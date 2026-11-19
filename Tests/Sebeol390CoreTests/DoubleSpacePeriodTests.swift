import Foundation
import Testing
#if SETO_ORACLE
@testable import SetoOracle
#else
@testable import SetoCore
#endif

@Test func convertsAnEligibleSecondSpaceWithinFourTenthsOfASecond() {
    let first = Date(timeIntervalSince1970: 100)
    var detector = DoubleSpacePeriod()
    detector.recordFirstSpace(contextBefore: "hello ", now: first)

    let converted = detector.shouldConvert(contextBefore: "hello ", now: first.addingTimeInterval(0.4))
    #expect(converted)

    let convertedAgain = detector.shouldConvert(contextBefore: "hello ", now: first.addingTimeInterval(0.4))
    #expect(!convertedAgain)
}

@Test func acceptsDigitsAndHangulSyllablesAndJamo() {
    for context in ["word1 ", "한글 ", "ㄱ ", "ᄀ "] {
        var detector = DoubleSpacePeriod()
        detector.recordFirstSpace(contextBefore: context, now: Date(timeIntervalSince1970: 1))
        let converted = detector.shouldConvert(contextBefore: context, now: Date(timeIntervalSince1970: 1.1))
        #expect(converted)
    }
}

@Test func rejectsIneligiblePrecedingCharactersAndStartOfText() {
    for context in ["", " ", "word. ", "word, ", "word\n ", "word  "] {
        var detector = DoubleSpacePeriod()
        detector.recordFirstSpace(contextBefore: context, now: Date(timeIntervalSince1970: 1))
        let converted = detector.shouldConvert(contextBefore: context, now: Date(timeIntervalSince1970: 1.1))
        #expect(!converted)
    }
}

@Test func requiresUnchangedContextAndAnInRangeTime() {
    let first = Date(timeIntervalSince1970: 10)
    var changedContext = DoubleSpacePeriod()
    changedContext.recordFirstSpace(contextBefore: "hello ", now: first)
    let changedContextConverted = changedContext.shouldConvert(contextBefore: "hello! ", now: first.addingTimeInterval(0.1))
    #expect(!changedContextConverted)

    var tooLate = DoubleSpacePeriod()
    tooLate.recordFirstSpace(contextBefore: "hello ", now: first)
    let tooLateConverted = tooLate.shouldConvert(contextBefore: "hello ", now: first.addingTimeInterval(0.401))
    #expect(!tooLateConverted)

    var cleared = DoubleSpacePeriod()
    cleared.recordFirstSpace(contextBefore: "hello ", now: first)
    cleared.clear()
    let clearedConverted = cleared.shouldConvert(contextBefore: "hello ", now: first.addingTimeInterval(0.1))
    #expect(!clearedConverted)
}
