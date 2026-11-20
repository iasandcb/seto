import Foundation
@_exported import SetoSupport
import seto_ffi

public enum Language: String, Equatable, Sendable {
    case korean
    case english

    public var flipped: Language { self == .korean ? .english : .korean }
}

/// What the field should do with this key. Confirmed English is ordinary
/// text. Hangul and undecided shifted punctuation stay in composition.
public enum FieldEdit: Equatable, Sendable {
    case none
    case unmark(String)
    case insert(String)
    case mark(String)
    case replaceBeforeCaret(utf16: Int, text: String)
    case insertThenMark(insert: String, mark: String)
    case insertReplacing(utf16: Int, text: String)
    case insertReplacingThenMark(utf16: Int, insert: String, mark: String)
    case clearMarkThenInsert(utf16: Int, text: String)
    case clearMarkThenMark(utf16: Int, text: String)
    case rewrite(utf16: Int, text: String, thenMark: String)

    public var preservesCharacters: Bool {
        switch self {
        case .none, .unmark:
            return true
        default:
            return false
        }
    }

    var sendsMoreThanOneEdit: Bool {
        switch self {
        case .insertThenMark, .insertReplacingThenMark, .clearMarkThenInsert, .clearMarkThenMark:
            return true
        case .rewrite(_, _, let thenMark):
            return !thenMark.isEmpty
        default:
            return false
        }
    }
}

public struct SessionUpdate: Equatable, Sendable {
    public var mode: Language
    public var didAutoConvert: Bool
    public var preedit: String
    public var field: FieldEdit
}

public enum InputGate {
    public static func shouldPassThrough(secureInput: Bool, command: Bool, control: Bool, option: Bool) -> Bool {
        secureInput || command || control || option
    }
}

public enum CompositionPiece: Equatable, Sendable {
    case syllable
    case bareChoseong
    case bareJungseong
    case bareJongseong
    case digit
    case symbol
}

public struct Composition: Equatable, Sendable {
    public var text: String
    public var pieces: [CompositionPiece]

    public var syllableCount: Int {
        pieces.reduce(0) { $0 + ($1 == .syllable ? 1 : 0) }
    }
}

/// Rust `Composer`.
public enum Composer {
    static func preservesBoundary(_ index: Int, in atoms: [KeyAtom]) -> Bool {
        let value = UInt32(exactly: index) ?? 0
        return must { try seto_ffi.boundaryPreserved(index: value, keys: atoms.map(ffiAtom)) }
    }

    public static func compose<S: Sequence>(_ atoms: S) -> Composition where S.Element == KeyAtom {
        let composed = must { try seto_ffi.composeAtoms(keys: atoms.map(ffiAtom)) }
        return Composition(text: composed.text, pieces: composed.pieces.map(piece))
    }

    public static func jamoSequence<S: Sequence>(_ atoms: S) -> [Jamo]? where S.Element == KeyAtom {
        must { try seto_ffi.sequenceJamo(keys: atoms.map(ffiAtom)) }?.map { bits in
            Jamo(scalar: bits.scalar, kind: jamoKind(bits.position))
        }
    }
}

/// Rust `TypoCorrector`. Word lists still come from the Swift `Lexicon` the caller already built.
public enum TypoCorrector {
    public static func correction(
        composed: String,
        keys: [KeyAtom],
        language: Language,
        lexicon: Lexicon,
        memory: (any TypoMemory)?
    ) -> String? {
        let bridge = memory.map(TypoBridge.init)
        return must {
            try seto_ffi.correctTypo(
                composed: composed,
                keys: keys.map(ffiAtom),
                language: ffiLanguage(language),
                lexicon: LexiconCache.shared.lexicon(for: lexicon),
                memory: bridge
            )
        }
    }

    static func keystrokes(for word: String, layout: KeyboardLayout) -> String? {
        seto_ffi.keystrokesFor(word: word, layout: layoutKind(layout))
    }
}

enum KoreanEndings {
    static let longestFirst = seto_ffi.koreanEndingTable()
    static let set = Set(longestFirst)

    static func split(_ word: String) -> (stem: String, ending: String)? {
        guard let split = seto_ffi.splitKoreanEnding(word: word) else { return nil }
        return (split.stem, split.ending)
    }
}

enum KoreanVerbEndings {
    static let longestFirst = seto_ffi.verbEndingTable()

    static func isInflected(_ word: String, isKnown: (String) -> Bool) -> Bool {
        // Rust calls the predicate before returning and then drops it. The
        // closure does not outlive this function; StemProbe only stores it so
        // UniFFI can pass a class callback.
        withoutActuallyEscaping(isKnown) { escaping in
            seto_ffi.verbIsInflected(word: word, known: StemProbe(escaping))
        }
    }
}

