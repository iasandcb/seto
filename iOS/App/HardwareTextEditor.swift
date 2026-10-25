import SwiftUI
import UIKit

/// The containing app receives hardware events; a keyboard extension cannot
/// register a system-wide hardware input method on iOS.
struct HardwareTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    @Binding var modeLabel: String

    func makeUIView(context: Context) -> HardwareTextView {
        let view = HardwareTextView()
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.accessibilityLabel = "세벌식 연습장"
        updateCallbacks(view)
        return view
    }

    func updateUIView(_ view: HardwareTextView, context: Context) {
        updateCallbacks(view)
        if view.text != text {
            view.text = text
            view.resetSession()
        }
        if !focused, view.isFirstResponder { view.resignFirstResponder() }
    }

    private func updateCallbacks(_ view: HardwareTextView) {
        view.onText = { text = $0 }
        view.onFocus = { focused = $0 }
        view.onMode = { modeLabel = $0 }
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
    private var session = Session(lexicon: HardwareTextView.lexicon)
    private var expectedText = ""
    private var expectedSelection = NSRange(location: 0, length: 0)
    private var applying = false
    private var consumed: Set<Int> = []
    var onText: ((String) -> Void)?
    var onFocus: ((Bool) -> Void)?
    var onMode: ((String) -> Void)?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var keyCommands: [UIKeyCommand]? {
        let toggle = UIKeyCommand(input: " ", modifierFlags: .shift, action: #selector(toggleLanguage))
        toggle.discoverabilityTitle = "세토 한/영 전환 · 자동 변환 되돌리기"
        toggle.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [toggle]
    }

    @objc private func toggleLanguage() { apply { $0.toggle() } }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
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
        case .input(let character): apply { $0.input(character) }
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

    func resetSession() {
        session = Session(lexicon: Self.lexicon, mode: session.mode)
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
        applying = true
        // A mode toggle alone must preserve a user's selection.
        if before != session.document { replace(replacement, withText: change.inserted) }
        applying = false
        expectedText = text ?? ""
        expectedSelection = selectedRange
        onText?(expectedText)
        onMode?(update.mode == .korean ? "한글" : "영문")
        if session.document.count > 512, session.preedit.isEmpty { resetSession() }
    }

    func textViewDidChange(_ textView: UITextView) {
        if !applying { resetSession(); onText?(text ?? "") }
    }
    func textViewDidChangeSelection(_ textView: UITextView) {
        if !applying { resetSession() }
    }
    func textViewDidBeginEditing(_ textView: UITextView) { resetSession(); onFocus?(true) }
    func textViewDidEndEditing(_ textView: UITextView) { resetSession(); consumed.removeAll(); onFocus?(false) }
}
