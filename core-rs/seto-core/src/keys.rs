//! Ports of `Keymap.swift`, `HardwareKeymap.swift`, `KeyboardReplacement.swift`
//! and `ShiftSpaceToggleTracker.swift`.

use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

/// ANSI QWERTY macOS virtual key codes. Physical position, not the active layout.
pub mod keymap {
    pub const CAPS_LOCK: u16 = 0x39;
    pub const DELETE: u16 = 0x33;
    pub const RETURN: u16 = 0x24;
    pub const TAB: u16 = 0x30;
    pub const ESCAPE: u16 = 0x35;
    pub const SPACE: u16 = 0x31;

    pub fn qwerty_character(key_code: u16, shift: bool) -> Option<char> {
        let (unshifted, shifted) = match key_code {
            0x00 => ('a', 'A'),
            0x01 => ('s', 'S'),
            0x02 => ('d', 'D'),
            0x03 => ('f', 'F'),
            0x04 => ('h', 'H'),
            0x05 => ('g', 'G'),
            0x06 => ('z', 'Z'),
            0x07 => ('x', 'X'),
            0x08 => ('c', 'C'),
            0x09 => ('v', 'V'),
            0x0B => ('b', 'B'),
            0x0C => ('q', 'Q'),
            0x0D => ('w', 'W'),
            0x0E => ('e', 'E'),
            0x0F => ('r', 'R'),
            0x10 => ('y', 'Y'),
            0x11 => ('t', 'T'),
            0x12 => ('1', '!'),
            0x13 => ('2', '@'),
            0x14 => ('3', '#'),
            0x15 => ('4', '$'),
            0x16 => ('6', '^'),
            0x17 => ('5', '%'),
            0x18 => ('=', '+'),
            0x19 => ('9', '('),
            0x1A => ('7', '&'),
            0x1B => ('-', '_'),
            0x1C => ('8', '*'),
            0x1D => ('0', ')'),
            0x1E => (']', '}'),
            0x1F => ('o', 'O'),
            0x20 => ('u', 'U'),
            0x21 => ('[', '{'),
            0x22 => ('i', 'I'),
            0x23 => ('p', 'P'),
            0x25 => ('l', 'L'),
            0x26 => ('j', 'J'),
            0x27 => ('\'', '"'),
            0x28 => ('k', 'K'),
            0x29 => (';', ':'),
            0x2A => ('\\', '|'),
            0x2B => (',', '<'),
            0x2C => ('/', '?'),
            0x2D => ('n', 'N'),
            0x2E => ('m', 'M'),
            0x2F => ('.', '>'),
            0x31 => (' ', ' '),
            0x32 => ('`', '~'),
            _ => return None,
        };
        Some(if shift { shifted } else { unshifted })
    }

    /// Arrows, Tab, Escape, Return, and the other keys that move through the
    /// app instead of composing. Home, End, Page Up/Down, Forward Delete, and
    /// F1/F2 are included so they are not swallowed.
    pub fn is_navigation(key_code: u16) -> bool {
        matches!(
            key_code,
            RETURN | TAB | ESCAPE | 0x73 | 0x74 | 0x75 | 0x77 | 0x78 | 0x79 | 0x7A | 0x7B | 0x7C | 0x7D | 0x7E
        )
    }
}

/// USB HID keyboard usages used by UIKit's `UIKey.keyCode`. Unlike macOS
/// virtual key codes these identify keys independently of the system layout.
pub mod hardware_keymap {
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum HardwareKeyAction {
        Input(char),
        Backspace,
        Toggle,
        PassThrough,
    }

    #[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
    pub struct Modifiers {
        pub shift: bool,
        pub command: bool,
        pub control: bool,
        pub option: bool,
    }

    impl Modifiers {
        pub const NONE: Modifiers = Modifiers { shift: false, command: false, control: false, option: false };
        pub const SHIFT: Modifiers = Modifiers { shift: true, command: false, control: false, option: false };
    }