/// One field. Composition, auto-switch, and typo correction run in the Rust `FieldSession`.
public final class Session {
    public let layout: KeyboardLayout
    public var autoSwitch: Bool {
        didSet { if configured { pushOptions() } }
    }
    public var correctsTypos = true {
        didSet { if configured { pushOptions() } }
    }
    public private(set) var mode: Language
    public private(set) var preedit = ""
    public private(set) var document = ""
    public private(set) var debugLine = ""

    private let rust: seto_ffi.FieldSession
    private let bridge: TypoBridge?
    /// didSet must not touch Rust while `init` is still assigning stored properties.
    private var configured = false

    public init(
        lexicon: Lexicon,
        autoSwitch: Bool = true,
        mode: Language = .korean,
        typos: (any TypoMemory)? = nil,
        layout: KeyboardLayout = .sebeol390
    ) {
        self.layout = layout
        self.autoSwitch = autoSwitch
        self.mode = mode
        let bridge = typos.map(TypoBridge.init)
        self.bridge = bridge
        rust = seto_ffi.FieldSession.open(
            lexicon: LexiconCache.shared.lexicon(for: lexicon),
            autoSwitch: autoSwitch,
            mode: ffiLanguage(mode),
            layout: layoutKind(layout),
            store: bridge
        )
        refresh()
        configured = true
    }

    public func input(_ english: Character) -> SessionUpdate {
        step { try rust.input(character: String(english)) }
    }

    public func input(_ atom: KeyAtom) -> SessionUpdate {
        step { try rust.inputAtom(atom: ffiAtom(atom)) }
    }

    public func backspace() -> SessionUpdate {
        step { try rust.backspace() }
    }

    public func toggle() -> SessionUpdate {
        step { try rust.toggle() }
    }

    public func convertOpenWord() -> SessionUpdate {
        step { try rust.convertOpenWord() }
    }

    public func commitDisplayed(endingRun: Bool = false) -> SessionUpdate {
        step { try rust.commitDisplayed(endingRun: endingRun) }
    }

    public func forceMode(_ language: Language) -> SessionUpdate {
        step { try rust.forceMode(mode: ffiLanguage(language)) }
    }

    public func discard() -> SessionUpdate {
        step { try rust.discard() }
    }

    private func step(_ body: () throws -> seto_ffi.SessionUpdate) -> SessionUpdate {
        let update = must(body)
        refresh()
        return SessionUpdate(
            mode: coreLanguage(update.mode),
            didAutoConvert: update.didAutoConvert,
            preedit: update.preedit,
            field: field(update.field)
        )
    }

    private func refresh() {
        withExtendedLifetime(bridge) {}
        let state = must { try rust.state() }
        mode = coreLanguage(state.mode)
        preedit = state.preedit
        document = state.document
        debugLine = must { try rust.debugLine() }
    }

    private func pushOptions() {
        must { try rust.setOptions(autoSwitch: autoSwitch, correctsTypos: correctsTypos) }
    }
}

private final class TypoBridge: seto_ffi.TypoStore, @unchecked Sendable {
    let memory: any TypoMemory
    init(_ memory: any TypoMemory) { self.memory = memory }
    func record(wrong: String, wrongKeys: String, finalText: String, finalKeys: String) {
        memory.record(wrong: wrong, wrongKeys: wrongKeys, final: finalText, finalKeys: finalKeys)
    }
    func uniqueFinal(wrong: String) -> String? {
        memory.uniqueFinal(for: wrong)
    }
}

private final class StemProbe: seto_ffi.KnownStem, @unchecked Sendable {
    let probe: (String) -> Bool
    init(_ probe: @escaping (String) -> Bool) { self.probe = probe }
    func isKnown(word: String) -> Bool { probe(word) }
}

private final class LexiconBox {
    weak var lexicon: Lexicon?
    let rust: seto_ffi.SharedLexicon
    init(_ lexicon: Lexicon, _ rust: seto_ffi.SharedLexicon) {
        self.lexicon = lexicon
        self.rust = rust
    }
}

private final class LexiconCache: @unchecked Sendable {
    static let shared = LexiconCache()
    private let lock = NSLock()
    /// Weak keys. `ObjectIdentifier` is the instance address, and a later
    /// `Lexicon` can be allocated there after the previous one is freed.
    /// Keeping the Rust lexicon under that address fed the new word list the
    /// previous dictionary, so typo correction and English heads went stale.
    private var entries: [LexiconBox] = []

