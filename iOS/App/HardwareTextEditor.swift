import SwiftUI
import UIKit
import GameController

/// The containing app receives hardware events; a keyboard extension cannot
/// register a system-wide hardware input method on iOS.
struct HardwareTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    @Binding var mode: Language
    @Binding var automatic: Bool
    var focusOnOpen = false
    @AppStorage("app.hardwareLayout") private var hardwareLayout: KeyboardLayout = .sebeol390

    func makeUIView(context: Context) -> HardwareTextView {
        let view = HardwareTextView()
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.accessibilityLabel = "세토 연습장"
        view.configure(automatic: automatic, mode: mode, layout: hardwareLayout)
        updateCallbacks(view)
        view.focusOnAttachment = focusOnOpen
        return view
    }

    func updateUIView(_ view: HardwareTextView, context: Context) {
        updateCallbacks(view)
        view.configure(automatic: automatic, mode: mode, layout: hardwareLayout)
        if view.text != text {
            view.text = text
            view.resetSession()
        }
        if !focused, view.isFirstResponder { view.resignFirstResponder() }
    }

    private func updateCallbacks(_ view: HardwareTextView) {
        view.onText = { text = $0 }
        view.onFocus = { focused = $0 }
        view.onMode = { mode = $0 }
        view.onAutomatic = { automatic = $0 }
    }
}

