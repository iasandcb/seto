import Foundation
import SwiftUI

struct SSHRemoteMessage: Codable, Sendable {
    var v = 1
    var session: String
    var type: String
    var id: String?
    var path: String?
    var content: String?
    var version: String?
    var code: String?
    var message: String?
}

/// Bounded framing on the exec channel only. Terminal output never enters this decoder.
struct SSHRemoteFrames {
    static let limit = 6 * 1024 * 1024 + 16384
    private var pending = Data()
    mutating func receive(_ bytes: Data) throws -> [Data] {
        var frames: [Data] = []
        for byte in bytes {
            if byte == 10 {
                frames.append(pending)
                pending.removeAll(keepingCapacity: true)
            } else {
                guard pending.count < Self.limit else { throw CocoaError(.fileReadTooLarge) }
                pending.append(byte)
            }
        }
        return frames
    }
}

struct SSHRemoteDraft: Codable, Identifiable, Equatable {
    var id: String { origin + "\n" + path }
    var origin: String
    var path: String
    var version: String
    var content: String
}

@MainActor
final class SSHRemoteEditor: ObservableObject {
    @Published var document: SSHRemoteDraft?
    @Published var presented = false
    @Published var ready = false
    @Published var saving = false
    @Published var conflict = false
    @Published var status = "파일 편집 연결을 누르세요."
    @Published var drafts: [SSHRemoteDraft]
    private(set) var session = ""
    private var origin = ""
    private var savedContent = ""
    private var needsVerification = false
    private var inFlight: (id: String, content: String)?
    private var timeout: Task<Void, Never>?
    private var send: ((SSHRemoteMessage) -> Void)?
    private let defaults: UserDefaults
    private let draftKey = "ssh.remote.drafts.v1"
    var dirty: Bool { document.map { $0.content != savedContent || $0.version == "missing" || needsVerification } ?? false }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        drafts = defaults.data(forKey: draftKey).flatMap { try? JSONDecoder().decode([SSHRemoteDraft].self, from: $0) } ?? []
    }

    func bind(origin: String, session: String, send: @escaping (SSHRemoteMessage) -> Void) {
        disconnected()
        self.origin = origin
        self.session = session
        self.send = send
        status = "편집 도우미에 연결 중…"
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, self.session == session, !self.ready else { return }
            self.disconnected("편집 도우미 응답이 없습니다. 설치를 확인한 뒤 다시 연결하세요.")
        }
    }

    func receive(_ message: SSHRemoteMessage) {
        guard message.v == 1, message.session == session, send != nil else { return }
        switch message.type {
        case "ready":
            timeout?.cancel(); timeout = nil
            ready = true
            status = "편집 연결됨 · 터미널에서 seto 파일명을 실행하세요."
        case "open":
            guard ready, document == nil, let path = message.path, path.hasPrefix("/"),
                  !path.contains("\0"), let content = message.content,
                  content.utf8.count <= 1024 * 1024, !content.contains("\0"),
                  let version = message.version, !version.isEmpty else { return }
            let loaded = SSHRemoteDraft(origin: origin, path: path, version: version, content: content)
            savedContent = content
            needsVerification = false
            conflict = false
            if let draft = drafts.first(where: { $0.id == loaded.id }), draft.content != content {
                document = draft
                conflict = draft.version != version
                status = conflict ? "원격 파일이 변경되었습니다. 복구한 초안을 복사하고 다시 여세요." : "기기에 보관한 초안을 복구했습니다."
            } else {
                document = loaded
                removeDraft(loaded.id)
                status = version == "missing" ? "새 파일 · 저장하면 서버에 생성됩니다." : "원격 파일을 열었습니다."
            }
            presented = true
        case "saved":
            guard let flight = inFlight, message.id == flight.id,
                  message.path == document?.path, let version = message.version,
                  !version.isEmpty, version != "missing" else { return }
            timeout?.cancel(); timeout = nil
            document?.version = version
            savedContent = flight.content
            needsVerification = false
            inFlight = nil; saving = false
            if dirty { persist(); status = "이전 내용 저장 확인 · 추가 변경은 미저장" }
            else if let document { removeDraft(document.id); status = "서버 저장 완료" }
        case "error":
            guard let flight = inFlight, message.id == flight.id else { return }
            timeout?.cancel(); timeout = nil
            saving = false; inFlight = nil
            conflict = message.code == "conflict"
            status = message.message ?? "저장 실패 · 초안은 기기에 보관했습니다."
            persist()
        default: break
        }
    }

    func update(_ content: String) {
        document?.content = content
        persist()
        if !saving && !conflict { status = ready ? "미저장 · 초안은 기기에 보관됨" : "연결 끊김 · 초안은 기기에 보관됨" }
    }

    func save() {
        guard ready, !saving, !conflict, let document else { return }
        guard document.content.utf8.count <= 1024 * 1024, !document.content.contains("\0") else {
            status = "1 MiB 이하의 UTF-8 텍스트만 저장할 수 있습니다. 초안은 유지됩니다."; return
        }
        needsVerification = true
        persist()
        let id = UUID().uuidString
        inFlight = (id, document.content); saving = true
        status = "서버 저장 확인 중…"
        send?(.init(session: session, type: "save", id: id, path: document.path, content: document.content, version: document.version))
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, self.inFlight?.id == id else { return }
            // The server may have committed already. Never retry with an uncertain baseline.
            self.conflict = true
            self.saving = false; self.inFlight = nil
            self.status = "저장 응답을 확인하지 못했습니다. 초안을 복사하고 파일을 다시 열어 확인하세요."
        }
    }

    func disconnected(_ reason: String = "연결 끊김 · 초안은 기기에 보관됨") {
        persist()
        ready = false; saving = false; inFlight = nil
        timeout?.cancel(); timeout = nil
        send = nil
        status = reason
    }

    func close(discardDraft: Bool = false) {
        guard !saving else { return }
        if discardDraft, let document { removeDraft(document.id) }
        else { persist() }
        if ready { send?(.init(session: session, type: "close", id: UUID().uuidString)) }
        document = nil; presented = false; conflict = false; needsVerification = false
    }

    func preview(_ draft: SSHRemoteDraft) {
        guard document == nil else { presented = true; return }
        document = draft
        savedContent = ""; conflict = true; needsVerification = true
        status = "로컬 초안 · 같은 서버에 연결하고 이 경로를 seto로 다시 열어 저장하세요."
        presented = true
    }

    private func persist() {
        guard let document else { return }
        guard dirty else { removeDraft(document.id); return }
        drafts = storedDrafts()
        drafts.removeAll { $0.id == document.id }
        drafts.append(document)
        writeDrafts()
    }
    private func removeDraft(_ id: String) {
        drafts = storedDrafts()
        drafts.removeAll { $0.id == id }
        writeDrafts()
    }
    private func storedDrafts() -> [SSHRemoteDraft] {
        defaults.data(forKey: draftKey).flatMap { try? JSONDecoder().decode([SSHRemoteDraft].self, from: $0) } ?? []
    }
    private func writeDrafts() {
        guard let data = try? JSONEncoder().encode(drafts) else { return }
        defaults.set(data, forKey: draftKey)
    }
}

