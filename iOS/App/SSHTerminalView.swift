import SetoCore
import SwiftUI
import UIKit
import SwiftTerm
import NIOCore
import CryptoKit
import GameController

@MainActor
final class TerminalModel: ObservableObject {
    @Published var status = "연결 전"
    @Published var pending = ""
    @Published var mode: Language = .korean
    @Published var automatic = true
    @Published var hostKey: String?
    @Published var hostChanged = false
    var decision: ((Bool) -> Void)?
    weak var terminal: SetoTerminal?
    var retainedHost: TerminalKeyboardHost?
    var navigateTab: ((Int) -> Void)?
    func decide(_ accept: Bool) { let action = decision; decision = nil; hostKey = nil; action?(accept) }
}

@MainActor
final class SSHTab: ObservableObject, Identifiable {
    let id = UUID()
    let number: Int
    @Published var title: String
    let model = TerminalModel()
    let files = SSHRemoteEditor()
    init(number: Int) { self.number = number; title = "터미널 \(number)" }
    func close() {
        model.decide(false)
        model.terminal?.disconnect()
        model.retainedHost = nil
    }
}

@MainActor
final class SSHTabs: ObservableObject {
    @Published private(set) var tabs: [SSHTab] = []
    @Published var selected: UUID?
    private var nextNumber = 1
    init() { add() }
    func add() {
        let tab = SSHTab(number: nextNumber)
        tab.model.navigateTab = { [weak self] offset in self?.move(offset) }
        nextNumber += 1
        tabs.append(tab)
        selected = tab.id
    }
    func remove(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].close()
        tabs.remove(at: index)
        if tabs.isEmpty { add() }
        else if selected == id { selected = tabs[min(index, tabs.count - 1)].id }
    }
    func move(_ offset: Int) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == selected }) else { return }
        selected = tabs[((index + offset) % tabs.count + tabs.count) % tabs.count].id
    }
    func closeAll() { for tab in tabs { tab.close() } }
}

struct SSHTerminalView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var workspace = SSHTabs()
    @StateObject private var servers = SSHServerStore()
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { workspace.closeAll(); dismiss() } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel("모든 터미널 닫기")
                Button { workspace.move(-1) } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                    .accessibilityLabel("이전 터미널 탭")
                    .disabled(workspace.tabs.count < 2)
                Button { workspace.move(1) } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                    .accessibilityLabel("다음 터미널 탭")
                    .disabled(workspace.tabs.count < 2)
                ScrollViewReader { scroll in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(workspace.tabs) { tab in
                                SSHTabLabel(tab: tab, selected: workspace.selected == tab.id,
                                    select: { workspace.selected = tab.id }, close: { workspace.remove(tab.id) })
                                    .id(tab.id)
                            }
                        }
                    }
                    .onChange(of: workspace.selected) { id in
                        if let id { scroll.scrollTo(id, anchor: .trailing) }
                    }
                }
                Button { workspace.add() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("새 터미널 탭")
            }
            .font(.caption).padding(.horizontal, 8).frame(height: 32).background(.bar)
            ZStack {
                ForEach(workspace.tabs) { tab in
                    SSHSessionView(tab: tab, servers: servers, active: workspace.selected == tab.id,
                                   closeTab: { workspace.remove(tab.id) })
                        .opacity(workspace.selected == tab.id ? 1 : 0)
                        .allowsHitTesting(workspace.selected == tab.id)
                        .accessibilityHidden(workspace.selected != tab.id)
                }
            }
        }
        .onDisappear {
            if !workspace.tabs.contains(where: { $0.files.presented }) { workspace.closeAll() }
        }
    }
}

