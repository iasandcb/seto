//! Mirrors Tests/Sebeol390CoreTests/ShiftSpaceToggleTrackerTests.swift.

use seto_core::ShiftSpaceToggleTracker;

#[test]
fn shift_space_toggles_when_no_other_key_was_typed() {
    let mut tracker = ShiftSpaceToggleTracker::new();
    tracker.shift_changed(true);
    assert!(tracker.key_down(true, true));
}

#[test]
fn shift_slash_then_space_does_not_toggle() {
    let mut tracker = ShiftSpaceToggleTracker::new();
    tracker.shift_changed(true);
    assert!(!tracker.key_down(false, true));
    assert!(!tracker.key_down(true, true));
}

#[test]
fn releasing_and_repressing_shift_restores_toggle() {
    let mut tracker = ShiftSpaceToggleTracker::new();
    tracker.shift_changed(true);
    let _ = tracker.key_down(false, true);
    tracker.shift_changed(false);
    tracker.shift_changed(true);
    assert!(tracker.key_down(true, true));
}

#[test]
fn space_without_shift_never_toggles() {
    let mut tracker = ShiftSpaceToggleTracker::new();
    assert!(!tracker.key_down(true, false));
}
