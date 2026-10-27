import SwiftUI
import WebKit

struct MarkVectorDocument: Identifiable, Codable {
    var id: String { origin + path }
    let origin: String
    let path: String
    let filename: String
    var content: String
    var version: String
}

@MainActor
final class MarkVectorConnection: ObservableObject {
    let webView = WKWebView(frame: .zero)
    @Published var document: MarkVectorDocument?
    @Published var busy = false
    @Published var error: String?
    private(set) var origin = ""

    init(origin: String = "") { self.origin = origin }

    func connect(_ address: String) {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", let host = url.host, url.user == nil, url.password == nil,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            error = "https://로 시작하는 mark-vector 서버 주소를 입력하세요."
            return
        }
        parts.path = ""; parts.query = nil; parts.fragment = nil
        guard let base = parts.url else { return }
        origin = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !host.isEmpty else { return }
        webView.load(URLRequest(url: url))
    }

    private func run(_ script: String, arguments: [String: Any] = [:]) async throws -> Any? {
        guard let url = webView.url,
              let base = URL(string: origin), url.scheme == base.scheme,
              url.host == base.host, url.port == base.port else {
            throw failure("mark-vector 페이지에서 로그인한 뒤 문서를 선택하세요.")
        }
        do {
            return try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
        } catch {
            let details = error as NSError
            if let message = details.userInfo["WKJavaScriptExceptionMessage"] as? String {
                throw failure(message)
            }
            throw error
        }
    }

    func openDocument() async {
        busy = true
        defer { busy = false }
        do {
            let result = try await run("""
                const ref = JSON.parse(localStorage.getItem('mark-vector:active-doc') || 'null');
                if (!ref || ref.role !== 'document') throw new Error('프로젝트의 문서를 먼저 선택하세요.');
                const save = document.getElementById('save-btn');
                if (!save || save.disabled || save.classList.contains('dirty'))
                    throw new Error('웹 편집을 마치고 저장한 뒤 다시 눌러 주세요.');
                const path = '/api/projects/' + encodeURIComponent(ref.projectId) + '/conversations/' +
                    encodeURIComponent(ref.sessionId) + '/documents/' + encodeURIComponent(ref.filename);
                const res = await fetch(path, {credentials: 'same-origin', cache: 'no-store'});
                if (!res.ok) throw new Error('문서를 열 수 없습니다. 로그인 상태를 확인하세요. (' + res.status + ')');
                const doc = await res.json();
                return {path, filename: ref.filename, content: doc.content, version: doc.version};
                """)
            guard let values = result as? [String: Any], let path = values["path"] as? String,
                  let filename = values["filename"] as? String, let content = values["content"] as? String,
                  let version = values["version"] as? String else { throw failure("문서 응답을 읽지 못했습니다.") }
            let loaded = MarkVectorDocument(origin: origin, path: path, filename: filename, content: content, version: version)
            if let data = UserDefaults.standard.data(forKey: recoveryKey(loaded)),
               let recovered = try? JSONDecoder().decode(MarkVectorDocument.self, from: data),
               recovered.id == loaded.id {
                document = recovered
            } else { document = loaded }
        } catch { self.error = error.localizedDescription }
    }

    func save(_ document: MarkVectorDocument) async throws -> String {
        guard document.origin == origin else { throw failure("문서를 연 서버에 다시 연결하세요.") }
        let result = try await run("""
            // Check for external changes before writing; the server currently
            // has no atomic conditional-save endpoint.
            const current = await fetch(path, {credentials: 'same-origin', cache: 'no-store'});
            if (!current.ok) throw new Error('문서 확인 실패 (' + current.status + '). 다시 로그인해 주세요.');
            const latest = await current.json();
            if (latest.version !== version) throw new Error('다른 곳에서 문서가 변경되었습니다. 입력 내용은 기기에 보관했습니다. 내용을 복사한 뒤 최신 문서를 확인하세요.');
            const res = await fetch(path, {method: 'PUT', credentials: 'same-origin',
                headers: {'Content-Type': 'application/json'}, body: JSON.stringify({content})});
            if (!res.ok) throw new Error('저장 실패 (' + res.status + '). 입력 내용은 유지됩니다.');
            return (await res.json()).version;
            """, arguments: ["path": document.path, "content": document.content, "version": document.version])
        guard let version = result as? String else { throw failure("저장 응답을 확인하지 못했습니다. 입력 내용은 유지됩니다.") }
        UserDefaults.standard.removeObject(forKey: recoveryKey(document))
        webView.reload()
        return version
    }

    func retainDraft(_ document: MarkVectorDocument) {
        if let data = try? JSONEncoder().encode(document) {
            UserDefaults.standard.set(data, forKey: recoveryKey(document))
        }
    }

    func clearRecovery(_ document: MarkVectorDocument) {
        UserDefaults.standard.removeObject(forKey: recoveryKey(document))
    }

    private func recoveryKey(_ document: MarkVectorDocument) -> String { "mark-vector:draft:" + document.id }
    private func failure(_ message: String) -> NSError { NSError(domain: "MarkVector", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private struct MarkVectorBrowser: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct MarkVectorView: View {
    @AppStorage("markVectorAddress") private var address = "https://markvector.fly.dev"
    @StateObject private var connection = MarkVectorConnection()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                HStack {
                    TextField("서버 주소", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    Button("연결") { connection.connect(address) }
                        .disabled(connection.busy)
                }.padding(.horizontal)
                Text("로그인하고 문서를 선택·저장한 뒤 ‘세토로 편집’을 누르세요.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                MarkVectorBrowser(webView: connection.webView)
            }
            .navigationTitle("mark-vector")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("닫기") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { Task { await connection.openDocument() } } label: {
                        if connection.busy { ProgressView() } else { Text("세토로 편집") }
                    }.disabled(connection.busy)
                }
            }
            .onAppear { if connection.webView.url == nil { connection.connect(address) } }
            .fullScreenCover(item: $connection.document) { document in
                MarkVectorEditor(document: document, connection: connection)
            }
            .alert("mark-vector", isPresented: Binding(get: { connection.error != nil }, set: { if !$0 { connection.error = nil } })) {
                Button("확인", role: .cancel) { connection.error = nil }
            } message: { Text(connection.error ?? "") }
        }
    }
}

