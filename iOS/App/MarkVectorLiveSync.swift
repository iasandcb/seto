import Foundation
import WebKit

/// One native writer sends coalesced snapshots; only server persistence
/// acknowledgements count as saved. No remote text ever drives local typing.
@MainActor
final class MarkVectorLiveSync: ObservableObject {
    @Published private(set) var status = "연결 중"
    @Published private(set) var synchronized = false
    var onPersisted: ((String, String) -> Void)?
    private var latest = ""
    private var persisted: String?
    private var version = ""
    private var sequence = 0
    private var inFlight: (sequence: Int, content: String)?
    private var connection: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var generation = UUID()
    private var ready = false
    private var lastMessage = Date()

    static func socketURL(for document: MarkVectorDocument) -> URL? {
        let path = document.path.split(separator: "/")
        guard path.count == 7, path[0] == "api", path[1] == "projects",
              path[3] == "conversations", path[5] == "documents",
              var url = URLComponents(string: document.origin), url.scheme == "https" else { return nil }
        url.scheme = "wss"
        url.percentEncodedPath = "/ws/documents/\(path[2])/\(path[4])/\(path[6])"
        url.queryItems = [URLQueryItem(name: "write", value: "1")]
        return url.url
    }

    func start(_ document: MarkVectorDocument, cookies: WKHTTPCookieStore) async {
        stop()
        let token = generation
        latest = document.content
        guard let url = Self.socketURL(for: document), let host = url.host else {
            status = "연결할 수 없는 문서 주소"
            return
        }
        let all = await cookies.allCookies()
        guard generation == token else { return }
        let matching = all.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return (host == domain || host.hasSuffix("." + domain)) &&
                (url.path == cookie.path || cookie.path == "/" || url.path.hasPrefix(cookie.path.hasSuffix("/") ? cookie.path : cookie.path + "/")) &&
                (cookie.expiresDate.map { $0 > Date() } ?? true)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        for (key, value) in HTTPCookie.requestHeaderFields(with: matching) { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue(document.origin, forHTTPHeaderField: "Origin")
        connection = Task { [weak self] in
            guard let self else { return }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            var attempts = 0
            while !Task.isCancelled, self.generation == token {
                self.status = attempts == 0 ? "연결 중" : "재연결 중 · 입력은 기기에 보관"
                let socket = session.webSocketTask(with: request)
                self.socket = socket
                self.ready = false
                self.inFlight = nil
                self.lastMessage = Date()
                socket.resume()
                let sending = Task { [weak self] in
                    do {
                        while !Task.isCancelled {
                            try await Task.sleep(for: .milliseconds(60))
                            guard let self, self.generation == token else { return }
                            if let pending = self.takeSnapshot() {
                                let snapshot = pending.content
                                self.status = "실시간 · 동기화 중"
                                let data = try JSONSerialization.data(withJSONObject: ["type": "update", "sequence": pending.sequence, "content": snapshot])
                                try await socket.send(.string(String(decoding: data, as: UTF8.self)))
                            }
                        }
                    } catch { socket.cancel(with: .goingAway, reason: nil) }
                }
                let heartbeat = Task { [weak self] in
                    do {
                        while !Task.isCancelled {
                            try await Task.sleep(for: .seconds(15))
                            guard let self, self.generation == token else { return }
                            if Date().timeIntervalSince(self.lastMessage) > 45 { socket.cancel(with: .goingAway, reason: nil); return }
                            try await socket.send(.string("{\"type\":\"ping\"}"))
                        }
                    } catch { socket.cancel(with: .goingAway, reason: nil) }
                }
                do {
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        guard self.generation == token else { break }
                        let data: Data
                        switch message {
                        case .data(let value): data = value
                        case .string(let value): data = Data(value.utf8)
                        @unknown default: continue
                        }
                        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        self.lastMessage = Date()
                        try self.receive(result)
                        attempts = 0
                    }
                } catch { /* The local draft is retained; reconnect with its newest snapshot. */ }
                sending.cancel(); heartbeat.cancel()
                socket.cancel(with: .goingAway, reason: nil)
                self.ready = false
                self.synchronized = false
                guard !Task.isCancelled, self.generation == token else { break }
                attempts += 1
                do { try await Task.sleep(for: .seconds(min(attempts, 10))) } catch { break }
            }
        }
    }

    func update(_ content: String) {
        latest = content
        synchronized = ready && persisted == latest
        if !synchronized, ready { status = "실시간 · 동기화 중" }
    }

    func takeSnapshot() -> (sequence: Int, content: String)? {
        guard ready, inFlight == nil, persisted != latest else { return nil }
        sequence += 1
        inFlight = (sequence, latest)
        return inFlight
    }

    /// Exposed internally so acknowledgement ordering can be tested without
    /// introducing a network into the UIKit test target.
    func receive(_ message: [String: Any]) throws {
        switch message["type"] as? String {
        case "ready":
            guard let content = message["content"] as? String, let nextVersion = message["version"] as? String else { return }
            ready = true
            persisted = content
            version = nextVersion
            if content == latest { onPersisted?(content, version) }
        case "ack":
            guard let pending = inFlight, let number = message["sequence"] as? Int,
                  number == pending.sequence, let nextVersion = message["version"] as? String else { return }
            persisted = pending.content
            version = nextVersion
            inFlight = nil
            onPersisted?(pending.content, version)
        case "error":
            throw NSError(domain: "MarkVectorLive", code: 1, userInfo: [NSLocalizedDescriptionKey: message["message"] as? String ?? "동기화 실패"])
        default: return
        }
        synchronized = ready && persisted == latest
        status = synchronized ? "실시간 · 저장됨" : "실시간 · 동기화 중"
    }

    func flush() async throws -> String {
        let deadline = Date().addingTimeInterval(15)
        while !synchronized {
            guard Date() < deadline, connection != nil else {
                throw NSError(domain: "MarkVectorLive", code: 2, userInfo: [NSLocalizedDescriptionKey: "서버 저장을 확인하지 못했습니다. 입력은 기기에 보관되어 있으며 연결되면 다시 전송합니다."])
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        return version
    }

    func stop() {
        generation = UUID()
        connection?.cancel(); connection = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        ready = false; synchronized = false; inFlight = nil
    }
}
