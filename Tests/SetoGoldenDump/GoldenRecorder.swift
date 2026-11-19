// Golden corpus dumper for the shared Rust core.
//
// This target is only part of the package when SETO_GOLDEN_DUMP is set, so a
// plain `swift test` never builds it or rewrites the corpus. Regenerate with:
//
//     SETO_GOLDEN_DUMP=1 swift test --filter SetoGoldenDump
//
// The other files in this directory are symlinks to the real test files.
// Inside this module, `Session` and `Lexicon` below shadow the oracle types:
// each wrapper forwards every call to the real `SetoOracle.Session` /
// `SetoSupport.Lexicon` and records the key, the returned `SessionUpdate`, and
// the session state after it. The Swift oracle is not changed.
//
// Output: core-rs/testdata/session-golden.json (override with SETO_GOLDEN_OUT).

import Foundation
import SetoSupport
import Testing
@testable import SetoOracle

// MARK: - Shadow Lexicon

/// Records how the lexicon was built so a replay can rebuild the same one.
final class Lexicon: @unchecked Sendable {
    let real: SetoSupport.Lexicon
    let spec: GoldenLexicon

    private init(real: SetoSupport.Lexicon, spec: GoldenLexicon) {
        self.real = real
        self.spec = spec
    }

    convenience init(
        english: [String],
        korean: [String],
        abbreviations: [String] = [],
        techStems: [String] = [],
        validKorean: [String] = []
    ) {
        self.init(
            real: SetoSupport.Lexicon(english: english, korean: korean, abbreviations: abbreviations,
                                   techStems: techStems, validKorean: validKorean),
            spec: GoldenLexicon(kind: "words", english: english, korean: korean,
                                abbreviations: abbreviations, techStems: techStems, validKorean: validKorean)
        )
    }

    static func load(from directory: URL) throws -> Lexicon {
        Lexicon(real: try SetoSupport.Lexicon.load(from: directory), spec: GoldenLexicon(kind: "resources"))
    }

    static func loadForKeyboard(from directory: URL) throws -> Lexicon {
        Lexicon(real: try SetoSupport.Lexicon.loadForKeyboard(from: directory), spec: GoldenLexicon(kind: "keyboard"))
    }

    static var defaultAbbreviations: [String] { SetoSupport.Lexicon.defaultAbbreviations }
    static var defaultTechStems: [String] { SetoSupport.Lexicon.defaultTechStems }

    func isEnglishWord(_ word: String) -> Bool { real.isEnglishWord(word) }
    func isEnglishPrefix(_ prefix: String) -> Bool { real.isEnglishPrefix(prefix) }
    func englishCompletions(_ prefix: String, limit: Int = 256) -> [String] { real.englishCompletions(prefix, limit: limit) }
    func isKoreanWord(_ word: String) -> Bool { real.isKoreanWord(word) }
    func isValidKorean(_ word: String) -> Bool { real.isValidKorean(word) }
    var koreanWordCount: Int { real.koreanWordCount }
    var validKoreanWordCount: Int { real.validKoreanWordCount }
    func koreanWords() -> [String] { real.koreanWords() }
    func englishWords(length: ClosedRange<Int>) -> [String] { real.englishWords(length: length) }
    func isAbbreviation(_ text: String) -> Bool { real.isAbbreviation(text) }
    func isCodeToken(_ text: String) -> Bool { real.isCodeToken(text) }
}

extension TypoCorrector {
    static func correction(
        composed: String, keys: [KeyAtom], language: Language, lexicon: Lexicon, memory: (any TypoMemory)?
    ) -> String? {
        correction(composed: composed, keys: keys, language: language, lexicon: lexicon.real, memory: memory)
    }
}

// MARK: - Shadow Session

/// Forwards to `SetoOracle.Session` and records one golden step per call.
final class Session {
    private let real: SetoOracle.Session
    private let scenario: GoldenScenario

