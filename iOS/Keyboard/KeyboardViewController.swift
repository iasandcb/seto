import UIKit

@MainActor
final class KeyboardViewController: UIInputViewController {
    private static let lexicon: Lexicon = {
        guard let url = Bundle.main.resourceURL, let lexicon = try? Lexicon.loadForKeyboard(from: url) else {
            return Lexicon(english: [], korean: [])
        }
        return lexicon
    }()
    private var session = Session(lexicon: KeyboardViewController.lexicon, layout: .dubeol)
    private var expectedContext: String?
    private let keyboard = KeyboardView()

    override func viewDidLoad() {
        super.viewDidLoad()
        keyboard.configureSuggestions(lexicon: Self.lexicon)
        keyboard.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboard)
        NSLayoutConstraint.activate([
            keyboard.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboard.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboard.topAnchor.constraint(equalTo: view.topAnchor),
            keyboard.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.heightAnchor.constraint(equalToConstant: KeyboardView.preferredHeight)
        ])
        keyboard.onKey = { [weak self] key in self?.edit { $0.input(LayoutDubeol.atom(for: key)) } }
        keyboard.onLiteral = { [weak self] key in
            guard let self else { return }
            self.textDocumentProxy.insertText(String(key))
            self.reset()
        }
        keyboard.onPhrase = { [weak self] phrase in
            guard let self else { return }
            self.synchronize()
            self.textDocumentProxy.insertText(phrase)
            self.reset()
        }
        keyboard.onDelete = { [weak self] in self?.delete() }
        keyboard.onSuggestion = { [weak self] context, candidate in self?.accept(context, candidate: candidate) }
        keyboard.onToggle = { [weak self] in self?.edit { $0.toggle() } }
        keyboard.onNext = { [weak self] button, event in
            self?.handleInputModeList(from: button, with: event)
        }
        keyboard.onAutoSwitch = { [weak self] in
            guard let self else { return }
            self.session.autoSwitch.toggle()
            UserDefaults.standard.set(self.session.autoSwitch, forKey: "autoSwitch")
            self.reset()
        }
        keyboard.showsInputModeSwitch = needsInputModeSwitchKey
        reset()
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        synchronize()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        reset()
    }

    private func synchronize() {
        // documentIdentifier may be nil in UIKit before the host attaches even
        // though Swift imports it as nonoptional UUID. Accessing it traps.
        if expectedContext != textDocumentProxy.documentContextBeforeInput ||
            !(textDocumentProxy.selectedText ?? "").isEmpty {
            reset()
        }
    }

    private func reset() {
        let automatic = UserDefaults.standard.object(forKey: "autoSwitch") as? Bool ?? true
        session = Session(lexicon: Self.lexicon, autoSwitch: automatic, mode: session.mode, layout: .dubeol)
        expectedContext = textDocumentProxy.documentContextBeforeInput
        keyboard.update(mode: session.mode, automatic: automatic)
        keyboard.updateSuggestionContext(nil)
    }

    private func accept(_ context: WordSuggestionContext, candidate: String) {
        guard textDocumentProxy.documentContextBeforeInput == context.before,
              textDocumentProxy.documentContextAfterInput == context.after,
              (textDocumentProxy.selectedText ?? "").isEmpty else { reset(); return }
        for _ in context.word { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(candidate)
        reset()
    }

    private func delete() {
        synchronize()
        if session.document.isEmpty {
            textDocumentProxy.deleteBackward()
            reset()
        } else {
            edit { $0.backspace() }
        }
    }

    private func edit(_ operation: (Session) -> SessionUpdate) {
        synchronize()
        let before = session.document
        let update = operation(session)
        let after = session.document
        // UIKit has no marked-text API for keyboard extensions. Replace only
        // the changed grapheme suffix owned by this session.
        let change = KeyboardReplacement.between(before, after)
        let context = textDocumentProxy.documentContextBeforeInput
        if change.deleteCount > 0 {
            guard let context, context.hasSuffix(change.removed) else {
                reset()
                return
            }
            for _ in 0..<change.deleteCount { textDocumentProxy.deleteBackward() }
        }
        if !change.inserted.isEmpty { textDocumentProxy.insertText(change.inserted) }
        expectedContext = textDocumentProxy.documentContextBeforeInput
        keyboard.update(mode: update.mode, automatic: session.autoSwitch)
        keyboard.updateSuggestionContext(after.isEmpty || !(textDocumentProxy.selectedText ?? "").isEmpty ? nil :
            WordSuggestionContext(before: expectedContext, after: textDocumentProxy.documentContextAfterInput))
        // Bound memory to the current word and its undo window.
        if after.count > 512, session.preedit.isEmpty { reset() }
    }
}
