import Foundation
import Testing
#if SETO_ORACLE
@testable import SetoOracle
#else
@testable import SetoCore
#endif

private let endingLexicon: Lexicon = {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try! Lexicon.load(from: root.appendingPathComponent("Resources"))
}()

@Test func hadaFormsAreNotTypoCorrections() throws {
    for layout in [KeyboardLayout.sebeol390, .dubeol] {
        for word in ["말하기", "공부하기", "말하다", "공부하다", "말하면", "공부해서", "공부하자"] {
            let keys = try #require(TypoCorrector.keystrokes(for: word, layout: layout))
            #expect(TypoCorrector.correction(
                composed: word, keys: keys.map { layout.atom(for: $0) },
                language: .korean, lexicon: endingLexicon, memory: nil
            ) == nil, "\(layout): \(word)")
        }
    }
}

@Test func hadaFormsStayTypedAtWordBoundaries() throws {
    for layout in [KeyboardLayout.sebeol390, .dubeol] {
        for word in ["말하기", "공부하기", "말하다", "공부하다", "말하면", "공부해서", "공부하자"] {
            let keys = try #require(TypoCorrector.keystrokes(for: word, layout: layout))
            for boundary in [" ", ".", "\n"] {
                let session = Session(lexicon: endingLexicon, mode: .korean, layout: layout)
                for key in keys + boundary { _ = session.input(layout.atom(for: key)) }
                #expect(session.document == word + boundary, "\(layout): \(word)")
            }
        }
    }
}

@Test func productiveHadaEndingsAndVerbNominalizationsAreRecognized() {
    for ending in ["하기", "하다", "하면", "해서", "하자", "하고", "하는"] {
        let split = KoreanEndings.split("공부" + ending)
        #expect(split?.stem == "공부")
        #expect(split?.ending == ending)
    }
    for (word, known) in [("먹기", "먹"), ("가기", "가다")] {
        // Exercise the productive rule without relying on a validity-list entry.
        #expect(KoreanVerbEndings.isInflected(word) { $0 == known })
    }
    #expect(zip(KoreanEndings.longestFirst, KoreanEndings.longestFirst.dropFirst())
        .allSatisfy { $0.count >= $1.count })
}

@Test func unknownOneKeyKoreanTyposStillCorrect() throws {
    for layout in [KeyboardLayout.sebeol390, .dubeol] {
        let keys = try #require(TypoCorrector.keystrokes(for: "한굴", layout: layout))
        #expect(TypoCorrector.correction(
            composed: "한굴", keys: keys.map { layout.atom(for: $0) },
            language: .korean, lexicon: endingLexicon, memory: nil
        ) == "한글")
        let session = Session(lexicon: endingLexicon, mode: .korean, layout: layout)
        for key in keys + " " { _ = session.input(layout.atom(for: key)) }
        #expect(session.document == "한글 ")
    }
}

@Test func shortHadaEndingsSplitFromKnownStems() {
    for stem in ["못", "안", "공부"] {
        #expect(endingLexicon.isKoreanWord(stem) || endingLexicon.isValidKorean(stem))
        for ending in ["한", "할", "함", "했", "해"] {
            let split = KoreanEndings.split(stem + ending)
            #expect(split?.stem == stem)
            #expect(split?.ending == ending)
        }
    }
    #expect(KoreanEndings.set.contains("만"))
    #expect(zip(KoreanEndings.longestFirst, KoreanEndings.longestFirst.dropFirst())
        .allSatisfy { $0.count >= $1.count })
}

@Test func shortHadaFormsAreNotTypoCorrections() throws {
    for layout in [KeyboardLayout.sebeol390, .dubeol] {
        for stem in ["못", "안", "공부"] {
            for ending in ["한", "할", "함", "했", "해"] {
                let word = stem + ending
                let keys = try #require(TypoCorrector.keystrokes(for: word, layout: layout))
                #expect(TypoCorrector.correction(
                    composed: word, keys: keys.map { layout.atom(for: $0) },
                    language: .korean, lexicon: endingLexicon, memory: nil
                ) == nil, "\(layout): \(word)")
            }
        }
    }
}

@Test func shortHadaFormsStayTypedAtWordBoundaries() throws {
    for layout in [KeyboardLayout.sebeol390, .dubeol] {
        for stem in ["못", "안", "공부"] {
            for ending in ["한", "할", "함", "했", "해"] {
                let word = stem + ending
                let keys = try #require(TypoCorrector.keystrokes(for: word, layout: layout))
                for boundary in [" ", ".", "\n"] {
                    let session = Session(lexicon: endingLexicon, mode: .korean, layout: layout)
                    for key in keys + boundary { _ = session.input(layout.atom(for: key)) }
                    #expect(session.document == word + boundary,
                        "\(layout): \(word), boundary: \(boundary.debugDescription)")
                }
            }
        }
    }
}