    init(
        lexicon: Lexicon,
        autoSwitch: Bool = true,
        mode: Language = .korean,
        typos: (any TypoMemory)? = nil,
        layout: KeyboardLayout = .sebeol390,
        _file: String = #fileID,
        _line: Int = #line
    ) {
        let scenario = GoldenRecorder.shared.begin(
            config: GoldenConfig(
                layout: layout.rawValue,
                autoSwitch: autoSwitch,
                mode: mode.rawValue,
                correctsTypos: true,
                lexicon: lexicon.spec,
                typos: typos.map(GoldenTypos.init(memory:))
            ),
            source: "\((_file as NSString).lastPathComponent):\(_line)"
        )
        self.scenario = scenario
        let proxy = typos.map { RecordingTypos(inner: $0, scenario: scenario) }
        real = SetoOracle.Session(lexicon: lexicon.real, autoSwitch: autoSwitch, mode: mode, typos: proxy, layout: layout)
    }

    var layout: KeyboardLayout { real.layout }
    var mode: Language { real.mode }
    var preedit: String { real.preedit }
    var document: String { real.document }
    var debugLine: String { real.debugLine }

    var autoSwitch: Bool {
        get { real.autoSwitch }
        set {
            real.autoSwitch = newValue
            scenario.record(GoldenEvent(type: "setAutoSwitch", value: newValue), update: nil, session: real)
        }
    }

    var correctsTypos: Bool {
        get { real.correctsTypos }
        set {
            real.correctsTypos = newValue
            scenario.record(GoldenEvent(type: "setCorrectsTypos", value: newValue), update: nil, session: real)
        }
    }

    func input(_ english: Character) -> SessionUpdate {
        perform(GoldenEvent(type: "input", key: String(english))) { $0.input(english) }
    }

    func input(_ atom: KeyAtom) -> SessionUpdate {
        perform(GoldenEvent(type: "atom", key: String(atom.english), layout: atom.layout.rawValue,
                            korean: GoldenKeyOutput(atom.korean))) { $0.input(atom) }
    }

    func backspace() -> SessionUpdate {
        perform(GoldenEvent(type: "backspace")) { $0.backspace() }
    }

    func toggle() -> SessionUpdate {
        perform(GoldenEvent(type: "toggle")) { $0.toggle() }
    }

    func convertOpenWord() -> SessionUpdate {
        perform(GoldenEvent(type: "convertOpenWord")) { $0.convertOpenWord() }
    }

    func commitDisplayed(endingRun: Bool = false) -> SessionUpdate {
        perform(GoldenEvent(type: "commitDisplayed", value: endingRun)) { $0.commitDisplayed(endingRun: endingRun) }
    }

    func forceMode(_ language: Language) -> SessionUpdate {
        perform(GoldenEvent(type: "forceMode", mode: language.rawValue)) { $0.forceMode(language) }
    }

    func discard() -> SessionUpdate {
        perform(GoldenEvent(type: "discard")) { $0.discard() }
    }

    private func perform(_ event: GoldenEvent, _ body: (SetoOracle.Session) -> SessionUpdate) -> SessionUpdate {
        scenario.beginStep()
        let update = body(real)
        scenario.record(event, update: update, session: real)
        return update
    }
}

/// Passes `record` through to the test's memory and logs it on the current step.
private final class RecordingTypos: TypoMemory {
    let inner: any TypoMemory
    let scenario: GoldenScenario

    init(inner: any TypoMemory, scenario: GoldenScenario) {
        self.inner = inner
        self.scenario = scenario
    }

    func record(wrong: String, wrongKeys: String, final: String, finalKeys: String) {
        scenario.pendingTypoRecords.append(GoldenTypoRow(wrong: wrong, wrongKeys: wrongKeys, final: final, finalKeys: finalKeys))
        inner.record(wrong: wrong, wrongKeys: wrongKeys, final: final, finalKeys: finalKeys)
    }

    func uniqueFinal(for wrong: String) -> String? {
        inner.uniqueFinal(for: wrong)
    }
}

