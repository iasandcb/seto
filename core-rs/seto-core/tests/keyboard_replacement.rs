//! Mirrors Tests/Sebeol390CoreTests/KeyboardReplacementTests.swift. The
//! session replay uses the documents the Swift Session produced for the same
//! keys, recorded in testdata/session-golden.json.

mod common;

use seto_core::KeyboardReplacement;
use unicode_segmentation::UnicodeSegmentation;

#[test]
fn keyboard_replacement_uses_graphemes() {
    let change = KeyboardReplacement::between("가족 👨‍👩‍👧‍👦가", "가족 👨‍👩‍👧‍👦각");
    assert_eq!(change.delete_count(), 1);
    assert_eq!(change.removed, "가");
    assert_eq!(change.inserted, "각");
    assert_eq!(KeyboardReplacement::between("한", "").delete_count(), 1);
    assert_eq!(KeyboardReplacement::between("", "한").inserted, "한");
    // Characters compare by canonical equivalence, like Swift.
    let decomposed = "\u{1112}\u{1161}\u{11AB}";
    assert_eq!(KeyboardReplacement::between("한a", &format!("{decomposed}b")).removed, "a");
}

#[test]
fn keyboard_replacement_replays_session() {
    let golden = common::golden();
    let name = "KeyboardReplacementTests/keyboardReplacementReplaysSession()#1";
    let scenario = golden
        .scenarios
        .iter()
        .find(|scenario| scenario.name == name || scenario.aliases.iter().any(|alias| alias == name))
        .expect("recorded scenario");
    assert!(scenario.steps.len() > 20);
    let mut client = String::new();
    let mut before = String::new();
    for step in &scenario.steps {
        let change = KeyboardReplacement::between(&before, &step.document);
        assert!(client.ends_with(&change.removed), "{client:?} {change:?}");
        let keep = client.graphemes(true).count() - change.delete_count();
        client = client.graphemes(true).take(keep).collect::<String>() + &change.inserted;
        assert_eq!(client, step.document);
        before = step.document.clone();
    }
    assert_eq!(client, "");
}
