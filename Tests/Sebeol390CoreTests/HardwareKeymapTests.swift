import Testing
#if SETO_ORACLE
@testable import SetoOracle
#else
@testable import SetoCore
#endif

@Test func hardwareUsesPhysicalQwertyPositions() {
    for (offset, key) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
        #expect(HardwareKeymap.action(usage: 4 + offset) == .input(key))
        #expect(HardwareKeymap.action(usage: 4 + offset, shift: true) == .input(Character(String(key).uppercased())))
    }
    for (offset, pair) in zip("1234567890", "!@#$%^&*()").enumerated() {
        #expect(HardwareKeymap.action(usage: 30 + offset) == .input(pair.0))
        #expect(HardwareKeymap.action(usage: 30 + offset, shift: true) == .input(pair.1))
    }
    #expect(HardwareKeymap.action(usage: 54, shift: true) == .input("<"))
    #expect(HardwareKeymap.action(usage: 56) == .input("/"))
    #expect(HardwareKeymap.action(usage: 100) == .input("\\"))
}

@Test func hardwarePreservesNativeShortcutsAndNavigation() {
    #expect(HardwareKeymap.action(usage: 44, shift: true) == .toggle)
    #expect(HardwareKeymap.action(usage: 44) == .input(" "))
    #expect(HardwareKeymap.action(usage: 42) == .backspace)
    for usage in [40, 41, 43, 57, 76, 79, 80, 81, 82, 224, 225, 999] {
        #expect(HardwareKeymap.action(usage: usage) == .passThrough)
    }
    for usage in [4, 42, 44] {
        #expect(HardwareKeymap.action(usage: usage, shift: true, command: true) == .passThrough)
        #expect(HardwareKeymap.action(usage: usage, control: true) == .passThrough)
        #expect(HardwareKeymap.action(usage: usage, option: true) == .passThrough)
    }
}

@Test func hardwareComposesAndDeletesJamo() {
    let session = Session(lexicon: Lexicon(english: [], korean: []), autoSwitch: false)
    // k = ㄱ, f = ㅏ, x = final ㄱ.
    for usage in [14, 9, 27] {
        if case .input(let character) = HardwareKeymap.action(usage: usage) { _ = session.input(character) }
    }
    #expect(session.document == "각")
    _ = session.backspace()
    #expect(session.document == "가")
    _ = session.toggle()
    #expect(session.mode == .english)
}