// MARK: - Golden schema

struct GoldenLexicon: Encodable {
    /// "resources": `Lexicon.load(from: Resources/)`.
    /// "keyboard": `Lexicon.loadForKeyboard` over iOS/Keyboard/Resources plus Resources/korean-words.txt.
    /// "words": `Lexicon(english:korean:…)` with the lists below.
    var kind: String
    var english: [String]?
    var korean: [String]?
    var abbreviations: [String]?
    var techStems: [String]?
    var validKorean: [String]?

    init(kind: String, english: [String] = [], korean: [String] = [], abbreviations: [String] = [],
         techStems: [String] = [], validKorean: [String] = []) {
        self.kind = kind
        guard kind == "words" else { return }
        self.english = english
        self.korean = korean
        self.abbreviations = abbreviations.isEmpty ? nil : abbreviations
        self.techStems = techStems.isEmpty ? nil : techStems
        self.validKorean = validKorean.isEmpty ? nil : validKorean
    }
}

struct GoldenTypoRow: Encodable, Equatable {
    var wrong: String
    var wrongKeys: String
    var final: String
    var finalKeys: String
}

struct GoldenTypos: Encodable {
    /// "memory": the test's in-memory `MemoryTypos`, seeded with `rows`.
    var kind: String
    var rows: [GoldenTypoRow]

    init(memory: any TypoMemory) {
        if let memory = memory as? MemoryTypos {
            kind = "memory"
            rows = memory.rows.map { GoldenTypoRow(wrong: $0.wrong, wrongKeys: $0.wrongKeys, final: $0.final, finalKeys: $0.finalKeys) }
        } else {
            kind = String(describing: type(of: memory))
            rows = []
        }
    }
}

struct GoldenConfig: Encodable {
    var layout: String
    var autoSwitch: Bool
    var mode: String
    var correctsTypos: Bool
    var lexicon: GoldenLexicon
    var typos: GoldenTypos?
}

struct GoldenKeyOutput: Encodable {
    var jamo: GoldenJamo?
    var character: String?

    init(_ output: KeyOutput) {
        switch output {
        case .jamo(let value):
            jamo = GoldenJamo(scalar: value.scalar, kind: Self.kindName(value.kind))
        case .character(let value):
            character = String(value)
        }
    }

    private static func kindName(_ kind: JamoKind) -> String {
        switch kind {
        case .choseong: return "choseong"
        case .jungseong: return "jungseong"
        case .jongseong: return "jongseong"
        }
    }
}

struct GoldenJamo: Encodable {
    var scalar: UInt32
    var kind: String
}

/// One call on the session.
///
/// - `input`: `Session.input(Character)`; `key` is read through the scenario layout.
///   Space, newline, digits, shifted pad digits (390 `M` = 1) are ordinary keys.
/// - `atom`: `Session.input(KeyAtom)` with an atom built by `layout` for `key`.
/// - `backspace`, `toggle` (Shift+Space / Caps Lock), `convertOpenWord`, `discard`.
/// - `commitDisplayed`: navigation / focus change; `value` is `endingRun`.
/// - `forceMode`: `mode` is the forced language.
/// - `setAutoSwitch`, `setCorrectsTypos`: property changes; `value` is the new value. No update.
struct GoldenEvent: Encodable {
    var type: String
    var key: String?
    var layout: String?
    var korean: GoldenKeyOutput?
    var value: Bool?
    var mode: String?
}

/// FieldEdit. Every `utf16` is a count of UTF-16 code units.
struct GoldenField: Encodable {
    var kind: String
    var text: String?
    var utf16: Int?
    var insert: String?
    var mark: String?
    var thenMark: String?

