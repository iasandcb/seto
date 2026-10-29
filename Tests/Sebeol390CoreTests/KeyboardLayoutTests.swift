import Testing
import Foundation
@testable import Sebeol390Core

@Test func selectedLayoutComposesThroughSession() {
    for (layout, keys) in [(KeyboardLayout.sebeol390, "mfs kgw"), (.sebeolFinal, "mfs kgw"), (.dubeol, "gks rmf")] {
        let session = Session(lexicon: Lexicon(english: [], korean: []), autoSwitch: false, layout: layout)
        for key in keys { _ = session.input(key) }
        #expect(session.document == "한 글", "\(layout): \(session.document)")
        _ = session.backspace()
        #expect(session.document == "한 그")
    }
}

@Test func finalShiftedJamoAndSymbols() {
    for (keys, expected) in [("kf!", "갂"), ("kf@", "갉"), ("kf#", "갖"), ("kf$", "갎"), ("kf%", "갍"), ("kfE", "갅"), ("kfD", "갋"), ("kfF", "갊"), ("kfR", "갏"), ("kfT", "갌"), ("kfV", "갃"), ("kG", "걔"), ("kfC", "갘")] {
        #expect(Composer.compose(keys.map(LayoutFinal.atom)).text == expected, "\(keys)")
    }
    for (key, output) in [("H", "0"), ("J", "1"), ("K", "2"), ("L", "3"), (":", "4"), ("Y", "5"), ("U", "6"), ("I", "7"), ("O", "8"), ("P", "9"), ("B", "?"), ("N", "-"), ("?", "!"), ("~", "※"), ("\"", "·"), ("[", "("), ("]", "<"), ("=", ">"), ("-", ")"), ("<", ","), (">", ".")] {
        #expect(LayoutFinal.atom(for: Character(key)).korean == .character(Character(output)))
    }
}

@Test func finalMovedPunctuationAndDigitsInSession() {
    let session = Session(lexicon: Lexicon(english: [], korean: []), autoSwitch: false, layout: .sebeolFinal)
    for key in "mfsB HJKL:YUIOP" { _ = session.input(key) }
    #expect(session.document == "한? 0123456789")
}

@Test func selectedLayoutAutomaticSwitching() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let lexicon = try Lexicon.load(from: root.appendingPathComponent("Resources"))
    for layout in KeyboardLayout.allCases {
        let koreanKeys = layout == .dubeol ? "gksrmf" : "mfskgw"
        let session = Session(lexicon: lexicon, mode: .english, layout: layout)
        for key in koreanKeys + " " { _ = session.input(key) }
        #expect(session.document == "한글 ", "\(layout): \(session.document)")
        #expect(session.mode == .korean)
        for key in "hello " { _ = session.input(key) }
        #expect(session.document == "한글 hello ")
        #expect(session.mode == .english)
    }
}

@Test func selectedLayoutTypoCorrection() {
    let lexicon = Lexicon(english: [], korean: ["한글"])
    for layout in KeyboardLayout.allCases {
        let keys = layout == .dubeol ? "gksrnf" : "mfskbw"
        let atoms = keys.map { layout.atom(for: $0) }
        #expect(Composer.compose(atoms).text == "한굴")
        #expect(TypoCorrector.correction(composed: "한굴", keys: atoms, language: .korean, lexicon: lexicon, memory: nil) == "한글", "\(layout.title)")
        let session = Session(lexicon: lexicon, autoSwitch: false, layout: layout)
        for key in keys + " " { _ = session.input(key) }
        #expect(session.document == "한글 ", "\(layout.title)")
    }
    let finalLexicon = Lexicon(english: [], korean: ["맑다"])
    let atoms = "if!uf".map(LayoutFinal.atom)
    #expect(Composer.compose(atoms).text == "맊다")
    #expect(TypoCorrector.correction(composed: "맊다", keys: atoms, language: .korean, lexicon: finalLexicon, memory: nil) == "맑다")
}

@Test func finalSingleKeyCompoundFinalDeletion() {
    let session = Session(lexicon: Lexicon(english: [], korean: []), autoSwitch: false, layout: .sebeolFinal)
    for key in "if@" { _ = session.input(key) }
    #expect(session.document == "맑")
    _ = session.backspace()
    #expect(session.document == "마")
}
