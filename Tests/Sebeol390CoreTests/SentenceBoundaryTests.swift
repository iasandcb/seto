import Testing
@testable import SetoCore

private func utf16(_ text: String) -> Int { text.utf16.count }

/// The sentence for a caret at `caret`, or at the end of `text`.
private func sentence(_ text: String, caret: Int? = nil) -> String {
    let range = SentenceBoundary.range(in: text, before: caret ?? utf16(text))
    let units = Array(text.utf16)
    return String(decoding: units[range], as: UTF16.self)
}

private func start(_ text: String, caret: Int? = nil) -> Int {
    SentenceBoundary.range(in: text, before: caret ?? utf16(text)).lowerBound
}

@Test func sentenceStartWithoutBoundaryIsTheFirstNonSpace() {
    #expect(start("   hello world") == 3)
    #expect(SentenceBoundary.range(in: "hello", before: 5) == 0..<5)
}

@Test func sentenceStartFollowsAPeriodAndSpace() {
    #expect(start("First one. Second one") == utf16("First one. "))
}

@Test func sentenceStartFollowsQuestionExclamationAndIdeographicPeriod() {
    for boundary in ["?", "!", "。", "！", "？"] {
        #expect(start("앞 문장\(boundary) 뒤 문장") == utf16("앞 문장\(boundary) "))
    }
}

@Test func sentenceStartFollowsLineBreaks() {
    for separator in ["\n", "\r", "\r\n", "\u{2028}", "\u{2029}"] {
        #expect(start("line one\(separator)  line two") == utf16("line one\(separator)  "))
    }
}

@Test func sentenceStartUsesOnlyTextBeforeTheCaret() {
    let text = "One. Two three. Four"
    let caret = utf16("One. Two")
    #expect(SentenceBoundary.range(in: text, before: caret) == utf16("One. ")..<caret)
}

@Test func caretMidSentenceEndsAtTheCaret() {
    #expect(sentence("첫 문장. 두 번째 문") == "두 번째 문")
    #expect(sentence("첫 문장. 두 번째 문장 ") == "두 번째 문장 ")
}

@Test func caretAfterAFinishedSentenceSelectsIt() {
    #expect(sentence("끝났다.") == "끝났다.")
    #expect(sentence("첫 문장. 끝났다.") == "끝났다.")
    #expect(sentence("끝났다。") == "끝났다。")
    #expect(sentence("정말?!") == "정말?!")
    #expect(sentence("앞. 정말！？") == "정말！？")
    #expect(sentence("그래서...") == "그래서...")
    #expect(sentence("그래서…") == "그래서…")
}

@Test func finishedSentenceExcludesTrailingSpacesAndTabs() {
    let text = "끝났다. "
    #expect(SentenceBoundary.range(in: text, before: utf16(text)) == 0..<utf16("끝났다."))
    #expect(sentence("앞. 끝났다.\t \t") == "끝났다.")
}

@Test func finishedSentenceIncludesClosingQuotesAndBrackets() {
    #expect(sentence("그는 \"좋아.\"") == "그는 \"좋아.\"")
    #expect(sentence("(괄호.)") == "(괄호.)")
    #expect(sentence("앞. 그가 “좋아!”  ") == "그가 “좋아!”")
    #expect(sentence("「끝。」』") == "「끝。」』")
    #expect(sentence("（끝.）") == "（끝.）")
}

@Test func onlyPunctuationIsEmpty() {
    for text in ["...", "…", ".", "?!", "  . ","앞. ...", "앞.\n!"] {
        #expect(SentenceBoundary.range(in: text, before: utf16(text)).isEmpty)
    }
    #expect(SentenceBoundary.range(in: "", before: 0) == 0..<0)
}

@Test func lineBreakAfterASentenceStaysEmpty() {
    for text in ["줄1\n", "Done.\n", "끝났다. \n", "끝났다.\n  "] {
        let caret = utf16(text)
        #expect(SentenceBoundary.range(in: text, before: caret) == caret..<caret)
    }
}

@Test func sentenceStartInKoreanText() {
    #expect(start("오늘은 날씨가 좋다. 내일은 비가 올거같다") == utf16("오늘은 날씨가 좋다. "))
}

@Test func sentenceStartIsSafeAroundSurrogatePairs() {
    #expect(start("좋아요 👍. 다음 😀 문장") == utf16("좋아요 👍. "))
    #expect(start("😀 starts") == 0)
    #expect(sentence("앞. 좋아요 👍.") == "좋아요 👍.")
    #expect(sentence("😀!") == "😀!")
}

@Test func sentenceRangeClampsTheCaret() {
    #expect(SentenceBoundary.range(in: "abc", before: 99) == 0..<3)
    #expect(SentenceBoundary.range(in: "abc", before: -1) == 0..<0)
}
