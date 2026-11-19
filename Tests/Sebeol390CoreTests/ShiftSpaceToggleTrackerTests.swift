import Testing
#if SETO_ORACLE
@testable import SetoOracle
#else
@testable import SetoCore
#endif

@Test func shiftSpaceTogglesWhenNoOtherKeyWasTyped() {
    var tracker = ShiftSpaceToggleTracker()
    tracker.shiftChanged(isDown: true)
    do { let r = tracker.keyDown(isSpace: true, shift: true); #expect(r) }
}

@Test func shiftSlashThenSpaceDoesNotToggle() {
    var tracker = ShiftSpaceToggleTracker()
    tracker.shiftChanged(isDown: true)
    do { let r = tracker.keyDown(isSpace: false, shift: true); #expect(!r) }
    do { let r = tracker.keyDown(isSpace: true, shift: true); #expect(!r) }
}

@Test func releasingAndRepressingShiftRestoresToggle() {
    var tracker = ShiftSpaceToggleTracker()
    tracker.shiftChanged(isDown: true)
    _ = tracker.keyDown(isSpace: false, shift: true)
    tracker.shiftChanged(isDown: false)
    tracker.shiftChanged(isDown: true)
    do { let r = tracker.keyDown(isSpace: true, shift: true); #expect(r) }
}

@Test func spaceWithoutShiftNeverToggles() {
    var tracker = ShiftSpaceToggleTracker()
    do { let r = tracker.keyDown(isSpace: true, shift: false); #expect(!r) }
}