private struct MarkVectorEditor: View {
    @State var document: MarkVectorDocument
    @ObservedObject var connection: MarkVectorConnection
    @Environment(\.dismiss) private var dismiss
    @State private var focused = false
    @AppStorage("app.inputMode") private var mode: Language = .korean
    @AppStorage("app.autoSwitch") private var automatic = true
    @State private var saving = false
    @StateObject private var live = MarkVectorLiveSync()
    @Environment(\.scenePhase) private var scenePhase
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                InputControls(mode: $mode, automatic: $automatic).padding(.horizontal, 16)
                HardwareTextEditor(text: $document.content, focused: $focused, mode: $mode, automatic: $automatic)
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 12)
                .navigationTitle(document.filename)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("닫기") { focused = false; dismiss() }.disabled(saving)
                    }
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        CopyPracticeButton(text: document.content).labelStyle(.iconOnly)
                        Button(live.synchronized ? "저장됨" : "저장") {
                            saving = true
                            Task {
                                defer { saving = false }
                                do {
                                    live.update(document.content)
                                    document.version = try await live.flush()
                                } catch { self.error = error.localizedDescription }
                            }
                        }.keyboardShortcut("s", modifiers: .command)
                            .disabled(saving || live.synchronized)
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Text(live.status)
                        Spacer()
                        Button("완료") { focused = false }
                    }
                }
                .onChange(of: document.content) { _ in
                    connection.retainDraft(document)
                    live.update(document.content)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Text(live.status).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                        .background(.bar)
                }
                .task(id: scenePhase) {
                    if scenePhase == .active {
                        live.onPersisted = { content, version in
                            document.version = version
                            if document.content == content { connection.clearRecovery(document) }
                            else { connection.retainDraft(document) }
                        }
                        await live.start(document, cookies: connection.webView.configuration.websiteDataStore.httpCookieStore)
                    } else { live.stop() }
                }
                .onDisappear { live.stop(); connection.webView.reload() }
                .interactiveDismissDisabled(saving)
                .alert("저장하지 못했습니다", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("확인", role: .cancel) { error = nil }
                } message: { Text(error ?? "") }
        }
    }
}