    func lexicon(for lexicon: Lexicon) -> seto_ffi.SharedLexicon {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.lexicon == nil }
        if let cached = entries.first(where: { $0.lexicon === lexicon }) {
            return cached.rust
        }
        let made = Self.make(lexicon)
        entries.append(LexiconBox(lexicon, made))
        return made
    }

    private static func make(_ lexicon: Lexicon) -> seto_ffi.SharedLexicon {
        switch lexicon.origin {
        case .files(let directory):
            return must { try seto_ffi.SharedLexicon.fromDirectory(directory: directory.path) }
        case .keyboard(let directory):
            return must { try seto_ffi.SharedLexicon.forKeyboard(directory: directory.path) }
        case .words(let english, let korean, let abbreviations, let techStems, let validKorean):
            return seto_ffi.SharedLexicon.fromLists(
                english: english, korean: korean, abbreviations: abbreviations,
                techStems: techStems, validKorean: validKorean)
        @unknown default:
            fatalError("세토 Rust 코어: 알 수 없는 사전 출처")
        }
    }
}

private func must<T>(_ body: () throws -> T) -> T {
    do { return try body() }
    catch { fatalError("세토 Rust 코어: \(error)") }
}

private func span(_ value: UInt64) -> Int {
    guard let span = Int(exactly: value) else { fatalError("UTF-16 span does not fit in Int") }
    return span
}

private func ffiLanguage(_ language: Language) -> seto_ffi.Language {
    switch language {
    case .korean: return .korean
    case .english: return .english
    }
}

private func coreLanguage(_ language: seto_ffi.Language) -> Language {
    switch language {
    case .korean: return .korean
    case .english: return .english
    @unknown default: fatalError("세토 Rust 코어: 알 수 없는 언어")
    }
}

private func layoutKind(_ layout: KeyboardLayout) -> seto_ffi.LayoutKind {
    switch layout {
    case .sebeol390: return .sebeol390
    case .dubeol: return .dubeol
    case .sebeolFinal: return .sebeolFinal
    }
}

private func jamoKind(_ position: seto_ffi.JamoPosition) -> JamoKind {
    switch position {
    case .choseong: return .choseong
    case .jungseong: return .jungseong
    case .jongseong: return .jongseong
    @unknown default: fatalError("세토 Rust 코어: 알 수 없는 자모")
    }
}

private func position(_ kind: JamoKind) -> seto_ffi.JamoPosition {
    switch kind {
    case .choseong: return .choseong
    case .jungseong: return .jungseong
    case .jongseong: return .jongseong
    }
}

private func piece(_ value: seto_ffi.Piece) -> CompositionPiece {
    switch value {
    case .syllable: return .syllable
    case .bareChoseong: return .bareChoseong
    case .bareJungseong: return .bareJungseong
    case .bareJongseong: return .bareJongseong
    case .digit: return .digit
    case .symbol: return .symbol
    @unknown default: fatalError("세토 Rust 코어: 알 수 없는 조합 조각")
    }
}

private func ffiAtom(_ atom: KeyAtom) -> seto_ffi.Atom {
    let korean: seto_ffi.AtomReading
    switch atom.korean {
    case .jamo(let jamo):
        korean = .jamo(scalar: jamo.scalar, position: position(jamo.kind))
    case .character(let character):
        korean = .character(value: String(character))
    }
    return seto_ffi.Atom(layout: layoutKind(atom.layout), english: String(atom.english), korean: korean)
}

private func field(_ edit: seto_ffi.FieldEdit) -> FieldEdit {
    switch edit {
    case .none:
        return .none
    case .unmark(let text):
        return .unmark(text)
    case .insert(let text):
        return .insert(text)
    case .mark(let text):
        return .mark(text)
    case .replaceBeforeCaret(let utf16, let text):
        return .replaceBeforeCaret(utf16: span(utf16), text: text)
    case .insertThenMark(let insert, let mark):
        return .insertThenMark(insert: insert, mark: mark)
    case .insertReplacing(let utf16, let text):
        return .insertReplacing(utf16: span(utf16), text: text)
    case .insertReplacingThenMark(let utf16, let insert, let mark):
        return .insertReplacingThenMark(utf16: span(utf16), insert: insert, mark: mark)
    case .clearMarkThenInsert(let utf16, let text):
        return .clearMarkThenInsert(utf16: span(utf16), text: text)
    case .clearMarkThenMark(let utf16, let text):
        return .clearMarkThenMark(utf16: span(utf16), text: text)
    case .rewrite(let utf16, let text, let thenMark):
        return .rewrite(utf16: span(utf16), text: text, thenMark: thenMark)
    @unknown default:
        fatalError("세토 Rust 코어: 알 수 없는 편집")
    }
}