struct SSHRemoteEditorView: View {
    @ObservedObject var files: SSHRemoteEditor
    @State private var focused = true
    @State private var confirmClose = false
    @AppStorage("app.inputMode") private var mode: Language = .korean
    @AppStorage("app.autoSwitch") private var automatic = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                InputControls(mode: $mode, automatic: $automatic).padding(.horizontal)
                HardwareTextEditor(text: Binding(get: { files.document?.content ?? "" }, set: { files.update($0) }),
                                   focused: $focused, mode: $mode, automatic: $automatic, focusOnOpen: true)
            }
            .navigationTitle((files.document?.path as NSString?)?.lastPathComponent ?? "원격 파일")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("닫기") {
                        focused = false
                        if files.dirty { confirmClose = true } else { files.close() }
                    }.disabled(files.saving)
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    CopyPracticeButton(text: files.document?.content ?? "").labelStyle(.iconOnly)
                    Button(files.saving ? "저장 중" : "저장") { files.save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!files.ready || files.saving || files.conflict)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Text(files.status).font(.caption)
                    Spacer()
                    Button("완료") { focused = false }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 3) {
                    Text(files.document?.path ?? "").lineLimit(2)
                    Text(files.status)
                }.font(.caption).padding(6).frame(maxWidth: .infinity).background(.bar)
            }
            .confirmationDialog("원격 서버에 저장하지 않은 변경이 있습니다.", isPresented: $confirmClose, titleVisibility: .visible) {
                Button("초안을 기기에 보관하고 닫기") { files.close() }
                Button("초안 버리고 닫기", role: .destructive) { files.close(discardDraft: true) }
                Button("계속 편집", role: .cancel) {}
            }
            .interactiveDismissDisabled()
        }
    }
}
