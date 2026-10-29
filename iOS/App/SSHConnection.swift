//
//  UIKitSshTerminalView.swift
//  iOS
//
//  Created by Miguel de Icaza on 4/22/20.
//  Copyright © 2020 Miguel de Icaza. All rights reserved.
//

import Foundation
import CryptoKit
import NIOConcurrencyHelpers
import UIKit
import SwiftTerm
import NIOCore
import NIOPosix
import NIOSSH

struct SSHConnectionInfo: Equatable, Sendable {
    let host: String
    let port: Int
    let username: String
    let password: String
    let term: String
    let environment: [String: String]

    init(
        host: String = "localhost",
        port: Int = 22,
        username: String,
        password: String,
        term: String = "xterm-256color",
        environment: [String: String] = ["LANG": "en_US.UTF-8"]
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.term = term
        self.environment = environment
    }
}

private enum SSHClientError: Error {
    case invalidChannelType
}

final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let verify: @Sendable (String, EventLoopPromise<Void>) -> Void
    init(verify: @escaping @Sendable (String, EventLoopPromise<Void>) -> Void) { self.verify = verify }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        verify(String(openSSHPublicKey: hostKey), validationCompletePromise)
    }
}

final class SimplePasswordDelegate: NIOSSHClientUserAuthenticationDelegate, Sendable {
    let username: String
    private let password: NIOLockedValueBox<String?>
    init(username: String, password: String) { self.username = username; self.password = .init(password) }
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        let secret = password.withLockedValue { value in defer { value = nil }; return value }
        guard availableMethods.contains(.password), let secret else { nextChallengePromise.succeed(nil); return }
        nextChallengePromise.succeed(.init(username: username, serviceName: "", offer: .password(.init(password: secret))))
    }
}

private final class SSHErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let onError: @Sendable (Error) -> Void

    init(onError: @escaping @Sendable (Error) -> Void) {
        self.onError = onError
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onError(error)
        context.close(promise: nil)
    }
}

private final class SSHShellChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let feedSender: TerminalFeedSender
    private let term: String
    private let environment: [String: String]
    private let initialWindowSize: (cols: Int, rows: Int)

    init(
        feedSender: TerminalFeedSender,
        term: String,
        environment: [String: String],
        initialWindowSize: (cols: Int, rows: Int)
    ) {
        self.feedSender = feedSender
        self.term = term
        self.environment = environment
        self.initialWindowSize = initialWindowSize
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let pipeline = context.pipeline
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            pipeline.fireErrorCaught(error)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: term,
            terminalCharacterWidth: initialWindowSize.cols,
            terminalRowHeight: initialWindowSize.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        let channel = context.channel
        channel.triggerUserOutboundEvent(pty).flatMap {
            channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true))
        }.whenFailure { error in
            channel.pipeline.fireErrorCaught(error)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)

        guard case .byteBuffer(var buffer) = payload.data else {
            return
        }

        guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else {
            return
        }

        let chunkSize = 1024
        var next = 0
        while next < bytes.count {
            let end = min(next + chunkSize, bytes.count)
            let chunk = bytes[next..<end]
            // feed is thread-safe as of the terminal-lock work; keep parsing on the NIO channel thread.
            feedSender.feed(byteArray: chunk)
            next = end
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            feedSender.feed(text: "\n[SSH] Session exited with status \(status.exitStatus)\n")
        } else if let signal = event as? SSHChannelRequestEvent.ExitSignal {
            feedSender.feed(text: "\n[SSH] Session closed: \(signal.signalName)\n")
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }
}

@MainActor
final class SSHConnection {
    var onStatus: (String) -> Void = { _ in }
    let verifyHost: @Sendable (String, EventLoopPromise<Void>) -> Void
    private let feedSender: TerminalFeedSender
    private let host: String
    private let port: Int
    private let username: String
    private var password: String
    private let term: String
    private let environment: [String: String]
    private let initialWindowSize: (cols: Int, rows: Int)
    private var group: EventLoopGroup?
    private var channel: Channel?
    private var sessionChannel: Channel?

    init(
        feedSender: TerminalFeedSender,
        host: String,
        port: Int,
        username: String,
        password: String,
        term: String,
        environment: [String: String],
        initialWindowSize: (cols: Int, rows: Int),
        verifyHost: @escaping @Sendable (String, EventLoopPromise<Void>) -> Void
    ) {
        self.verifyHost = verifyHost
        self.feedSender = feedSender
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.term = term
        self.environment = environment
        self.initialWindowSize = initialWindowSize
    }