@Test func colloquialDuParticleSplitsFromKnownStems() {
    for stem in ["너", "나", "저", "우리"] {
        #expect(endingLexicon.isKoreanWord(stem) || endingLexicon.isValidKorean(stem))
        for ending in ["두", "도"] {
            let split = KoreanEndings.split(stem + ending)
            #expect(split?.stem == stem)
            #expect(split?.ending == ending)
        }
    }
    #expect(zip(KoreanEndings.longestFirst, KoreanEndings.longestFirst.dropFirst())
        .allSatisfy { $0.count >= $1.count })
}

@Test func colloquialDuFormsAreNotTypoCorrections() throws {
    for layout in [KeyboardLayout.sebeol390, .dubeol] {
        for word in ["너두", "나두", "저두", "우리두"] {
            let keys = try #require(TypoCorrector.keystrokes(for: word, layout: layout))
            #expect(TypoCorrector.correction(
                composed: word, keys: keys.map { layout.atom(for: $0) },
                language: .korean, lexicon: endingLexicon, memory: nil
            ) == nil, "\(layout): \(word)")
        }
    }
}

private func keyboardEndingLexicon() throws -> (Lexicon, URL) {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    for name in ["keyboard-english.txt", "keyboard-korean-valid.txt"] {
        try FileManager.default.createSymbolicLink(
            at: bundle.appendingPathComponent(name),
            withDestinationURL: root.appendingPathComponent("iOS/Keyboard/Resources/" + name))
    }
    try FileManager.default.createSymbolicLink(
        at: bundle.appendingPathComponent("korean-words.txt"),
        withDestinationURL: root.appendingPathComponent("Resources/korean-words.txt"))
    return (try Lexicon.loadForKeyboard(from: bundle), bundle)
}

/// 몇시 is one choseong away from 몇+이, and was missing from the validity list
/// while 한시 and 두시 were present. 몇시에 is that headword plus 에.
@Test func myeotCompoundsAreNotTypoCorrections() throws {
    let (keyboard, directory) = try keyboardEndingLexicon()
    defer { try? FileManager.default.removeItem(at: directory) }
    let lexicons = [endingLexicon, keyboard]
    let words = ["몇시", "몇시에", "몇시간", "몇분", "몇개", "몇명", "몇번", "모시", "몇살", "몇년", "몇일", "몇세", "몇이"]
    for lexicon in lexicons {
        for word in ["몇시", "몇시간", "몇분", "몇개", "몇명", "몇번", "모시", "몇살", "몇년", "몇일", "몇세"] {
            #expect(lexicon.isKoreanWord(word) || lexicon.isValidKorean(word), "\(word)")
        }
    }
    #expect(KoreanEndings.split("몇시에")?.stem == "몇시", "몇시")
    #expect(KoreanEndings.split("몇시에")?.ending == "에", "에")
    for lexicon in lexicons {
        for layout in [KeyboardLayout.sebeol390, .dubeol, .sebeolFinal] {
            for word in words {
                let keys = try #require(TypoCorrector.keystrokes(for: word, layout: layout))
                #expect(TypoCorrector.correction(
                    composed: word, keys: keys.map { layout.atom(for: $0) },
                    language: .korean, lexicon: lexicon, memory: nil
                ) == nil, "\(layout): \(word)")
            }
        }
    }
}

@Test func myeotCompoundsStayTypedAtWordBoundaries() throws {
    let (keyboard, directory) = try keyboardEndingLexicon()
    defer { try? FileManager.default.removeItem(at: directory) }
    let lexicons = [endingLexicon, keyboard]
    let words = ["몇시", "몇시에", "몇시간", "몇분", "몇개", "몇명", "몇번", "모시", "몇살", "몇년", "몇일", "몇세", "몇이"]
    for lexicon in lexicons {
        for layout in [KeyboardLayout.sebeol390, .dubeol, .sebeolFinal] {
            for word in words {
                let keys = try #require(TypoCorrector.keystrokes(for: word, layout: layout))
                for boundary in [" ", ".", "\n"] {
                    let session = Session(lexicon: lexicon, mode: .korean, layout: layout)
                    for key in keys + boundary { _ = session.input(layout.atom(for: key)) }
                    #expect(session.document == word + boundary, "\(layout): \(word) \(boundary.debugDescription)")
                }
            }
        }
    }
}

@Test func colloquialDuFormsStayTypedAtWordBoundaries() throws {
    for layout in [KeyboardLayout.sebeol390, .dubeol] {
        for word in ["너두", "나두", "저두", "우리두"] {
            let keys = try #require(TypoCorrector.keystrokes(for: word, layout: layout))
            for boundary in [" ", ".", "\n"] {
                let session = Session(lexicon: endingLexicon, mode: .korean, layout: layout)
                for key in keys + boundary { _ = session.input(layout.atom(for: key)) }
                #expect(session.document == word + boundary, "\(layout): \(word), boundary: \(boundary.debugDescription)")
            }
        }
    }
}
