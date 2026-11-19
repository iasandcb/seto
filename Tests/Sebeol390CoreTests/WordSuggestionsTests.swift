import Foundation
import Testing
#if SETO_ORACLE
@testable import SetoOracle
#else
@testable import SetoCore
#endif

@Test func suggestionsCompleteOpenKoreanSyllablesAndCorrectTypos() {
    let engine = WordSuggestions(lexicon: Lexicon(english: [], korean: ["안녕", "안녕하세요", "가방", "감사합니다"]))
    #expect(engine.candidates(for: "안녕") == ["안녕하세요"])
    #expect(engine.candidates(for: "안녕ㅎ").first == "안녕하세요")
    // A provisional batchim becomes the initial of the next syllable.
    #expect(engine.candidates(for: "갑").contains("가방"))
    #expect(engine.candidates(for: "안뇽").contains("안녕"))
    #expect(engine.candidates(for: "").isEmpty)
    #expect(engine.candidates(for: "zzzz").isEmpty)
}

@Test func suggestionsCompleteEnglishAndPreserveCase() {
    let engine = WordSuggestions(lexicon: Lexicon(english: ["hello", "help", "helmet", "world"], korean: []))
    #expect(engine.candidates(for: "hel") == ["help", "hello", "helps"])
    #expect(engine.candidates(for: "Hell").contains("Hello"))
    #expect(engine.candidates(for: "HELO").contains("HELLO"))
    #expect(engine.candidates(for: "wrold").contains("world"))
    #expect(engine.candidates(for: String(repeating: "a", count: 33)).isEmpty)
    #expect(engine.candidates(for: "hel", limit: 1).count == 1)
}

@Test func suggestionContextsRespectCaretAndWordBoundaries() {
    #expect(WordSuggestionContext(before: "앞 👨‍👩‍👧‍👦 안녕ㅎ", after: "!")?.word == "안녕ㅎ")
    #expect(WordSuggestionContext(before: "hello ", after: "") == nil)
    #expect(WordSuggestionContext(before: nil, after: "") == nil)
    #expect(WordSuggestionContext(before: "hel", after: "lo") == nil)
    #expect(WordSuggestionContext(before: "hello", after: " world")?.word == "hello")
    for text in ["user_name", "https://example", "user@example", "utf8word", "안녕123"] {
        #expect(WordSuggestionContext(before: text, after: "") == nil)
    }
    #expect(WordSuggestionContext(before: "one hel", after: "") != WordSuggestionContext(before: "two hel", after: ""))
    let next = WordSuggestionContext.nextWord(before: "안녕 ", after: "")
    #expect(next?.predictsNextWord == true)
    #expect(next?.word == "")
    #expect(WordSuggestionContext.nextWord(before: "안녕", after: "") == nil)
    #expect(WordSuggestionContext.forComposition(before: "안녕 ", after: "", allowNextWord: true)?.predictsNextWord == true)
    #expect(WordSuggestionContext.forComposition(before: "안녕", after: "", allowNextWord: true)?.word == "안녕")
    #expect(WordSuggestionContext.forComposition(before: "안녕 ", after: "", allowNextWord: false) == nil)
}

@Test func learnedPrefixesOutrankDictionaryAndTyposStay() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let suite = "Sebeol390.WordSuggestions.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let learned = LearnedWords(defaults: defaults)
    learned.learn("가방", at: now)
    learned.learn("가방", at: now)
    learned.learn("가수", at: now.addingTimeInterval(-10))
    let engine = WordSuggestions(lexicon: Lexicon(english: ["world", "hello"], korean: ["가방", "가수", "가위", "안녕"]))
    let personal = learned.prefixMatches(for: "가", at: now)
    let ranked = engine.candidates(for: "가", promoting: personal)
    #expect(ranked.first == "가방")
    #expect(ranked.contains("가위"))
    #expect(engine.candidates(for: "안뇽", promoting: []) == engine.candidates(for: "안뇽"))
    #expect(engine.candidates(for: "안뇽", promoting: []).contains("안녕"))
    let corrected = engine.candidates(for: "wrold", promoting: ["typed"])
    #expect(corrected.first == "typed")
    #expect(corrected.contains("world"))
    #expect(engine.candidates(for: "h", promoting: ["hello"]).first == "hello")
    #expect(engine.candidates(for: "Hell", promoting: ["hello"]).first == "Hello")
    #expect(engine.candidates(for: "H", promoting: ["hello"]).first == "HELLO")
    #expect(engine.candidates(for: "HELO", promoting: ["hello"]).contains("HELLO"))
}

@Test func mappedSuggestionsMatchInMemoryPrefixLookup() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for name in ["keyboard-english.txt", "keyboard-korean-valid.txt"] {
        try FileManager.default.copyItem(at: root.appendingPathComponent("iOS/Keyboard/Resources/" + name), to: directory.appendingPathComponent(name))
    }
    try FileManager.default.copyItem(at: root.appendingPathComponent("Resources/korean-words.txt"), to: directory.appendingPathComponent("korean-words.txt"))
    let lexicon = try Lexicon.loadForKeyboard(from: directory)
    #expect(lexicon.englishCompletions("").isEmpty)
    #expect(lexicon.englishCompletions("hell", limit: 0).isEmpty)
    let completions = lexicon.englishCompletions("hell")
    #expect(completions.count <= 256)
    #expect(completions.allSatisfy { $0.hasPrefix("hell") })
    #expect(completions.contains("hello"))
    #expect(WordSuggestions(lexicon: lexicon).candidates(for: "hell").contains("hello"))
}
