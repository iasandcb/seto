import Testing
@testable import SetoCore

private func action(_ keyCode: UInt16, command: Bool = false, control: Bool = false,
                    option: Bool = false, shift: Bool = false) -> RefinementPanelKey {
    RefinementPanelKey.action(keyCode: keyCode, command: command, control: control,
                              option: option, shift: shift)
}

@Test func returnAndEnterAccept() {
    #expect(action(0x24) == .accept)
    #expect(action(0x4C) == .accept)
}

@Test func escapeCancels() {
    #expect(action(0x35) == .cancel)
}

@Test func tabShowsNext() {
    #expect(action(0x30) == .next)
}

@Test func shiftIsIgnored() {
    #expect(action(0x30, shift: true) == .next)
    #expect(action(0x24, shift: true) == .accept)
    #expect(action(0x35, shift: true) == .cancel)
}

@Test func shortcutModifiersPassThrough() {
    for key: UInt16 in [0x24, 0x4C, 0x35, 0x30] {
        #expect(action(key, command: true) == .other)
        #expect(action(key, control: true) == .other)
        #expect(action(key, option: true) == .other)
        #expect(action(key, command: true, shift: true) == .other)
    }
}

@Test func otherKeysPassThrough() {
    // Space, A, L, Left arrow, Delete.
    for key: UInt16 in [0x31, 0x00, 0x25, 0x7B, 0x33] {
        #expect(action(key) == .other)
        #expect(!RefinementPanelKey.isPanelKey(key))
    }
    for key: UInt16 in [0x24, 0x4C, 0x35, 0x30] {
        #expect(RefinementPanelKey.isPanelKey(key))
    }
}
