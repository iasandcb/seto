import Testing
import Foundation
@testable import SetoCore

@Test func dubeolComposition() {
    for (keys, expected) in [("gksrmf", "한글"), ("dkssudgktpdy", "안녕하세요"), ("rkqt", "값"), ("rkqtdl", "값이"), ("rkrk", "가가"), ("rhk", "과"), ("Rk", "까"), ("rhkr", "곽")] {
        #expect(Composer.compose(keys.map(LayoutDubeol.atom)).text == expected)
    }
}

@Test func dubeolSessionDeletion() {
    let session = Session(lexicon: Lexicon(english: [], korean: []), autoSwitch: false)
    for key in "gksrmf" { _ = session.input(LayoutDubeol.atom(for: key)) }
    #expect(session.document == "한글")
    _ = session.backspace()
    #expect(session.document == "한그")
    _ = session.backspace()
    #expect(session.document == "한ㄱ")
}

@Test func dubeolAutomaticLanguageSwitching() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let lexicon = try Lexicon.load(from: root.appendingPathComponent("Resources"))
    for (initial, keys, expected, finalMode) in [
        (Language.korean, "hello ", "hello ", Language.english),
        (.korean, "world ", "world ", .english),
        (.english, "dkssudgktpdy ", "안녕하세요 ", .korean),
        (.english, "gksrmf ", "한글 ", .korean)
    ] {
        let session = Session(lexicon: lexicon, autoSwitch: true, mode: initial)
        for key in keys { _ = session.input(LayoutDubeol.atom(for: key)) }
        #expect(session.document == expected, "\(keys): \(session.document)")
        #expect(session.mode == finalMode)
    }
}

@Test func dubeolEnglishHeadsWithKoreanParticles() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let lexicon = try Lexicon.load(from: root.appendingPathComponent("Resources"))
    for initial in [Language.korean, .english] {
        for (keys, expected) in [("apisms", "api는"), ("gitdms", "git은"), ("apifmf", "api를"), ("gitdmf", "git을"), ("githubdptj", "github에서")] {
            let session = Session(lexicon: lexicon, autoSwitch: true, mode: initial)
            for key in keys { _ = session.input(LayoutDubeol.atom(for: key)) }
            #expect(session.document == expected, "\(initial) \(keys): \(session.document)")
            _ = session.input(LayoutDubeol.atom(for: " "))
            #expect(session.document == expected + " ")
        }
    }
}

@Test func dubeolNaturalKoreanPhraseStaysKorean() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let lexicon = try Lexicon.load(from: root.appendingPathComponent("Resources"))
    for initial in [Language.korean, .english] {
        for (keys, expected) in [("akadp emfdj", "맘에 들어"), ("akadp emfdjdy", "맘에 들어요"), ("akdma", "마음"), ("emfdj", "들어")] {
            let session = Session(lexicon: lexicon, autoSwitch: true, mode: initial)
            for key in keys { _ = session.input(LayoutDubeol.atom(for: key)) }
            #expect(session.document == expected, "\(initial) \(keys): \(session.document)")
            _ = session.input(LayoutDubeol.atom(for: " "))
            #expect(session.document == expected + " ")
        }
    }
}

@Test func dubeolChatReactionsOverrideEnglishDictionaryInBothModes() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: bundle) }
    for name in ["keyboard-english.txt", "keyboard-korean-valid.txt"] {
        try FileManager.default.copyItem(at: root.appendingPathComponent("iOS/Keyboard/Resources/" + name), to: bundle.appendingPathComponent(name))
    }
    try FileManager.default.copyItem(at: root.appendingPathComponent("Resources/korean-words.txt"), to: bundle.appendingPathComponent("korean-words.txt"))
    let lexicon = try Lexicon.loadForKeyboard(from: bundle)
    for initial in [Language.korean, .english] {
        for (keys, expected) in [("dd", "ㅇㅇ"), ("ddd", "ㅇㅇㅇ"), ("zz", "ㅋㅋ"), ("gg", "ㅎㅎ"), ("bb", "ㅠㅠ"), ("nn", "ㅜㅜ")] {
            let session = Session(lexicon: lexicon, mode: initial)
            for key in keys { _ = session.input(LayoutDubeol.atom(for: key)) }
            #expect(session.document == expected, "\(initial) \(keys): \(session.document)")
            _ = session.input(LayoutDubeol.atom(for: " "))
            #expect(session.document == expected + " ")
        }
    }
}
