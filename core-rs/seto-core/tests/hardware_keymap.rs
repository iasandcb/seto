//! Mirrors Tests/Sebeol390CoreTests/HardwareKeymapTests.swift.

mod common;

use seto_core::{HardwareKeyAction, Modifiers, compose, hardware_keymap::action, layout390};

fn shift() -> Modifiers {
    Modifiers::SHIFT
}

#[test]
fn hardware_uses_physical_qwerty_positions() {
    for (offset, key) in "abcdefghijklmnopqrstuvwxyz".chars().enumerate() {
        let usage = 4 + offset as i64;
        assert_eq!(action(usage, Modifiers::NONE), HardwareKeyAction::Input(key));
        assert_eq!(action(usage, shift()), HardwareKeyAction::Input(key.to_ascii_uppercase()));
    }
    for (offset, (plain, shifted)) in "1234567890".chars().zip("!@#$%^&*()".chars()).enumerate() {
        let usage = 30 + offset as i64;
        assert_eq!(action(usage, Modifiers::NONE), HardwareKeyAction::Input(plain));
        assert_eq!(action(usage, shift()), HardwareKeyAction::Input(shifted));
    }
    assert_eq!(action(54, shift()), HardwareKeyAction::Input('<'));
    assert_eq!(action(56, Modifiers::NONE), HardwareKeyAction::Input('/'));
    assert_eq!(action(100, Modifiers::NONE), HardwareKeyAction::Input('\\'));
}

#[test]
fn hardware_preserves_native_shortcuts_and_navigation() {
    assert_eq!(action(44, shift()), HardwareKeyAction::Toggle);
    assert_eq!(action(44, Modifiers::NONE), HardwareKeyAction::Input(' '));
    assert_eq!(action(42, Modifiers::NONE), HardwareKeyAction::Backspace);
    for usage in [40, 41, 43, 57, 76, 79, 80, 81, 82, 224, 225, 999] {
        assert_eq!(action(usage, Modifiers::NONE), HardwareKeyAction::PassThrough, "{usage}");
    }
    for usage in [4, 42, 44] {
        let command = Modifiers { shift: true, command: true, ..Modifiers::NONE };
        let control = Modifiers { control: true, ..Modifiers::NONE };
        let option = Modifiers { option: true, ..Modifiers::NONE };
        assert_eq!(action(usage, command), HardwareKeyAction::PassThrough);
        assert_eq!(action(usage, control), HardwareKeyAction::PassThrough);
        assert_eq!(action(usage, option), HardwareKeyAction::PassThrough);
    }
}

#[test]
fn hardware_composes_jamo() {
    // hardwareComposesAndDeletesJamo: k = ㄱ, f = ㅏ, x = final ㄱ. The
    // Session half (backspace, toggle) is in the golden corpus.
    let keys: Vec<_> = [14, 9, 27]
        .into_iter()
        .map(|usage| match action(usage, Modifiers::NONE) {
            HardwareKeyAction::Input(character) => layout390::atom(character),
            other => panic!("{usage} produced {other:?}"),
        })
        .collect();
    assert_eq!(compose(&keys).text, "각");
    assert_eq!(compose(&keys[..2]).text, "가");
}