private struct SSHTabLabel: View {
    @ObservedObject var tab: SSHTab
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Button(action: select) { Text(tab.title).lineLimit(1).frame(maxWidth: 150) }
                .accessibilityAddTraits(selected ? .isSelected : [])
            Button(action: close) { Image(systemName: "xmark").font(.caption2) }
                .accessibilityLabel(tab.title + " 탭 닫기")
        }
        .padding(.horizontal, 8).frame(height: 28)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct SSHSessionView: View {
    @ObservedObject var tab: SSHTab
    @ObservedObject var servers: SSHServerStore
    let active: Bool
    let closeTab: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage("app.hardwareLayout") private var hardwareLayout: KeyboardLayout = .sebeol390
    @StateObject private var serverForm = SSHServerForm()
    @State private var serverNotice: String?
    @State private var info: SSHConnectionInfo?
    @State private var error: String?
    @ObservedObject private var model: TerminalModel
    @ObservedObject private var files: SSHRemoteEditor

    init(tab: SSHTab, servers: SSHServerStore, active: Bool, closeTab: @escaping () -> Void) {
        self.tab = tab; self.servers = servers; self.active = active; self.closeTab = closeTab
        self.model = tab.model; self.files = tab.files
    }

    private var compactTerminal: Bool { info != nil && verticalSizeClass == .compact }

    var body: some View {
        NavigationStack {
            VStack(spacing: compactTerminal ? 0 : 8) {
                if let info {
                    if !compactTerminal {
                        HStack {
                            Text(model.status).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            fileControls
                            HardwareLayoutPicker()
                            automaticToggle.font(.caption).fixedSize()
                        }.padding(.horizontal, 8)
                    }
                    // Keep a single terminal identity across rotation to preserve SSH and focus.
                    Group {
                        if active {
                            TerminalHost(info: info, model: model, files: files, layout: hardwareLayout)
                        } else { Color.clear }
                    }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                    if compactTerminal {
                        landscapeControls
                    } else {
                        keyControls.font(.caption).padding(.horizontal, 4)
                        HStack {
                            Text("조합").foregroundStyle(.secondary)
                            Text(model.pending.isEmpty ? " " : model.pending).lineLimit(2)
                            Spacer()
                            commitButton
                        }.font(.callout).padding(8)
                    }
                } else {
                    Form {
                        Section("저장한 서버") {
                            ForEach(servers.servers) { server in
                                Button { selectServer(server) } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(server.name).foregroundStyle(.primary)
                                            Text(server.endpoint.label).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if server.remembersPassword {
                                            Image(systemName: "key.fill").accessibilityLabel("비밀번호 저장됨")
                                        }
                                        if serverForm.serverID == server.id {
                                            Image(systemName: "checkmark").accessibilityLabel("선택됨")
                                        }
                                    }
                                }
                                .swipeActions {
                                    Button("삭제", role: .destructive) { deleteServer(server) }
                                }
                                .contextMenu {
                                    Button("삭제", role: .destructive) { deleteServer(server) }
                                }
                            }
                            Button { serverForm.reset(); error = nil; serverNotice = nil } label: {
                                Label("새 서버", systemImage: "plus")
                            }
                        }
                        Section("SSH 서버") {
                            TextField("서버 이름 (선택)", text: $serverForm.name)
                            TextField("주소 또는 ssh://user@host:22", text: $serverForm.address)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("사용자 이름", text: $serverForm.username)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            SecureField("비밀번호", text: $serverForm.password)
                                // Credentials are managed by SSHServerStore. An explicit non-password
                                // type avoids Passwords save prompts; nil still permits login heuristics.
                                // SecureField continues to mask input and use secure text entry.
                                .textContentType(.oneTimeCode)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            Toggle("비밀번호 저장", isOn: $serverForm.rememberPassword)
                            Text("켜면 이 기기의 키체인에 비밀번호를 저장합니다. 끈 뒤 서버를 저장하면 저장된 비밀번호를 삭제합니다.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button(serverForm.serverID == nil ? "서버 저장" : "서버 변경 저장", action: saveServer)
                            Button("연결", action: connect)
                            Text("연결하면 서버 정보와 비밀번호 저장 설정을 함께 저장합니다.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let serverNotice { Text(serverNotice).foregroundStyle(.secondary) }
                        Section {
                            Text("하드웨어 키보드: 두벌식·세벌식 390·세벌식 최종 선택 · Shift+Space 한영 전환. 한글은 아래 조합 영역에서 작성하고 공백·Enter·제어 키 또는 확정 버튼으로 전송합니다.")
                        }
                        if !files.drafts.isEmpty {
                            Section("기기에 보관한 원격 파일 초안") {
                                ForEach(files.drafts) { draft in
                                    Button { files.preview(draft) } label: {
                                        VStack(alignment: .leading) {
                                            Text(draft.path)
                                            Text(draft.origin).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                        if let error { Text(error).foregroundStyle(.red) }
                    }
                }
            }
            .toolbar(compactTerminal ? .hidden : .visible, for: .navigationBar)
            .statusBarHidden(compactTerminal)
            .navigationTitle("SSH 터미널")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("닫기") { closeTab() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if info != nil {
                        Button("연결 종료", action: disconnect)
                    }
                }
            }
            .alert(model.hostChanged ? "서버 키가 변경되었습니다" : "서버 신뢰 확인", isPresented: Binding(get: { active && model.hostKey != nil }, set: { if !$0 { model.decide(false) } })) {
                if !model.hostChanged { Button("신뢰하고 연결") { model.decide(true) } }
                Button("취소", role: .cancel) { model.decide(false) }
            } message: {
                Text(model.hostChanged ? "저장된 서버 키와 다르므로 연결을 차단했습니다.\n\(model.hostKey ?? "")" : "서버 관리자와 지문을 확인하세요.\n\(model.hostKey ?? "")")
            }
            .fullScreenCover(isPresented: Binding(get: { active && files.presented }, set: { files.presented = $0 }), onDismiss: {
                if active && model.status == "연결됨" { _ = model.terminal?.becomeFirstResponder() }
            }) { SSHRemoteEditorView(files: files) }
            .onChange(of: files.presented) { visible in
                if visible && active { model.terminal?.suspendForEditor() }
            }
            .onChange(of: active) { visible in
                if !visible { model.terminal?.cancelInput() }
            }
            .onChange(of: servers.servers) { values in
                if let id = serverForm.serverID, !values.contains(where: { $0.id == id }) {
                    serverForm.reset(); serverNotice = nil
                }
            }
            .onChange(of: scenePhase) { phase in
                if phase != .active { model.terminal?.cancelInput() }
                if phase == .background { model.decide(false); model.terminal?.disconnect() }
            }
        }
    }

    private var fileControls: some View {
        Menu {
            Text(files.status)
            Button(files.ready ? "파일 편집 연결됨" : "파일 편집 연결") { model.terminal?.enableFileEditor() }
                .disabled(files.ready || model.status != "연결됨")
            Text("서버에 도우미를 설치한 뒤 연결하세요. 터미널에서 seto 파일명을 실행합니다.")
            ForEach(files.drafts) { draft in
                Button("초안: " + draft.path) { files.preview(draft) }
            }
        } label: { Image(systemName: "doc.text") }
        .accessibilityLabel("원격 파일 편집 및 로컬 초안")
    }

    private var automaticToggle: some View {
        Toggle("자동 한/영", isOn: Binding(get: { model.automatic }, set: { model.terminal?.setAutomatic($0) }))
    }

    private var commitButton: some View {
        Button("확정") { model.terminal?.flushInput() }.disabled(model.pending.isEmpty)
    }

    private var keyControls: some View {
        HStack(spacing: 10) {
            Button(model.mode.displayName) { model.terminal?.toggleMode() }
            ForEach(["Esc", "Tab", "Ctrl+C", "←", "↓", "↑", "→"], id: \.self) { key in
                Button(key) { model.terminal?.special(key) }
            }
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var landscapeControls: some View {
        HStack(spacing: 10) {
            Menu {
                Text(model.status)
                automaticToggle
                Picker("외부 키보드 자판", selection: $hardwareLayout) {
                    ForEach(KeyboardLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Button("연결 종료", action: disconnect)
                Button("닫기") { closeTab() }
            } label: {
                Image(systemName: "ellipsis.circle").font(.body)
            }.accessibilityLabel("터미널 메뉴 및 연결 상태")
            fileControls
            keyControls
            Divider().frame(height: 20)
            Text(model.pending.isEmpty ? "조합 대기" : model.pending)
                .font(.custom("D2Coding", size: 17))
                .foregroundStyle(model.pending.isEmpty ? .secondary : .primary)
                .lineLimit(1).truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("조합 " + model.pending)
            commitButton
        }
        .font(.caption)
        .padding(.horizontal, 6)
        .frame(height: 36)
        .background(.bar)
    }

    private func selectServer(_ server: SSHServer) {
        do {
            try serverForm.load(server, from: servers)
            error = nil; serverNotice = nil
        } catch { self.error = error.localizedDescription }
    }

    private func saveServer() {
        do {
            let server = try serverForm.save(to: servers)
            error = nil; serverNotice = "\(server.name) 저장됨"
        } catch { self.error = error.localizedDescription }
    }

    private func deleteServer(_ server: SSHServer) {
        do {
            try servers.remove(server)
            if serverForm.serverID == server.id { serverForm.reset() }
            error = nil; serverNotice = nil
        } catch { self.error = error.localizedDescription }
    }

    private func disconnect() {
        model.decide(false); model.terminal?.disconnect(); model.retainedHost = nil; info = nil
        if let server = servers.servers.first(where: { $0.id == serverForm.serverID }) { selectServer(server) }
    }

    private func connect() {
        do {
            let server = try serverForm.save(to: servers)
            let endpoint = server.endpoint
            tab.title = "\(tab.number) · \(server.name)"
            error = nil; serverNotice = nil
            info = SSHConnectionInfo(host: endpoint.host, port: endpoint.port,
                                     username: endpoint.username, password: serverForm.password)
            serverForm.password = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct TerminalHost: UIViewRepresentable {
    let info: SSHConnectionInfo
    let model: TerminalModel
    let files: SSHRemoteEditor
    let layout: KeyboardLayout
    func makeUIView(context: Context) -> TerminalKeyboardHost {
        if let host = model.retainedHost {
            host.focusWhenAttached = model.status == "연결됨" && !files.presented
            host.terminal.configureLayout(layout)
            return host
        }
        let view = SetoTerminal(frame: .zero)
        view.model = model
        view.files = files
        model.terminal = view
        view.configureLayout(layout)
        view.refresh()
        let host = TerminalKeyboardHost(terminal: view)
        model.retainedHost = host
        view.connect(info)
        return host
    }
    func updateUIView(_ uiView: TerminalKeyboardHost, context: Context) { uiView.terminal.configureLayout(layout) }
    static func dismantleUIView(_ uiView: TerminalKeyboardHost, coordinator: ()) {
        uiView.stopAllInput()
        _ = uiView.resignFirstResponder()
        // The tab owns the detached view. SwiftTerm pauses its display driver with window == nil.
    }
}

final class SetoTerminal: TerminalView, TerminalViewDelegate {
    weak var model: TerminalModel?
    private var connection: SSHConnection?
    var files: SSHRemoteEditor?
    private var remoteOrigin = ""
    private var rendererShutdown: Task<Void, Never>?
    private let input = TerminalInput(lexicon: TerminalInput.bundledLexicon, automatic: true)

    override init(frame: CGRect) {
        super.init(frame: frame)
        font = UIFont(name: "D2Coding", size: 18) ?? .monospacedSystemFont(ofSize: 18, weight: .regular)
        terminalDelegate = self
        input.send = { [weak self] text in self?.connection?.send(Data(text.utf8)) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func connect(_ info: SSHConnectionInfo) {
        let model = model
        remoteOrigin = "\(info.username)@\(info.host.lowercased()):\(info.port)"
        let identity = "\(info.host):\(info.port)"
        let c = SSHConnection(feedSender: feedSender, host: info.host, port: info.port,
            username: info.username, password: info.password, term: info.term,
            environment: info.environment, initialWindowSize: (80, 24)) { [weak model] key, promise in
                Task { @MainActor [weak model] in
                    guard let model else { promise.fail(CancellationError()); return }
                    let storage = "ssh.hostkey." + identity
                    let existing = UserDefaults.standard.string(forKey: storage)
                    if existing == key { promise.succeed(()); return }
                    let encoded = key.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    let bytes = Data(base64Encoded: encoded) ?? Data(key.utf8)
                    let fingerprint = Data(SHA256.hash(data: bytes)).base64EncodedString().replacingOccurrences(of: "=", with: "")
                    model.hostChanged = existing != nil
                    model.decision = { accept in
                        if accept && existing == nil {
                            UserDefaults.standard.set(key, forKey: storage); promise.succeed(())
                        } else { promise.fail(CancellationError()) }
                    }
                    model.hostKey = identity + "\nSHA256:" + fingerprint
                }
            }
        c.onStatus = { [weak self] status in
            self?.model?.status = status
            if status == "연결 끊김" || status.hasPrefix("오류:") {
                self?.input.discard(); self?.refresh()
                (self?.superview as? TerminalKeyboardHost)?.stopAllInput()
                self?.model?.decide(false)
                self?.files?.disconnected()
            }
            if status == "연결됨", let self {
                let size = self.terminalDimensions
                self.connection?.resize(cols: size.cols, rows: size.rows)
                _ = self.becomeFirstResponder()
            }
        }
        connection = c
        c.connect()
    }
    func enableFileEditor() {
        guard let connection, let files, model?.status == "연결됨" else { return }
        connection.stopEditor()
        let session = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        files.bind(origin: remoteOrigin, session: session) { [weak connection] message in connection?.sendEditor(message) }
        connection.startEditor(session: session, onFrame: { [weak files, weak connection] data in
            guard let files, files.session == session else { return }
            guard let message = try? JSONDecoder().decode(SSHRemoteMessage.self, from: data),
                  message.v == 1, message.session == session else {
                connection?.stopEditor()
                files.disconnected("편집 도우미 응답을 검증하지 못했습니다. 설치 버전을 확인하세요.")
                return
            }
            files.receive(message)
        }, onEnd: { [weak files] reason in
            guard files?.session == session else { return }
            files?.disconnected(reason)
        })
    }

    func suspendForEditor() {
        cancelInput()
        _ = (superview as? TerminalKeyboardHost)?.resignFirstResponder()
    }

    func cancelInput() { (superview as? TerminalKeyboardHost)?.stopAllInput() }

    func disconnect() {
        (superview as? TerminalKeyboardHost)?.stopAllInput()
        input.discard(); refresh()
        files?.disconnected()
        connection?.disconnect(); connection = nil
        model?.status = "연결 종료"
        closeRenderer()
    }

    /// SwiftTerm's display driver must be shut down explicitly by its owner.
    private func closeRenderer() {
        guard rendererShutdown == nil else { return }
        if updateUiClosed() { return }
        // A committed Metal frame may still be finishing. Retry without keeping a timer alive.
        rendererShutdown = Task { @MainActor [self] in
            for _ in 0..<20 {
                if Task.isCancelled { break }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                if updateUiClosed() { rendererShutdown = nil; return }
            }
            rendererShutdown = nil
        }
    }
    func refresh() {
        guard let model else { return }
        if model.pending != input.pending { model.pending = input.pending }
        if model.mode != input.mode { model.mode = input.mode }
        if model.automatic != input.automatic { model.automatic = input.automatic }
    }
    func configureLayout(_ layout: KeyboardLayout) { guard input.layout != layout else { return }; input.configure(mode: input.mode, automatic: input.automatic, layout: layout); refresh() }
    func setAutomatic(_ enabled: Bool) { input.configure(mode: input.mode, automatic: enabled); refresh() }
    func flushInput() { input.flush(); refresh() }
    @objc func toggleMode() { input.toggle(); refresh() }
    func special(_ name: String) {
        flushInput()
        let sequences = ["Esc": "\u{1b}", "Tab": "\t", "Ctrl+C": "\u{03}", "←": "\u{1b}[D", "→": "\u{1b}[C", "↑": "\u{1b}[A", "↓": "\u{1b}[B"]
        if let value = sequences[name] { connection?.send(Data(value.utf8)) }
    }
    override var keyCommands: [UIKeyCommand]? {
        let toggle = UIKeyCommand(input: " ", modifierFlags: .shift, action: #selector(toggleMode))
        toggle.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [toggle]
    }
    @discardableResult
    func handleKey(usage: Int, flags: UIKeyModifierFlags = []) -> Bool {
        let shortcutFlags = flags.intersection([.command, .shift, .control, .alternate])
        if shortcutFlags == [.command, .shift], (usage == 47 || usage == 48), let navigate = model?.navigateTab {
            navigate(usage == 47 ? -1 : 1)
            return true
        }
        guard model?.status == "연결됨" else { return true }
        switch HardwareKeymap.action(usage: usage, shift: flags.contains(.shift), command: flags.contains(.command), control: flags.contains(.control), option: flags.contains(.alternate)) {
        case .input(let character): input.input(character)
        case .backspace: input.backspace()
        case .toggle: input.toggle()
        case .passThrough:
            if !(224...231).contains(usage), usage != 57 { flushInput() }
            return false
        }
        refresh(); return true
    }
    override func becomeFirstResponder() -> Bool {
        if let host = superview as? TerminalKeyboardHost { return host.becomeFirstResponder() }
        return super.becomeFirstResponder()
    }
    func nativeBegan(_ presses: Set<UIPress>, event: UIPressesEvent?) { super.pressesBegan(presses, with: event) }
    func nativeEnded(_ presses: Set<UIPress>, event: UIPressesEvent?) { super.pressesEnded(presses, with: event) }
    func nativeCancelled(_ presses: Set<UIPress>, event: UIPressesEvent?) { super.pressesCancelled(presses, with: event) }
    override func insertText(_ text: String) {
        guard model?.status == "연결됨" else { return }
        flushInput(); super.insertText(text)
    }
    override func deleteBackward() { input.backspace(); refresh() }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { connection?.send(Data(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { connection?.resize(cols: newCols, rows: newRows) }
    func scrolled(source: TerminalView, position: Double) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func clipboardCopy(source: TerminalView, content: Data) { /* Remote clipboard writes are disabled. */ }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Own the complete physical-key lifetime, including repeat and cancellation.
/// SwiftTerm's release handlers are not open to subclasses.
final class TerminalKeyboardHost: UIView, UIKeyInput, UITextInputTraits {
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    let terminal: SetoTerminal
    var focusWhenAttached = false
    private var forwarding = false
    private var timer: Timer?
    private var repeated: (Int, UIKeyModifierFlags)?
    private var consumed = Set<Int>()
    private var nativePresses = Set<UIPress>()
    private var modifiers: UIKeyModifierFlags = []
    var hasText: Bool { true }
    override var canBecomeFirstResponder: Bool { true }
    override var inputView: UIView? { GCKeyboard.coalesced == nil ? nil : UIView(frame: .zero) }
    init(terminal: SetoTerminal) {
        self.terminal = terminal
        super.init(frame: .zero)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: .GCKeyboardDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: .GCKeyboardDidDisconnect, object: nil)
        addSubview(terminal)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor), terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminal.topAnchor.constraint(equalTo: topAnchor), terminal.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func insertText(_ text: String) { terminal.insertText(text) }
    func deleteBackward() { terminal.deleteBackward() }
    override var keyCommands: [UIKeyCommand]? {
        let toggle = UIKeyCommand(input: " ", modifierFlags: .shift, action: #selector(toggle))
        toggle.wantsPriorityOverSystemBehavior = true
        let previous = UIKeyCommand(input: "[", modifierFlags: [.command, .shift], action: #selector(previousTab))
        previous.discoverabilityTitle = "이전 터미널 탭"
        previous.wantsPriorityOverSystemBehavior = true
        let next = UIKeyCommand(input: "]", modifierFlags: [.command, .shift], action: #selector(nextTab))
        next.discoverabilityTitle = "다음 터미널 탭"
        next.wantsPriorityOverSystemBehavior = true
        return [toggle, previous, next]
    }
    @objc private func previousTab() { terminal.model?.navigateTab?(-1) }
    @objc private func nextTab() { terminal.model?.navigateTab?(1) }
    @objc private func keyboardChanged() { stopAllInput(); reloadInputViews() }
    @objc private func toggle() { terminal.toggleMode() }
    override func copy(_ sender: Any?) { terminal.copy(sender) }
    override func paste(_ sender: Any?) { terminal.flushInput(); terminal.paste(sender) }
    override func selectAll(_ sender: Any?) { terminal.selectAll(sender) }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        action == #selector(toggle) || action == #selector(previousTab) || action == #selector(nextTab) || terminal.canPerformAction(action, withSender: sender)
    }
    func stopRepeat() { timer?.invalidate(); timer = nil; repeated = nil }
    func stopAllInput() {
        stopRepeat()
        consumed.removeAll()
        modifiers = []
        let presses = nativePresses
        nativePresses.removeAll()
        guard !presses.isEmpty else { return }
        forwarding = true
        terminal.nativeCancelled(presses, event: nil)
        forwarding = false
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopAllInput() }
        else if focusWhenAttached { focusWhenAttached = false; _ = becomeFirstResponder() }
    }
    private func startRepeat(usage: Int, flags: UIKeyModifierFlags) {
        stopRepeat()
        repeated = (usage, flags)
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            let active = MainActor.assumeIsolated {
                guard let self, let (usage, flags) = self.repeated else { return false }
                _ = self.terminal.handleKey(usage: usage, flags: flags)
                return true
            }
            if !active { timer.invalidate() }
        }
        timer.fireDate = Date().addingTimeInterval(0.45)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if forwarding { super.pressesBegan(presses, with: event); return }
        var rest = Set<UIPress>()
        for press in presses {
            guard let key = press.key else { rest.insert(press); continue }
            if modifiers != key.modifierFlags { stopRepeat(); modifiers = key.modifierFlags }
            let usage = key.keyCode.rawValue
            if terminal.handleKey(usage: usage, flags: key.modifierFlags) {
                consumed.insert(usage)
                let action = HardwareKeymap.action(usage: usage, shift: key.modifierFlags.contains(.shift))
                switch action {
                case .input, .backspace:
                    if key.modifierFlags.intersection([.command, .control, .alternate]).isEmpty {
                        startRepeat(usage: usage, flags: key.modifierFlags)
                    }
                default: break
                }
            } else { rest.insert(press) }
        }
        nativePresses.formUnion(rest)
        forwarding = true
        if !rest.isEmpty { terminal.nativeBegan(rest, event: event) }
        forwarding = false
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if forwarding { super.pressesEnded(presses, with: event); return }
        let rest = presses.filter { press in
            guard let key = press.key else { return true }
            if repeated?.0 == key.keyCode.rawValue || modifiers != key.modifierFlags { stopRepeat() }
            modifiers = key.modifierFlags
            return consumed.remove(key.keyCode.rawValue) == nil
        }
        nativePresses.subtract(presses)
        forwarding = true
        terminal.nativeEnded(Set(rest), event: event)
        forwarding = false
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if forwarding { super.pressesCancelled(presses, with: event); return }
        stopRepeat(); consumed.removeAll(); nativePresses.subtract(presses)
        forwarding = true; terminal.nativeCancelled(presses, event: event); forwarding = false
    }
    override func resignFirstResponder() -> Bool { stopAllInput(); return super.resignFirstResponder() }
}