    init(_ field: FieldEdit) {
        switch field {
        case .none:
            kind = "none"
        case .unmark(let value):
            kind = "unmark"; text = value
        case .insert(let value):
            kind = "insert"; text = value
        case .mark(let value):
            kind = "mark"; text = value
        case .replaceBeforeCaret(let count, let value):
            kind = "replaceBeforeCaret"; utf16 = count; text = value
        case .insertThenMark(let first, let second):
            kind = "insertThenMark"; insert = first; mark = second
        case .insertReplacing(let count, let value):
            kind = "insertReplacing"; utf16 = count; text = value
        case .insertReplacingThenMark(let count, let first, let second):
            kind = "insertReplacingThenMark"; utf16 = count; insert = first; mark = second
        case .clearMarkThenInsert(let count, let value):
            kind = "clearMarkThenInsert"; utf16 = count; text = value
        case .clearMarkThenMark(let count, let value):
            kind = "clearMarkThenMark"; utf16 = count; text = value
        case .rewrite(let count, let value, let after):
            kind = "rewrite"; utf16 = count; text = value; thenMark = after
        }
    }
}

struct GoldenUpdate: Encodable {
    var mode: String
    var didAutoConvert: Bool
    var preedit: String
    var field: GoldenField
}

struct GoldenStep: Encodable {
    var event: GoldenEvent
    /// The `SessionUpdate` returned by the call. Absent for property changes.
    var update: GoldenUpdate?
    /// Session state after the call.
    var document: String
    var mode: String
    var preedit: String
    /// `TypoMemory.record` calls made during this step.
    var typoRecords: [GoldenTypoRow]?
}

final class GoldenScenario: @unchecked Sendable {
    let test: String
    let file: String
    let source: String
    let config: GoldenConfig
    var steps: [GoldenStep] = []
    var pendingTypoRecords: [GoldenTypoRow] = []

    init(test: String, file: String, source: String, config: GoldenConfig) {
        self.test = test
        self.file = file
        self.source = source
        self.config = config
    }

    func beginStep() {
        pendingTypoRecords = []
    }

    func record(_ event: GoldenEvent, update: SessionUpdate?, session: SetoOracle.Session) {
        steps.append(GoldenStep(
            event: event,
            update: update.map {
                GoldenUpdate(mode: $0.mode.rawValue, didAutoConvert: $0.didAutoConvert, preedit: $0.preedit, field: GoldenField($0.field))
            },
            document: session.document,
            mode: session.mode.rawValue,
            preedit: session.preedit,
            typoRecords: pendingTypoRecords.isEmpty ? nil : pendingTypoRecords
        ))
        pendingTypoRecords = []
    }

    /// Compact human-readable key line: ⌫ backspace, ⇧ toggle, ⇥ commit, ↵ newline.
    var summary: String {
        steps.map { step -> String in
            switch step.event.type {
            case "input", "atom": return step.event.key == "\n" ? "↵" : (step.event.key ?? "")
            case "backspace": return "⌫"
            case "toggle": return "⇧"
            case "convertOpenWord": return "※"
            case "commitDisplayed": return "⇥"
            case "forceMode": return "«\(step.event.mode ?? "")»"
            case "discard": return "⌧"
            default: return ""
            }
        }.joined()
    }
}

private struct GoldenScenarioOut: Encodable {
    var name: String
    var aliases: [String]?
    var source: String
    var keys: String
    var config: GoldenConfig
    var steps: [GoldenStep]
}

// MARK: - Recorder

final class GoldenRecorder: @unchecked Sendable {
    static let shared: GoldenRecorder = {
        let recorder = GoldenRecorder()
        atexit { GoldenRecorder.shared.write() }
        return recorder
    }()

    /// Tests that record more sessions than this are sampled down to about `sampleLimit`.
    static let sampleThreshold = 2000
    static let sampleLimit = 500

    private let lock = NSLock()
    private var scenarios: [GoldenScenario] = []

    func begin(config: GoldenConfig, source: String) -> GoldenScenario {
        let test = Test.current?.name ?? "unknown"
        let file = Test.current.map { (($0.sourceLocation.fileID as NSString).lastPathComponent as NSString).deletingPathExtension } ?? "unknown"
        let scenario = GoldenScenario(test: test, file: file, source: source, config: config)
        lock.lock()
        scenarios.append(scenario)
        lock.unlock()
        return scenario
    }

