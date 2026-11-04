import Testing
@testable import SetoCore

private func next(_ index: Int, of count: Int, maximum: Int = 5,
                  canGenerate: Bool = true) -> SuggestionCursor.Step {
    SuggestionCursor.next(index: index, count: count, maximum: maximum, canGenerate: canGenerate)
}

@Test func nextAdvancesWithinCacheWithoutGenerating() {
    #expect(next(0, of: 3) == .show(1))
    #expect(next(1, of: 3) == .show(2))
    #expect(next(0, of: 3, canGenerate: false) == .show(1))
    #expect(next(3, of: 5) == .show(4))
}

@Test func nextGeneratesOnLastWhenAllowed() {
    #expect(next(0, of: 1) == .generate)
    #expect(next(2, of: 3) == .generate)
    #expect(next(3, of: 4) == .generate)
}

@Test func nextWrapsAtMaximum() {
    #expect(next(4, of: 5) == .show(0))
    #expect(next(2, of: 3, maximum: 3) == .show(0))
}

@Test func nextWrapsWhenGenerationStopped() {
    #expect(next(2, of: 3, canGenerate: false) == .show(0))
    #expect(next(0, of: 1, canGenerate: false) == .show(0))
}

@Test func previousStepsBackAndWrapsToLast() {
    #expect(SuggestionCursor.previous(index: 2, count: 3) == 1)
    #expect(SuggestionCursor.previous(index: 1, count: 3) == 0)
    #expect(SuggestionCursor.previous(index: 0, count: 3) == 2)
    #expect(SuggestionCursor.previous(index: 0, count: 5) == 4)
}

@Test func singleSuggestion() {
    #expect(SuggestionCursor.previous(index: 0, count: 1) == 0)
    #expect(next(0, of: 1, maximum: 1) == .show(0))
}

@Test func outOfRangeIndexIsClamped() {
    #expect(SuggestionCursor.previous(index: 7, count: 3) == 1)
    #expect(next(7, of: 3) == .generate)
    #expect(SuggestionCursor.previous(index: 0, count: 0) == 0)
}
