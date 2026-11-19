import Foundation
import Testing
#if SETO_ORACLE
@testable import SetoOracle
#else
@testable import SetoCore
#endif

private let transitionCorpusLexicon: Lexicon = {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources")
    return try! Lexicon.load(from: root)
}()

private struct TransitionCase {
    var name: String
    var keys: String
    var initialMode: Language
    var expectedText: String
    var expectedMode: Language
}

private let transitionCorpus: [TransitionCase] = [
    .init(name: "English word from Korean mode", keys: "hello", initialMode: .korean,
          expectedText: "hello", expectedMode: .english),
    .init(name: "recognized Korean word from English mode", keys: "mgz", initialMode: .english,
          expectedText: "흠", expectedMode: .korean),
    .init(name: "English stem with Korean ending", keys: "deploymr2hgsuc", initialMode: .korean,
          expectedText: "deploy했는데", expectedMode: .korean),
    .init(name: "English stem with Korean ending from English mode", keys: "deploymr2hgsuc", initialMode: .english,
          expectedText: "deploy했는데", expectedMode: .korean),
    .init(name: "acronym with Korean particle", keys: "AIyv", initialMode: .english,
          expectedText: "AI로", expectedMode: .korean),
    .init(name: "known acronym particle split", keys: "ktxhgs", initialMode: .korean,
          expectedText: "ktx는", expectedMode: .korean),
    .init(name: "filename remains a code token", keys: "agents.md", initialMode: .korean,
          expectedText: "agents.md", expectedMode: .english),
    .init(name: "English context preserves ambiguous short word", keys: "one of the", initialMode: .english,
          expectedText: "one of the", expectedMode: .english),
]

@Test func transitionCorpusProducesExpectedTextAndConfirmedMode() {
    for item in transitionCorpus {
        let session = Session(lexicon: transitionCorpusLexicon, mode: item.initialMode)
        for key in item.keys {
            _ = session.input(key)
        }
        #expect(session.document == item.expectedText,
                "\(item.name): \(session.debugLine)")
        #expect(session.mode == item.expectedMode,
                "\(item.name): \(session.debugLine)")
        _ = session.input(" ")
        #expect(session.document == item.expectedText + " ",
                "\(item.name) at word boundary: \(session.debugLine)")
        #expect(session.mode == item.expectedMode,
                "\(item.name) at word boundary: \(session.debugLine)")
    }
}
