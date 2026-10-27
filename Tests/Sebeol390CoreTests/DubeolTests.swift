import Testing
@testable import Sebeol390Core

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
