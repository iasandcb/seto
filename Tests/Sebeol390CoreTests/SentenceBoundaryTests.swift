import Testing
@testable import SetoCore

private func utf16(_ text: String) -> Int { text.utf16.count }

@Test func sentenceStartWithoutBoundaryIsTheFirstNonSpace() {
    let text = "   hello world"
    #expect(SentenceBoundary.start(in: text, before: utf16(text)) == 3)
    #expect(SentenceBoundary.start(in: "hello", before: 5) == 0)
}

@Test func sentenceStartFollowsAPeriodAndSpace() {
    let text = "First one. Second one"
    #expect(SentenceBoundary.start(in: text, before: utf16(text)) == utf16("First one. "))
}

@Test func sentenceStartFollowsQuestionExclamationAndIdeographicPeriod() {
    for boundary in ["?", "!", "。"] {
        let text = "앞 문장\(boundary) 뒤 문장"
        #expect(SentenceBoundary.start(in: text, before: utf16(text)) == utf16("앞 문장\(boundary) "))
    }
}

@Test func sentenceStartFollowsLineBreaks() {
    for separator in ["\n", "\r", "\r\n", "\u{2028}", "\u{2029}"] {
        let text = "line one\(separator)  line two"
        #expect(SentenceBoundary.start(in: text, before: utf16(text)) == utf16("line one\(separator)  "))
    }
}

@Test func sentenceStartUsesOnlyTextBeforeTheCaret() {
    let text = "One. Two three. Four"
    let caret = utf16("One. Two")
    #expect(SentenceBoundary.start(in: text, before: caret) == utf16("One. "))
}

@Test func caretRightAfterABoundaryGivesAnEmptySentence() {
    #expect(SentenceBoundary.start(in: "Done.", before: 5) == 5)
    #expect(SentenceBoundary.start(in: "Done. ", before: 6) == 6)
    #expect(SentenceBoundary.start(in: "Done.\n", before: 6) == 6)
    #expect(SentenceBoundary.start(in: "", before: 0) == 0)
}

@Test func sentenceStartInKoreanText() {
    let text = "오늘은 날씨가 좋다. 내일은 비가 올거같다"
    #expect(SentenceBoundary.start(in: text, before: utf16(text)) == utf16("오늘은 날씨가 좋다. "))
}

@Test func sentenceStartIsSafeAroundSurrogatePairs() {
    let text = "좋아요 👍. 다음 😀 문장"
    #expect(SentenceBoundary.start(in: text, before: utf16(text)) == utf16("좋아요 👍. "))
    let leading = "😀 starts"
    #expect(SentenceBoundary.start(in: leading, before: utf16(leading)) == 0)
}

@Test func sentenceStartClampsTheCaret() {
    #expect(SentenceBoundary.start(in: "abc", before: 99) == 0)
    #expect(SentenceBoundary.start(in: "abc", before: -1) == 0)
}
