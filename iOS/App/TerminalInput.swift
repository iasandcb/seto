import Foundation

/// Unsent text only: the remote application never receives composition rewrites.
final class TerminalInput {
    static let bundledLexicon: Lexicon = {
        guard let directory = Bundle.main.resourceURL, let lexicon = try? Lexicon.load(from: directory) else {
            return Lexicon(english: [], korean: [])
        }
        return lexicon
    }()
    private let lexicon: Lexicon
    private var session: Session
    private(set) var layout: KeyboardLayout
    var mode: Language { session.mode }
    var pending: String { session.document }
    var automatic: Bool { session.autoSwitch }
    var send: (String) -> Void = { _ in }

    init(lexicon: Lexicon = Lexicon(english: [], korean: []), mode: Language = .korean, automatic: Bool = false, layout: KeyboardLayout = .sebeol390) {
        self.layout = layout
        self.lexicon = lexicon
        session = Session(lexicon: lexicon, autoSwitch: automatic, mode: mode, layout: layout)
        session.correctsTypos = false
    }

    func configure(mode: Language, automatic: Bool, layout: KeyboardLayout? = nil) {
        let newLayout = layout ?? self.layout
        guard mode != session.mode || automatic != session.autoSwitch || newLayout != self.layout else { return }
        flush()
        self.layout = newLayout
        session = Session(lexicon: lexicon, autoSwitch: automatic, mode: mode, layout: newLayout)
        session.correctsTypos = false
    }

    func input(_ character: Character) {
        if mode == .english && !automatic { send(String(character)); return }
        _ = session.input(character)
        // Keep the whole open token locally, including prefixes automatic mode may revise.
        if character == " " || character == "\n" { flush() }
    }

    func backspace() {
        if pending.isEmpty { send("\u{7f}") }
        else { _ = session.backspace() }
    }

    func toggle() { _ = session.toggle() }

    func flush() {
        // Resolve the open word with the same boundary scoring as an ordinary space.
        // Remove only the synthetic delimiter; no remote text is ever rewritten.
        let text: String
        if session.document.isEmpty { text = "" }
        else {
            _ = session.input(" ")
            text = String(session.document.dropLast())
        }
        let mode = session.mode
        let automatic = session.autoSwitch
        session = Session(lexicon: lexicon, autoSwitch: automatic, mode: mode, layout: layout)
        session.correctsTypos = false
        if !text.isEmpty { send(text) }
    }

    func discard() {
        session = Session(lexicon: lexicon, autoSwitch: automatic, mode: mode, layout: layout)
        session.correctsTypos = false
    }
}