    static var outputURL: URL {
        if let path = ProcessInfo.processInfo.environment["SETO_GOLDEN_OUT"] {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("core-rs/testdata/session-golden.json")
    }

    func write() {
        lock.lock()
        let all = scenarios.filter { !$0.steps.isEmpty }
        lock.unlock()
        guard !all.isEmpty else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        struct Body: Encodable { var config: GoldenConfig; var steps: [GoldenStep] }
        struct Entry { var scenario: GoldenScenario; var body: Data; var summary: String; var name = "" }

        // Some tests iterate dictionaries, so creation order is not stable
        // between runs. Everything below depends only on recorded content.
        var groups: [String: [Entry]] = [:]
        for scenario in all {
            let body = try! encoder.encode(Body(config: scenario.config, steps: scenario.steps))
            groups["\(scenario.file)/\(scenario.test)", default: []]
                .append(Entry(scenario: scenario, body: body, summary: scenario.summary))
        }

        // Dictionary sweeps record tens of thousands of sessions. Keep a
        // deterministic content-hash sample of each so the corpus stays small
        // enough to check in. SETO_GOLDEN_FULL=1 keeps every session.
        let sample = ProcessInfo.processInfo.environment["SETO_GOLDEN_FULL"] == nil
        var sampling: [String] = []
        var entries: [Entry] = []
        for test in groups.keys.sorted() {
            var group = groups[test]!
            let recorded = group.count
            if sample, recorded > Self.sampleThreshold {
                let stride = UInt64((recorded + Self.sampleLimit - 1) / Self.sampleLimit)
                group = group.filter { Self.fnv1a($0.body) % stride == 0 }
                sampling.append("{\"kept\":\(group.count),\"recorded\":\(recorded),\"stride\":\(stride),\"test\":\"\(test)\"}")
            }
            group.sort {
                $0.summary != $1.summary ? $0.summary < $1.summary : $0.body.lexicographicallyPrecedes($1.body)
            }
            for index in group.indices {
                group[index].name = "\(test)#\(index + 1)"
            }
            entries += group
        }

        // Identical scenarios (same config and the same recorded steps) are
        // written once; later names are kept as aliases.
        var outputs: [GoldenScenarioOut] = []
        var byBody: [Data: Int] = [:]
        for entry in entries {
            if let existing = byBody[entry.body] {
                outputs[existing].aliases = (outputs[existing].aliases ?? []) + [entry.name]
                continue
            }
            byBody[entry.body] = outputs.count
            let scenario = entry.scenario
            outputs.append(GoldenScenarioOut(name: entry.name, aliases: nil, source: scenario.source,
                                             keys: entry.summary, config: scenario.config, steps: scenario.steps))
        }

        let stepCount = outputs.reduce(0) { $0 + $1.steps.count }
        var text = "{\n"
        text += "\"generator\": \"Tests/SetoGoldenDump (SETO_GOLDEN_DUMP=1 swift test --filter SetoGoldenDump)\",\n"
        text += "\"schema\": 1,\n"
        text += "\"sampled\": [\(sampling.joined(separator: ","))],\n"
        text += "\"scenarioCount\": \(outputs.count),\n"
        text += "\"stepCount\": \(stepCount),\n"
        text += "\"scenarios\": [\n"
        for (offset, scenario) in outputs.enumerated() {
            text += String(decoding: try! encoder.encode(scenario), as: UTF8.self)
            text += offset + 1 < outputs.count ? ",\n" : "\n"
        }
        text += "]\n}\n"

        let url = Self.outputURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data("golden: wrote \(outputs.count) scenarios (\(all.count) recorded), \(stepCount) steps to \(url.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("golden: failed to write \(url.path): \(error)\n".utf8))
        }
    }

    private static func fnv1a(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