@MainActor
final class HardwareTextView: UITextView, UITextViewDelegate {
    private static let lexicon: Lexicon = {
        guard let url = Bundle.main.resourceURL, let lexicon = try? Lexicon.load(from: url) else {
            return Lexicon(english: [], korean: [])
        }
        return lexicon
    }()
    private(set) var session = Session(lexicon: HardwareTextView.lexicon)
    private var expectedText = ""
    private var expectedSelection = NSRange(location: 0, length: 0)
    private var applying = false
    private var consumed: Set<Int> = []
    var focusOnAttachment = false
    var onText: ((String) -> Void)?
    var onFocus: ((Bool) -> Void)?
    var onMode: ((Language) -> Void)?
    var onAutomatic: ((Bool) -> Void)?
    private lazy var softwareInputView = TouchKeyboardInputView(keyboard: touchKeyboard)
    private let hardwareInputView = UIView(frame: .zero)
    private var hardwareKeyboardConnected = false
    var hardwareKeyboardIsConnected: () -> Bool = { GCKeyboard.coalesced != nil }
    private let learnedWords = LearnedWords(defaults: LearnedWords.resolvedDefaults())
    private let touchKeyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 0, height: KeyboardView.preferredHeight))

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        delegate = self
        touchKeyboard.showsInputModeSwitch = false
        touchKeyboard.autoresizingMask = [.flexibleWidth]
        touchKeyboard.configureSuggestions(lexicon: Self.lexicon, learned: learnedWords)
        touchKeyboard.onKey = { [weak self] character in self?.apply { $0.input(LayoutDubeol.atom(for: character)) } }
        touchKeyboard.onLiteral = { [weak self] character in
            guard let self else { return }
            let allows = SuggestionLearning.allows(secureTextEntry: self.isSecureTextEntry, contentType: self.textContentType)
            let prefix = self.caretPrefix()
            self.resetSession()
            self.insertText(String(character))
            if allows, let prefix {
                self.learnedWords.observe(from: prefix, to: prefix + String(character))
            }
            self.resetSession()
            self.onText?(self.text ?? "")
        }
        touchKeyboard.onPhrase = { [weak self] phrase in
            guard let self else { return }
            self.resetSession()
            self.insertText(phrase)
            self.resetSession()
            self.onText?(self.text ?? "")
        }
        touchKeyboard.onDelete = { [weak self] in self?.handleKey(usage: 42) }
        touchKeyboard.onDeleteWord = { [weak self] in self?.deleteWordWave() }
        touchKeyboard.backspaceHasMoreText = { [weak self] in
            guard let self else { return false }
            if self.selectedRange.length > 0 { return true }
            return !(self.text ?? "").isEmpty
        }
        touchKeyboard.onMoveCursor = { [weak self] step, goal in
            self?.moveCursor(by: step.characters, lines: step.lines, goalColumn: goal)
        }
        touchKeyboard.onSuggestion = { [weak self] context, candidate in self?.accept(context, candidate: candidate) }
        touchKeyboard.onToggle = { [weak self] in self?.toggleLanguage() }
        touchKeyboard.onReinterpretWord = { [weak self] in self?.convertOpenWord() }
        touchKeyboard.onAutoSwitch = { [weak self] in
            guard let self else { return }
            self.session.autoSwitch.toggle()
            self.onAutomatic?(self.session.autoSwitch)
            self.refreshKeyboard()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(hardwareKeyboardChanged), name: .GCKeyboardDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(hardwareKeyboardChanged), name: .GCKeyboardDidDisconnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(hardwareKeyboardChanged), name: UIApplication.didBecomeActiveNotification, object: nil)
        inputView = softwareInputView
        setHardwareKeyboardConnected(hardwareKeyboardIsConnected())
        refreshKeyboard()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, focusOnAttachment else { return }
        focusOnAttachment = false
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            _ = self.becomeFirstResponder()
        }
    }

    @objc private func hardwareKeyboardChanged() {
        setHardwareKeyboardConnected(hardwareKeyboardIsConnected())
    }

    /// Swap only the input view; keep focus, selection, and composition intact.
    func setHardwareKeyboardConnected(_ connected: Bool) {
        guard hardwareKeyboardConnected != connected else { return }
        hardwareKeyboardConnected = connected
        if !connected { softwareInputView.prepare(bottomInset: window?.safeAreaInsets.bottom ?? 0) }
        inputView = connected ? hardwareInputView : softwareInputView
        if isFirstResponder { reloadInputViews() }
    }

    override func becomeFirstResponder() -> Bool {
        setHardwareKeyboardConnected(hardwareKeyboardIsConnected())
        (inputView as? TouchKeyboardInputView)?.prepare(bottomInset: window?.safeAreaInsets.bottom ?? 0)
        return super.becomeFirstResponder()
    }

    override var keyCommands: [UIKeyCommand]? {
        let toggle = UIKeyCommand(input: " ", modifierFlags: .shift, action: #selector(toggleLanguage))
        toggle.discoverabilityTitle = "세토 한/영 전환 · 자동 변환 되돌리기"
        toggle.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [toggle]
    }

    @objc private func toggleLanguage() { apply { $0.toggle() } }

    /// ※ long-press. Same replacement path as a key, so an open syllable is
    /// rewritten in place and the session's composition matches the field.
    private func convertOpenWord() { apply { $0.convertOpenWord() } }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key != nil }) { setHardwareKeyboardConnected(true) }
        var remaining = Set<UIPress>()
        for press in presses {
            guard let key = press.key else { remaining.insert(press); continue }
            guard handleKey(usage: key.keyCode.rawValue, flags: key.modifierFlags) else {
                remaining.insert(press)
                continue
            }
            consumed.insert(key.keyCode.rawValue)
        }
        if !remaining.isEmpty { super.pressesBegan(remaining, with: event) }
    }

    /// Shared entry point for event delivery and UIKit integration tests.
    @discardableResult
    func handleKey(usage: Int, flags: UIKeyModifierFlags = []) -> Bool {
        let action = HardwareKeymap.action(
            usage: usage, shift: flags.contains(.shift),
            command: flags.contains(.command), control: flags.contains(.control),
            option: flags.contains(.alternate)
        )
        switch action {
        case .input(let character): inputCharacter(character)
        case .toggle: toggleLanguage()
        case .backspace:
            synchronize()
            if selectedRange.length > 0 || session.document.isEmpty {
                resetSession()
                deleteBackward()
                resetSession()
                onText?(text ?? "")
            } else { apply { $0.backspace() } }
        case .passThrough:
            // Modifier-only events must retain composition and pending undo.
            if !(224...231).contains(usage), usage != 57 { resetSession() }
            return false
        }
        return true
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = presses.filter { press in
            guard let key = press.key else { return true }
            return consumed.remove(key.keyCode.rawValue) == nil
        }
        if !remaining.isEmpty { super.pressesEnded(remaining, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses { if let key = press.key { consumed.remove(key.keyCode.rawValue) } }
        super.pressesCancelled(presses, with: event)
    }

    func configure(automatic: Bool, mode: Language, layout: KeyboardLayout = .sebeol390) {
        if session.layout != layout {
            _ = session.commitDisplayed(endingRun: true)
            session = Session(lexicon: Self.lexicon, autoSwitch: automatic, mode: mode, layout: layout)
            expectedText = text ?? ""
            expectedSelection = selectedRange
        }
        session.autoSwitch = automatic
        if session.mode != mode { _ = session.forceMode(mode) }
        refreshKeyboard()
    }

    func inputCharacter(_ character: Character) { apply { $0.input(character) } }

    private func refreshKeyboard() {
        touchKeyboard.update(mode: session.mode, automatic: session.autoSwitch)
        let allows = SuggestionLearning.allows(secureTextEntry: isSecureTextEntry, contentType: textContentType)
        touchKeyboard.setLearnedWords(allows ? learnedWords : nil)
        touchKeyboard.updateSuggestionContext(session.document.isEmpty ? nil : suggestionContext())
    }

    private func suggestionContext() -> WordSuggestionContext? {
        let source = (text ?? "") as NSString
        let caret = selectedRange.location
        guard selectedRange.length == 0, caret != NSNotFound, caret <= source.length else { return nil }
        return WordSuggestionContext.forComposition(
            before: source.substring(to: caret),
            after: source.substring(from: caret),
            allowNextWord: true
        )
    }

    private func caretPrefix() -> String? {
        let source = (text ?? "") as NSString
        let range = selectedRange
        guard range.length == 0, range.location != NSNotFound, range.location <= source.length else { return nil }
        return source.substring(to: range.location)
    }

    private func accept(_ context: WordSuggestionContext, candidate: String) {
        guard suggestionContext() == context else { resetSession(); return }
        let length = (context.word as NSString).length
        let range = NSRange(location: selectedRange.location - length, length: length)
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let replacement = textRange(from: start, to: end) else { resetSession(); return }
        applying = true
        unmarkText()
        replace(replacement, withText: candidate)
        applying = false
        resetSession()
        onText?(text ?? "")
    }

    /// Space-drag cursor movement: steps over composed characters sideways and
    /// to the visually nearest column on the adjacent line vertically, using
    /// the same rule as the keyboard extension. Collapses any selection and
    /// commits the current composition by starting a new session.
    @discardableResult
    func moveCursor(by characters: Int, lines: Int = 0, goalColumn: Int? = nil) -> Int? {
        let source = (text ?? "") as NSString
        let selection = selectedRange
        let step = CursorStep(characters: characters, lines: lines)
        guard !step.isZero, selection.location != NSNotFound,
              selection.location + selection.length <= source.length else { return goalColumn }
        unmarkText()
        let backward = lines < 0 || (lines == 0 && characters < 0)
        let anchor = backward ? selection.location : selection.location + selection.length
        let motion = CursorMotion.resolve(
            before: source.substring(to: anchor), after: source.substring(from: anchor),
            step: step, goalColumn: goalColumn
        )
        selectedRange = NSRange(location: anchor + motion.utf16Offset, length: 0)
        resetSession()
        scrollRangeToVisible(selectedRange)
        return motion.goalColumn
    }

    /// One held-backspace word wave. An open syllable stays on the single
    /// backspace path, so it still loses one jamo instead of the whole syllable.
    private func deleteWordWave() {
        synchronize()
        let selection = selectedRange
        let source = (text ?? "") as NSString
        let context: String?
        if selection.length == 0, selection.location != NSNotFound, selection.location <= source.length {
            context = source.substring(to: selection.location)
        } else {
            context = nil
        }
        let plan = WordDeletion.plan(
            contextBefore: context,
            sessionDocument: session.document,
            composing: !session.preedit.isEmpty,
            selection: selection.length > 0
        )
        guard !plan.single else {
            handleKey(usage: 42)
            return
        }
        let suffixCount = plan.sessionBackspaces + plan.hostBackspaces
        let beforeCaretCount = context?.count ?? 0
        if plan.sessionBackspaces > 0 {
            apply { session in
                var update = session.backspace()
                var steps = 1
                while steps < plan.sessionBackspaces, session.preedit.isEmpty {
                    let mid = session.document
                    let next = session.backspace()
                    guard session.document != mid else { break }
                    update = next
                    steps += 1
                }
                return update
            }
        }
        guard session.preedit.isEmpty, let afterContext = caretPrefix() else { return }
        let removed = max(0, beforeCaretCount - afterContext.count)
        guard removed > 0 || plan.sessionBackspaces == 0 else { return }
        let hostDeletes = suffixCount - removed
        guard hostDeletes > 0, session.document.isEmpty else { return }
        for _ in 0..<hostDeletes { deleteBackward() }
        resetSession()
        onText?(text ?? "")
    }

    func resetSession() {
        let correctsTypos = session.correctsTypos
        session = Session(lexicon: Self.lexicon, autoSwitch: session.autoSwitch, mode: session.mode, layout: session.layout)
        session.correctsTypos = correctsTypos
        refreshKeyboard()
        expectedText = text ?? ""
        expectedSelection = selectedRange
    }

    private func synchronize() {
        if text != expectedText || selectedRange != expectedSelection || markedTextRange != nil {
            unmarkText()
            resetSession()
        }
    }

    private func apply(_ operation: (Session) -> SessionUpdate) {
        synchronize()
        let before = session.document
        let update = operation(session)
        let change = KeyboardReplacement.between(before, session.document)
        let removedLength = (change.removed as NSString).length
        let selection = selectedRange
        let source = (text ?? "") as NSString
        guard selection.location != NSNotFound, selection.location >= removedLength,
              selection.location + selection.length <= source.length else { resetSession(); return }
        let range = NSRange(location: selection.location - removedLength, length: removedLength + selection.length)
        guard source.substring(with: NSRange(location: range.location, length: removedLength)) == change.removed,
              let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let replacement = textRange(from: start, to: end) else { resetSession(); return }
        let oldPrefix = source.substring(to: selection.location)
        let newPrefix = source.substring(to: selection.location - removedLength) + change.inserted
        applying = true
        // A mode toggle alone must preserve a user's selection.
        if before != session.document { replace(replacement, withText: change.inserted) }
        applying = false
        if before != session.document,
           SuggestionLearning.allows(secureTextEntry: isSecureTextEntry, contentType: textContentType) {
            learnedWords.observe(from: oldPrefix, to: newPrefix)
        }
        expectedText = text ?? ""
        expectedSelection = selectedRange
        onText?(expectedText)
        onMode?(update.mode)
        refreshKeyboard()
        if session.document.count > 512, session.preedit.isEmpty { resetSession() }
    }

    func textViewDidChange(_ textView: UITextView) {
        if !applying { resetSession(); onText?(text ?? "") }
    }
    func textViewDidChangeSelection(_ textView: UITextView) {
        if !applying { resetSession() }
    }
    func textViewDidBeginEditing(_ textView: UITextView) { resetSession(); onFocus?(true) }
    func textViewDidEndEditing(_ textView: UITextView) {
        touchKeyboard.cancelBackspaceHold()
        resetSession(); consumed.removeAll(); onFocus?(false)
    }
}

/// UIKit must reserve the full key height plus the home-indicator safe area.
@MainActor
final class TouchKeyboardInputView: UIInputView {
    let keyboard: KeyboardView
    private var bottomPadding: CGFloat = 0
    private var keyboardHeight: NSLayoutConstraint!

    init(keyboard: KeyboardView) {
        self.keyboard = keyboard
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: KeyboardView.preferredHeight), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = [.flexibleWidth]
        keyboardHeight = heightAnchor.constraint(equalToConstant: KeyboardView.preferredHeight)
        keyboardHeight.priority = .init(999)
        keyboardHeight.isActive = true
        keyboard.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keyboard)
        NSLayoutConstraint.activate([
            keyboard.leadingAnchor.constraint(equalTo: leadingAnchor),
            keyboard.trailingAnchor.constraint(equalTo: trailingAnchor),
            keyboard.topAnchor.constraint(equalTo: topAnchor),
            keyboard.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func prepare(bottomInset: CGFloat) {
        bottomPadding = max(0, bottomInset)
        keyboardHeight.constant = fittedHeight
        frame.size.height = fittedHeight
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private var fittedHeight: CGFloat {
        KeyboardView.preferredHeight + bottomPadding
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: fittedHeight)
    }

    override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
        CGSize(width: targetSize.width, height: fittedHeight)
    }

    override func systemLayoutSizeFitting(_ targetSize: CGSize, withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority, verticalFittingPriority: UILayoutPriority) -> CGSize {
        systemLayoutSizeFitting(targetSize)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        let inset = max(safeAreaInsets.bottom, window?.safeAreaInsets.bottom ?? 0)
        if inset != bottomPadding { prepare(bottomInset: inset) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window { prepare(bottomInset: max(safeAreaInsets.bottom, window.safeAreaInsets.bottom)) }
    }
}
