import Testing
@testable import SetoCore

@Test func keyboardReplacementUsesGraphemes() {
    let change = KeyboardReplacement.between("가족 👨‍👩‍👧‍👦가", "가족 👨‍👩‍👧‍👦각")
    #expect(change.deleteCount == 1)
    #expect(change.removed == "가")
    #expect(change.inserted == "각")
    #expect(KeyboardReplacement.between("한", "").deleteCount == 1)
    #expect(KeyboardReplacement.between("", "한").inserted == "한")
}

@Test func keyboardReplacementReplaysSession() {
    let session = Session(lexicon: Lexicon(english: ["hello", "deploy"], korean: ["한글"]))
    var client = ""
    func apply(_ operation: () -> Void) {
        let before = session.document
        operation()
        let change = KeyboardReplacement.between(before, session.document)
        #expect(client.hasSuffix(change.removed))
        client = String(client.dropLast(change.deleteCount)) + change.inserted
        #expect(client == session.document)
    }
    for key in "hello deploy " { apply { _ = session.input(key) } }
    apply { _ = session.toggle() }
    apply { _ = session.backspace() }
    for key in "kfx " { apply { _ = session.input(key) } }
    for _ in 0..<client.count + 2 { apply { _ = session.backspace() } }
}