    func connect() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        onStatus("접속 중")
        let verifyHost = verifyHost
        let username = username
        let password = password
        self.password = ""
        let reportError: @Sendable (Error) -> Void = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.handleError(error)
            }
        }

        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(15))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let sshHandler = NIOSSHHandler(
                        role: .client(
                            .init(
                                userAuthDelegate: SimplePasswordDelegate(
                                    username: username,
                                    password: password
                                ),
                                serverAuthDelegate: HostKeyDelegate(verify: verifyHost)
                            )
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(sshHandler)
                    try channel.pipeline.syncOperations.addHandler(
                        SSHErrorHandler(onError: reportError)
                    )
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

        bootstrap.connect(host: host, port: port).whenComplete { [weak self] result in
            Task { @MainActor [weak self] in
                self?.connectionCompleted(result)
            }
        }
    }

    func send(_ data: Data) {
        guard let sessionChannel else { return }
        sessionChannel.eventLoop.execute {
            var buffer = sessionChannel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            let payload = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            sessionChannel.writeAndFlush(payload, promise: nil)
        }
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, let sessionChannel else { return }
        sessionChannel.eventLoop.execute {
            let event = SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: cols,
                terminalRowHeight: rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0
            )
            sessionChannel.triggerUserOutboundEvent(event, promise: nil)
        }
    }

    func disconnect() {
        let channel = channel
        let group = group
        self.channel = nil
        sessionChannel = nil
        password = ""
        self.group = nil

        if let channel, let group {
            channel.closeFuture.whenComplete { _ in
                group.shutdownGracefully { _ in }
            }
            channel.close(promise: nil)
        } else if let group {
            group.shutdownGracefully { _ in }
        }
    }

    private func connectionCompleted(_ result: Result<Channel, Error>) {
        switch result {
        case .failure(let error):
            handleError(error)
            disconnect()
        case .success(let channel):
            guard group != nil else {
                channel.close(promise: nil)
                return
            }
            self.channel = channel
            channel.closeFuture.whenComplete { [weak self] _ in
                Task { @MainActor in self?.onStatus("연결 끊김") }
            }
            createSessionChannel(on: channel)
        }
    }

    private func createSessionChannel(on channel: Channel) {
        let feedSender = feedSender
        let term = term
        let environment = environment
        let initialWindowSize = initialWindowSize
        let reportError: @Sendable (Error) -> Void = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.handleError(error)
            }
        }

        channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
            let promise = channel.eventLoop.makePromise(of: Channel.self)
            sshHandler.createChannel(promise, channelType: .session) { childChannel, channelType in
                guard channelType == .session else {
                    return channel.eventLoop.makeFailedFuture(SSHClientError.invalidChannelType)
                }

                return childChannel.eventLoop.makeCompletedFuture {
                    let handler = SSHShellChannelHandler(
                        feedSender: feedSender,
                        term: term,
                        environment: environment,
                        initialWindowSize: initialWindowSize
                    )
                    let sync = childChannel.pipeline.syncOperations
                    try sync.addHandler(handler)
                    try sync.addHandler(SSHErrorHandler(onError: reportError))
                }
            }

            return promise.futureResult
        }.whenComplete { [weak self] result in
            Task { @MainActor [weak self] in
                self?.sessionChannelCompleted(result)
            }
        }
    }

    private func sessionChannelCompleted(_ result: Result<Channel, Error>) {
        switch result {
        case .failure(let error):
            handleError(error)
        case .success(let childChannel):
            guard channel != nil else {
                childChannel.close(promise: nil)
                return
            }
            sessionChannel = childChannel
            childChannel.closeFuture.whenComplete { [weak self] _ in
                Task { @MainActor in
                    self?.onStatus("연결 끊김")
                    self?.disconnect()
                }
            }
            onStatus("연결됨")
            resize(cols: initialWindowSize.cols, rows: initialWindowSize.rows)
        }
    }

    private func handleError(_ error: Error) {
        onStatus("오류: \(error)")
        feedSender.feed(text: "[ERROR] \(error)\n")
        disconnect()
    }
}

