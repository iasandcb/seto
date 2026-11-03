import Foundation
import Testing
@testable import SetoCore

private func isolatedStore(capacity: Int = LearnedWords.defaultCapacity) throws -> (LearnedWords, UserDefaults, String) {
    let suite = "Sebeol390.LearnedWords.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    return (LearnedWords(defaults: defaults, capacity: capacity), defaults, suite)
}

@Test func learnedWordsRankFrequencyThenRecencyAndKeepOneCharacterPrefixes() throws {
    let suite = "Sebeol390.LearnedWords.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let store = LearnedWords(defaults: defaults)
    store.learn("apple", at: now)
    store.learn("apple", at: now)
    store.learn("apple", at: now)
    store.learn("apply", at: now.addingTimeInterval(60))
    store.learn("apply", at: now.addingTimeInterval(60))
    store.learn("hello", at: now)
    store.learn("안녕하세요", at: now)
    store.learn("a", at: now)
    store.learn("secret", secure: true, at: now)
    #expect(store.prefixMatches(for: "app", at: now.addingTimeInterval(60)).first == "apple")
    #expect(store.prefixMatches(for: "h", at: now) == ["hello"])
    #expect(store.prefixMatches(for: "안", at: now) == ["안녕하세요"])
    #expect(store.prefixMatches(for: "안녕ㅎ", at: now) == ["안녕하세요"])
    #expect(store.prefixMatches(for: "se", at: now).isEmpty)
    #expect(store.prefixMatches(for: "a", at: now).first == "apple")

    let later = now.addingTimeInterval(120)
    store.learn("apply", at: later)
    #expect(store.prefixMatches(for: "app", at: later).first == "apply")
}

@Test func learnedWordsRememberFollowersAfterSpaceAndIgnoreSecureFields() throws {
    let (store, defaults, suite) = try isolatedStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    store.observe(from: "안녕", to: "안녕 ", at: now)
    store.observe(from: "안녕 세", to: "안녕 세상 ", at: now)
    #expect(store.nextWords(after: "안녕 ", at: now).isEmpty)
    store.observe(from: "안녕 세", to: "안녕 세상 ", at: now.addingTimeInterval(5))
    #expect(store.nextWords(after: "안녕 ", at: now) == ["세상"])
    store.observe(from: "secret", to: "secret ", secure: true, at: now)
    #expect(store.prefixMatches(for: "se", at: now).isEmpty)
    for _ in 0..<3 { store.learn("세토", at: now) }
    #expect(store.nextWords(after: "다른 ", at: now).contains("세토"))
    #expect(store.nextWords(after: "안녕 ", at: now) == ["세상"])
}

@Test func learnedWordsPersistPruneRareEntriesAndDropStaleSingles() throws {
    let suite = "Sebeol390.LearnedWords.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let store = LearnedWords(defaults: defaults, capacity: 2)
    store.learn("alpine", at: now.addingTimeInterval(-100))
    store.learn("alpha", at: now)
    store.learn("alpha", at: now)
    store.learn("alpha", at: now)
    store.learn("alto", at: now)
    store.learn("alto", at: now)
    store.learn("alto", at: now)
    let kept = store.prefixMatches(for: "al", limit: 5, at: now)
    #expect(kept.contains("alpha"))
    #expect(kept.contains("alto"))
    #expect(!kept.contains("alpine"))

    let reloaded = LearnedWords(defaults: defaults, capacity: 2)
    #expect(reloaded.prefixMatches(for: "al", limit: 5, at: now).count == 2)

    let staleSuite = "Sebeol390.LearnedWords.stale.\(UUID())"
    let staleDefaults = try #require(UserDefaults(suiteName: staleSuite))
    defer { staleDefaults.removePersistentDomain(forName: staleSuite) }
    let seeded = LearnedWords(defaults: staleDefaults, capacity: 20)
    seeded.learn("once", at: Date().addingTimeInterval(-40 * 24 * 60 * 60))
    let opened = LearnedWords(defaults: staleDefaults, capacity: 20)
    #expect(opened.prefixMatches(for: "on").isEmpty)
    opened.learn("kept", at: Date())
    opened.learn("kept", at: Date())
    #expect(opened.prefixMatches(for: "ke") == ["kept"])
    #expect(LearnedWords.applyingEdit(to: "안뇽", removing: "안뇽", inserting: "안녕 ") == "안녕 ")
    #expect(LearnedWords.precedingWord(in: "say hel", current: "hel") == "say")
    let hello = LearnedWords.committedWords(from: "hello", to: "hello ")
    #expect(hello.map(\.word) == ["hello"])
    #expect(hello.map(\.previous) == [nil])
    #expect(LearnedWords.committedWords(from: "안녕 세", to: "안녕 세상 ").map(\.word) == ["세상"])
}
