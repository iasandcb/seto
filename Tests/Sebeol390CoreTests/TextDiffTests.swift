import Testing
@testable import SetoCore

private func roundTrips(_ old: String, _ new: String) -> [TextDiff.Segment] {
    let segments = TextDiff.diff(old, new)
    #expect(segments.oldText == old)
    #expect(segments.newText == new)
    return segments
}

@Test func identicalTextsAreOneUnchangedSegment() {
    #expect(TextDiff.diff("같다", "같다") == [.same("같다")])
    #expect(TextDiff.diff("", "") == [])
}

@Test func emptySideIsAWholeInsertionOrDeletion() {
    #expect(roundTrips("", "new") == [.added("new")])
    #expect(roundTrips("old", "") == [.removed("old")])
}

@Test func koreanSpellingFixIsCharacterLevel() {
    #expect(roundTrips("안녕하세여", "안녕하세요") == [.same("안녕하세"), .removed("여"), .added("요")])
}

@Test func koreanSpacingFixShowsOnlyAddedSpaces() {
    #expect(roundTrips("할수있다", "할 수 있다") == [
        .same("할"), .added(" "), .same("수"), .added(" "), .same("있다"),
    ])
}

@Test func englishWordReplacement() {
    #expect(roundTrips("I has a pen.", "I have a pen.") == [
        .same("I ha"), .removed("s"), .added("ve"), .same(" a pen."),
    ])
}

@Test func longTextsDiffByWordTokens() {
    let words = (0..<60).map { "word\($0)" }
    let old = words.joined(separator: " ")
    var changed = words
    changed[30] = "replaced"
    let new = changed.joined(separator: " ")
    let segments = roundTrips(old, new)
    #expect(segments.count == 4)
    #expect(segments[1] == .removed("word30"))
    #expect(segments[2] == .added("replaced"))
}

@Test func tokensAlternateWordsAndWhitespace() {
    #expect(TextDiff.tokens("a  bc d") == ["a", "  ", "bc", " ", "d"])
}

@Test func oversizedDiffReplacesEverything() {
    let old = Array(repeating: "가나", count: 400).joined(separator: " ")
    let new = Array(repeating: "다라", count: 400).joined(separator: " ")
    #expect(TextDiff.diff(old, new) == [.removed(old), .added(new)])
}

@Test func emojiAreComparedAsWholeCharacters() {
    #expect(roundTrips("좋아 👍", "좋아요 👍") == [.same("좋아"), .added("요"), .same(" 👍")])
}

@Test func refinementOutputDropsQuotesAndKeepsOriginalSpacing() {
    #expect(RefinementOutput.clean("  \"안녕하세요.\"\n", original: "안녕하세여 ") == "안녕하세요. ")
    #expect(RefinementOutput.clean("“Hello.”", original: "hello") == "Hello.")
    #expect(RefinementOutput.clean("\"Quoted\" text", original: "\"quoted\" text") == "\"Quoted\" text")
    #expect(RefinementOutput.clean("\"Hi\"", original: "\"hi\"") == "\"Hi\"")
    #expect(RefinementOutput.clean("   ", original: "x") == "")
}
