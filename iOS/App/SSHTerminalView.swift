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
    func decide(_ accept: Bool) { let action = decision; decision = nil; hostKey = nil; action?(accept) }
}

struct SSHTerminalView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage("app.hardwareLayout") private var hardwareLayout: KeyboardLayout = .sebeol390
    @AppStorage("ssh.address") private var address = ""
    @AppStorage("ssh.user") private var username = ""
    @State private var password = ""
    @State private var info: SSHConnectionInfo?
    @State private var error: String?
    @StateObject private var model = TerminalModel()

    private var compactTerminal: Bool { info != nil && verticalSizeClass == .compact }

    var body: some View {
        NavigationStack {
            VStack(spacing: compactTerminal ? 0 : 8) {
                if let info {
                    if !compactTerminal {
                        HStack {
                            Text(model.status).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            HardwareLayoutPicker()
                            automaticToggle.font(.caption).fixedSize()
                        }.padding(.horizontal, 8)
                    }
                    // Keep a single terminal identity across rotation to preserve SSH and focus.
                    TerminalHost(info: info, model: model, layout: hardwareLayout)
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
                        Section("SSH 서버") {
                            TextField("주소 또는 ssh://user@host:22", text: $address)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("사용자 이름", text: $username)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            SecureField("비밀번호 (저장하지 않음)", text: $password)
                            Button("연결", action: connect)
                        }
                        Section {
                            Text("하드웨어 키보드: 두벌식·세벌식 390·세벌식 최종 선택 · Shift+Space 한영 전환. 한글은 아래 조합 영역에서 작성하고 공백·Enter·제어 키 또는 확정 버튼으로 전송합니다.")
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
                    Button("닫기") { model.decide(false); model.terminal?.disconnect(); dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if info != nil {
                        Button("연결 종료") { model.decide(false); model.terminal?.disconnect(); info = nil }
                    }
                }
            }
            .alert(model.hostChanged ? "서버 키가 변경되었습니다" : "서버 신뢰 확인", isPresented: Binding(get: { model.hostKey != nil }, set: { if !$0 { model.decide(false) } })) {
                if !model.hostChanged { Button("신뢰하고 연결") { model.decide(true) } }
                Button("취소", role: .cancel) { model.decide(false) }
            } message: {
                Text(model.hostChanged ? "저장된 서버 키와 다르므로 연결을 차단했습니다.\n\(model.hostKey ?? "")" : "서버 관리자와 지문을 확인하세요.\n\(model.hostKey ?? "")")
            }
            .onDisappear { model.decide(false); model.terminal?.disconnect() }
            .onChange(of: scenePhase) { phase in
                if phase == .background { model.decide(false); model.terminal?.disconnect() }
            }
        }
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
                Button("연결 종료") { model.decide(false); model.terminal?.disconnect(); info = nil }
                Button("닫기") { model.decide(false); model.terminal?.disconnect(); dismiss() }
            } label: {
                Image(systemName: "ellipsis.circle").font(.body)
            }.accessibilityLabel("터미널 메뉴 및 연결 상태")
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

    private func connect() {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: raw.contains("://") ? raw : "ssh://" + raw),
              url.scheme == "ssh", let host = url.host, !host.isEmpty,
              url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              (1...65535).contains(url.port ?? 22) else {
            error = "SSH 서버 주소와 포트를 확인하세요."; return
        }
        let user = url.user ?? username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty else { error = "사용자 이름을 입력하세요."; return }
        username = user
        error = nil
        info = SSHConnectionInfo(host: host, port: url.port ?? 22, username: user, password: password)
        password = ""
    }
}

private struct TerminalHost: UIViewRepresentable {
    let info: SSHConnectionInfo
    let model: TerminalModel
    let layout: KeyboardLayout
    func makeUIView(context: Context) -> TerminalKeyboardHost {
        let view = SetoTerminal(frame: .zero)
        view.model = model
        model.terminal = view
        view.configureLayout(layout)
        view.refresh()
        let host = TerminalKeyboardHost(terminal: view)
        view.connect(info)
        return host
    }
    func updateUIView(_ uiView: TerminalKeyboardHost, context: Context) { uiView.terminal.configureLayout(layout) }
    static func dismantleUIView(_ uiView: TerminalKeyboardHost, coordinator: ()) { uiView.stopRepeat(); uiView.terminal.disconnect() }
}

final class SetoTerminal: TerminalView, TerminalViewDelegate {
    weak var model: TerminalModel?
    private var connection: SSHConnection?
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
        let identity = "\(info.host):\(info.port)"
        let c = SSHConnection(feedSender: feedSender, host: info.host, port: info.port,
            username: info.username, password: info.password, term: info.term,
            environment: info.environment, initialWindowSize: (80, 24)) { key, promise in
                Task { @MainActor in
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
                (self?.superview as? TerminalKeyboardHost)?.stopRepeat()
                self?.model?.decide(false)
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
    func disconnect() { (superview as? TerminalKeyboardHost)?.stopRepeat(); input.discard(); refresh(); connection?.disconnect(); connection = nil; model?.status = "연결 종료" }
    func refresh() { model?.pending = input.pending; model?.mode = input.mode; model?.automatic = input.automatic }
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
    private var forwarding = false
    private var timer: Timer?
    private var repeated: (Int, UIKeyModifierFlags)?
    private var consumed = Set<Int>()
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
        return [toggle]
    }
    @objc private func keyboardChanged() { stopRepeat(); reloadInputViews() }
    @objc private func toggle() { terminal.toggleMode() }
    override func copy(_ sender: Any?) { terminal.copy(sender) }
    override func paste(_ sender: Any?) { terminal.flushInput(); terminal.paste(sender) }
    override func selectAll(_ sender: Any?) { terminal.selectAll(sender) }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        action == #selector(toggle) || terminal.canPerformAction(action, withSender: sender)
    }
    func stopRepeat() { timer?.invalidate(); timer = nil; repeated = nil }
    private func startRepeat(usage: Int, flags: UIKeyModifierFlags) {
        stopRepeat()
        repeated = (usage, flags)
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let (usage, flags) = self.repeated else { return }
                _ = self.terminal.handleKey(usage: usage, flags: flags)
            }
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
                case .input, .backspace: startRepeat(usage: usage, flags: key.modifierFlags)
                default: break
                }
            } else { rest.insert(press) }
        }
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
        forwarding = true
        terminal.nativeEnded(Set(rest), event: event)
        forwarding = false
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if forwarding { super.pressesCancelled(presses, with: event); return }
        stopRepeat(); consumed.removeAll()
        forwarding = true; terminal.nativeCancelled(presses, event: event); forwarding = false
    }
    override func resignFirstResponder() -> Bool { stopRepeat(); consumed.removeAll(); return super.resignFirstResponder() }
}