    pub fn action(usage: i64, modifiers: Modifiers) -> HardwareKeyAction {
        if modifiers.command || modifiers.control || modifiers.option {
            return HardwareKeyAction::PassThrough;
        }
        if usage == 44 && modifiers.shift {
            return HardwareKeyAction::Toggle;
        }
        if usage == 42 {
            return HardwareKeyAction::Backspace;
        }
        // Caps Lock is commonly reserved by iOS for changing system input
        // sources. Use Shift+Space rather than depending on its delivery.
        match position(usage) {
            Some((plain, shifted)) => HardwareKeyAction::Input(if modifiers.shift { shifted } else { plain }),
            None => HardwareKeyAction::PassThrough,
        }
    }

    fn position(usage: i64) -> Option<(char, char)> {
        const LETTERS: &[u8] = b"abcdefghijklmnopqrstuvwxyz";
        const DIGITS: (&[u8], &[u8]) = (b"1234567890", b"!@#$%^&*()");
        const ROW: (&[u8], &[u8]) = (b"-=[]\\", b"_+{}|");
        const RIGHT: (&[u8], &[u8]) = (b";'`,./", b":\"~<>?");
        let pick = |table: (&[u8], &[u8]), index: i64| {
            let index = usize::try_from(index).ok()?;
            Some((*table.0.get(index)? as char, *table.1.get(index)? as char))
        };
        match usage {
            4..=29 => {
                let letter = LETTERS[(usage - 4) as usize] as char;
                Some((letter, letter.to_ascii_uppercase()))
            }
            30..=39 => pick(DIGITS, usage - 30),
            44 => Some((' ', ' ')),
            45..=49 => pick(ROW, usage - 45),
            51..=56 => pick(RIGHT, usage - 51),
            // ISO non-US backslash key (same symbols as its ANSI counterpart).
            100 => Some(('\\', '|')),
            _ => None,
        }
    }
}

/// A grapheme-based edit for clients, such as iOS keyboard extensions, which
/// can insert text and delete backward but cannot set a marked range.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeyboardReplacement {
    pub removed: String,
    pub inserted: String,
}

impl KeyboardReplacement {
    /// Number of grapheme clusters (Swift `Character`s) to delete backward.
    pub fn delete_count(&self) -> usize {
        self.removed.graphemes(true).count()
    }

    pub fn between(before: &str, after: &str) -> Self {
        let mut shared_bytes = (0, 0);
        for (left, right) in before.graphemes(true).zip(after.graphemes(true)) {
            if !same_character(left, right) {
                break;
            }
            shared_bytes.0 += left.len();
            shared_bytes.1 += right.len();
        }
        KeyboardReplacement {
            removed: before[shared_bytes.0..].to_owned(),
            inserted: after[shared_bytes.1..].to_owned(),
        }
    }
}

/// Swift `Character` equality is canonical equivalence.
fn same_character(left: &str, right: &str) -> bool {
    left == right || left.nfc().eq(right.nfc())
}

/// Decides whether Shift+Space is a language toggle. Typing `?` (Shift+/) and
/// then Space with Shift still held must stay a normal space, so the toggle
/// only counts when no other key was typed since Shift went down.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ShiftSpaceToggleTracker {
    shift_down: bool,
    other_key_typed: bool,
}

impl ShiftSpaceToggleTracker {
    pub fn new() -> Self {
        Self::default()
    }

    /// Feed every flagsChanged event with the current Shift state.
    pub fn shift_changed(&mut self, is_down: bool) {
        if is_down && !self.shift_down {
            self.other_key_typed = false;
        }
        self.shift_down = is_down;
    }

    /// Feed every keyDown. Returns true if this key is a Shift+Space toggle.
    pub fn key_down(&mut self, is_space: bool, shift: bool) -> bool {
        if is_space {
            return shift && !self.other_key_typed;
        }
        if shift {
            self.other_key_typed = true;
        }
        false
    }
}
