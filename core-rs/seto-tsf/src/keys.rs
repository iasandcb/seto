//! Hardware-key classification for the Windows text service.
//!
//! Virtual-key and scan-code values match WinUser.h / set-1 scan codes so the
//! module can be tested without the `windows` crate. Character mapping follows
//! the physical ANSI QWERTY position (scan code), the same contract as the
//! macOS virtual key codes and the Android HID usages. The core then reads
//! that QWERTY character as 세벌식 390.

use seto_core::ShiftSpaceToggleTracker;

/// Virtual keys this classifier cares about. Values are WinUser.h constants.
pub mod vk {
    pub const BACK: u16 = 0x08;
    pub const TAB: u16 = 0x09;
    pub const RETURN: u16 = 0x0D;
    pub const SHIFT: u16 = 0x10;
    pub const CONTROL: u16 = 0x11;
    pub const MENU: u16 = 0x12;
    pub const CAPITAL: u16 = 0x14;
    pub const HANGUL: u16 = 0x15;
    pub const HANJA: u16 = 0x19;
    pub const ESCAPE: u16 = 0x1B;
    pub const SPACE: u16 = 0x20;
    pub const PRIOR: u16 = 0x21;
    pub const NEXT: u16 = 0x22;
    pub const END: u16 = 0x23;
    pub const HOME: u16 = 0x24;
    pub const LEFT: u16 = 0x25;
    pub const UP: u16 = 0x26;
    pub const RIGHT: u16 = 0x27;
    pub const DOWN: u16 = 0x28;
    pub const SNAPSHOT: u16 = 0x2C;
    pub const INSERT: u16 = 0x2D;
    pub const DELETE: u16 = 0x2E;
    pub const LWIN: u16 = 0x5B;
    pub const RWIN: u16 = 0x5C;
    pub const NUMPAD0: u16 = 0x60;
    pub const NUMPAD9: u16 = 0x69;
    pub const F1: u16 = 0x70;
    pub const F24: u16 = 0x87;
    pub const LSHIFT: u16 = 0xA0;
    pub const RSHIFT: u16 = 0xA1;
    pub const LCONTROL: u16 = 0xA2;
    pub const RCONTROL: u16 = 0xA3;
    pub const LMENU: u16 = 0xA4;
    pub const RMENU: u16 = 0xA5;
    pub const OEM_1: u16 = 0xBA;
    pub const OEM_PLUS: u16 = 0xBB;
    pub const OEM_COMMA: u16 = 0xBC;
    pub const OEM_MINUS: u16 = 0xBD;
    pub const OEM_PERIOD: u16 = 0xBE;
    pub const OEM_2: u16 = 0xBF;
    pub const OEM_3: u16 = 0xC0;
    pub const OEM_4: u16 = 0xDB;
    pub const OEM_5: u16 = 0xDC;
    pub const OEM_6: u16 = 0xDD;
    pub const OEM_7: u16 = 0xDE;
    pub const OEM_102: u16 = 0xE2;
}

/// One key transition, already decoded from the Win32 message.
///
/// Modifier flags describe keys *held*, including the key of this event when
/// that key is itself a modifier. [`classify_down`] identifies the key from
/// `vk` / `extended` before it consults those flags.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WinKey {
    pub vk: u16,
    pub scan: u16,
    pub extended: bool,
    pub shift: bool,
    pub control: bool,
    pub left_alt: bool,
    pub right_alt: bool,
    pub win: bool,
    pub repeat: bool,
}

impl WinKey {
    pub const fn bare(vk: u16) -> Self {
        Self {
            vk,
            scan: 0,
            extended: false,
            shift: false,
            control: false,
            left_alt: false,
            right_alt: false,
            win: false,
            repeat: false,
        }
    }

    /// ANSI QWERTY character key. `ch` is the unshifted glyph; `shift` selects
    /// the shifted glyph and sets the modifier the way a real Shift hold does.
    pub fn qwerty(ch: char, shift: bool) -> Self {
        let (scan, vk, _shifted) = qwerty_position(ch).unwrap_or((0, 0, ch));
        Self {
            vk,
            scan,
            extended: false,
            shift,
            control: false,
            left_alt: false,
            right_alt: false,
            win: false,
            repeat: false,
        }
    }
}

/// Modifier and composition state the classifier is allowed to see.
/// `Copy` so a key-down test can step a snapshot without touching the engine.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct DecisionState {
    pub open_word: bool,
    pub shift_tracker: ShiftSpaceToggleTracker,
    pub right_alt_down: bool,
    pub right_alt_used: bool,
}

/// What a key-down means. The engine performs the session call; this enum
/// does not borrow the session.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DownClass {
    /// Not eaten. `commit` finishes the open word before the app sees the key.
    /// `ending_run` is true for Return, which clears sentence context.
    Pass {
        commit: bool,
        ending_run: bool,
        mark_right_alt_used: bool,
    },
    /// No open word: the session forgets one committed grapheme and the app
    /// performs the deletion.
    AppBackspace,
    Shift {
        down: bool,
    },
    /// Eaten, no session call. `begin_right_alt` arms the Right Alt tap.
    Swallow {
        begin_right_alt: bool,
    },
    Toggle,
    /// Eaten backspace while a word is open.
    Backspace,
    Input(char),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UpClass {
    Pass,
    /// Eaten key-up. `toggle` is a Right Alt tap (down and up with no chord).
    Eat {
        toggle: bool,
    },
}

pub fn step_down(state: &mut DecisionState, key: &WinKey) -> DownClass {
    let class = classify_down(key, state);
    match class {
        DownClass::Shift { down } => state.shift_tracker.shift_changed(down),
        DownClass::Swallow { begin_right_alt: true } => {
            state.right_alt_down = true;
            state.right_alt_used = false;
        }
        DownClass::Pass { mark_right_alt_used: true, .. } => state.right_alt_used = true,
        DownClass::Input(_) | DownClass::Toggle | DownClass::Backspace => {
            let _ = state.shift_tracker.key_down(is_space_key(key), key.shift);
        }
        _ => {}
    }
    class
}

pub fn step_up(state: &mut DecisionState, key: &WinKey) -> UpClass {
    if is_shift_key(key.vk) {
        state.shift_tracker.shift_changed(key.shift);
        return UpClass::Pass;
    }
    if is_right_alt_key(key) {
        if !state.right_alt_down {
            return UpClass::Pass;
        }
        let tap = !state.right_alt_used && !key.control && !key.win && !key.repeat;
        state.right_alt_down = false;
        state.right_alt_used = false;
        return UpClass::Eat { toggle: tap };
    }
    if is_hangul_key(key) || key.vk == vk::CAPITAL {
        return UpClass::Eat { toggle: false };
    }
    UpClass::Pass
}

pub fn eaten_down(class: DownClass) -> bool {
    matches!(class, DownClass::Swallow { .. } | DownClass::Toggle | DownClass::Backspace | DownClass::Input(_))
}

pub fn eaten_up(class: UpClass) -> bool {
    matches!(class, UpClass::Eat { .. })
}

pub fn classify_down(key: &WinKey, state: &DecisionState) -> DownClass {
    if is_shift_key(key.vk) {
        return DownClass::Shift { down: true };
    }
    if is_right_alt_key(key) {
        if key.control || key.win {
            return DownClass::Pass { commit: true, ending_run: false, mark_right_alt_used: false };
        }
        if key.repeat || state.right_alt_down {
            return DownClass::Swallow { begin_right_alt: false };
        }
        return DownClass::Swallow { begin_right_alt: true };
    }
    if is_modifier_key(key.vk) {
        return DownClass::Pass { commit: false, ending_run: false, mark_right_alt_used: false };
    }
    if key.control || key.win || key.left_alt || state.right_alt_down {
        return DownClass::Pass { commit: true, ending_run: false, mark_right_alt_used: state.right_alt_down };
    }
    if is_hangul_key(key) {
        if key.repeat {
            return DownClass::Swallow { begin_right_alt: false };
        }
        return DownClass::Toggle;
    }
    if key.vk == vk::CAPITAL {
        return DownClass::Swallow { begin_right_alt: false };
    }
    if key.vk == vk::BACK {
        return if state.open_word { DownClass::Backspace } else { DownClass::AppBackspace };
    }
    if is_navigation(key.vk) {
        return DownClass::Pass { commit: true, ending_run: key.vk == vk::RETURN, mark_right_alt_used: false };
    }
    if is_space_key(key) {
        let mut peek = state.shift_tracker;
        if peek.key_down(true, key.shift) {
            return DownClass::Toggle;
        }
    }
    if let Some(ch) = qwerty_char(key) {
        return DownClass::Input(ch);
    }
    DownClass::Pass { commit: true, ending_run: false, mark_right_alt_used: false }
}

fn is_hangul_key(key: &WinKey) -> bool {
    key.vk == vk::HANGUL
}

fn is_right_alt_key(key: &WinKey) -> bool {
    key.vk == vk::RMENU || (key.vk == vk::MENU && key.extended)
}

fn is_shift_key(vk: u16) -> bool {
    matches!(vk, vk::SHIFT | vk::LSHIFT | vk::RSHIFT)
}

fn is_modifier_key(vk: u16) -> bool {
    matches!(vk, vk::CONTROL | vk::LCONTROL | vk::RCONTROL | vk::MENU | vk::LMENU | vk::LWIN | vk::RWIN)
}

fn is_space_key(key: &WinKey) -> bool {
    key.vk == vk::SPACE || key.scan == 0x39
}

fn is_navigation(vk: u16) -> bool {
    matches!(
        vk,
        vk::TAB
            | vk::RETURN
            | vk::ESCAPE
            | vk::PRIOR
            | vk::NEXT
            | vk::END
            | vk::HOME
            | vk::LEFT
            | vk::UP
            | vk::RIGHT
            | vk::DOWN
            | vk::SNAPSHOT
            | vk::INSERT
            | vk::DELETE
            | vk::HANJA
    ) || (vk::F1..=vk::F24).contains(&vk)
        || (vk::NUMPAD0..=vk::NUMPAD9).contains(&vk)
}

/// Unshifted and shifted ANSI glyphs for a set-1 scan code, ignoring extended
/// keys (arrows share some of these scans).
fn scan_pair(scan: u16) -> Option<(char, char)> {
    let pair = match scan {
        0x02 => ('1', '!'),
        0x03 => ('2', '@'),
        0x04 => ('3', '#'),
        0x05 => ('4', '$'),
        0x06 => ('5', '%'),
        0x07 => ('6', '^'),
        0x08 => ('7', '&'),
        0x09 => ('8', '*'),
        0x0A => ('9', '('),
        0x0B => ('0', ')'),
        0x0C => ('-', '_'),
        0x0D => ('=', '+'),
        0x10 => ('q', 'Q'),
        0x11 => ('w', 'W'),
        0x12 => ('e', 'E'),
        0x13 => ('r', 'R'),
        0x14 => ('t', 'T'),
        0x15 => ('y', 'Y'),
        0x16 => ('u', 'U'),
        0x17 => ('i', 'I'),
        0x18 => ('o', 'O'),
        0x19 => ('p', 'P'),
        0x1A => ('[', '{'),
        0x1B => (']', '}'),
        0x1E => ('a', 'A'),
        0x1F => ('s', 'S'),
        0x20 => ('d', 'D'),
        0x21 => ('f', 'F'),
        0x22 => ('g', 'G'),
        0x23 => ('h', 'H'),
        0x24 => ('j', 'J'),
        0x25 => ('k', 'K'),
        0x26 => ('l', 'L'),
        0x27 => (';', ':'),
        0x28 => ('\'', '"'),
        0x29 => ('`', '~'),
        0x2B => ('\\', '|'),
        0x2C => ('z', 'Z'),
        0x2D => ('x', 'X'),
        0x2E => ('c', 'C'),
        0x2F => ('v', 'V'),
        0x30 => ('b', 'B'),
        0x31 => ('n', 'N'),
        0x32 => ('m', 'M'),
        0x33 => (',', '<'),
        0x34 => ('.', '>'),
        0x35 => ('/', '?'),
        0x39 => (' ', ' '),
        0x56 => ('\\', '|'),
        _ => return None,
    };
    Some(pair)
}

fn qwerty_position(ch: char) -> Option<(u16, u16, char)> {
    let unshifted = if ch.is_ascii_uppercase() { ch.to_ascii_lowercase() } else { ch };
    let (scan, vk, shifted) = match unshifted {
        '1' => (0x02, b'1' as u16, '!'),
        '2' => (0x03, b'2' as u16, '@'),
        '3' => (0x04, b'3' as u16, '#'),
        '4' => (0x05, b'4' as u16, '$'),
        '5' => (0x06, b'5' as u16, '%'),
        '6' => (0x07, b'6' as u16, '^'),
        '7' => (0x08, b'7' as u16, '&'),
        '8' => (0x09, b'8' as u16, '*'),
        '9' => (0x0A, b'9' as u16, '('),
        '0' => (0x0B, b'0' as u16, ')'),
        '-' => (0x0C, vk::OEM_MINUS, '_'),
        '=' => (0x0D, vk::OEM_PLUS, '+'),
        'q' => (0x10, b'Q' as u16, 'Q'),
        'w' => (0x11, b'W' as u16, 'W'),
        'e' => (0x12, b'E' as u16, 'E'),
        'r' => (0x13, b'R' as u16, 'R'),
        't' => (0x14, b'T' as u16, 'T'),
        'y' => (0x15, b'Y' as u16, 'Y'),
        'u' => (0x16, b'U' as u16, 'U'),
        'i' => (0x17, b'I' as u16, 'I'),
        'o' => (0x18, b'O' as u16, 'O'),
        'p' => (0x19, b'P' as u16, 'P'),
        '[' => (0x1A, vk::OEM_4, '{'),
        ']' => (0x1B, vk::OEM_6, '}'),
        'a' => (0x1E, b'A' as u16, 'A'),
        's' => (0x1F, b'S' as u16, 'S'),
        'd' => (0x20, b'D' as u16, 'D'),
        'f' => (0x21, b'F' as u16, 'F'),
        'g' => (0x22, b'G' as u16, 'G'),
        'h' => (0x23, b'H' as u16, 'H'),
        'j' => (0x24, b'J' as u16, 'J'),
        'k' => (0x25, b'K' as u16, 'K'),
        'l' => (0x26, b'L' as u16, 'L'),
        ';' => (0x27, vk::OEM_1, ':'),
        '\'' => (0x28, vk::OEM_7, '"'),
        '`' => (0x29, vk::OEM_3, '~'),
        '\\' => (0x2B, vk::OEM_5, '|'),
        'z' => (0x2C, b'Z' as u16, 'Z'),
        'x' => (0x2D, b'X' as u16, 'X'),
        'c' => (0x2E, b'C' as u16, 'C'),
        'v' => (0x2F, b'V' as u16, 'V'),
        'b' => (0x30, b'B' as u16, 'B'),
        'n' => (0x31, b'N' as u16, 'N'),
        'm' => (0x32, b'M' as u16, 'M'),
        ',' => (0x33, vk::OEM_COMMA, '<'),
        '.' => (0x34, vk::OEM_PERIOD, '>'),
        '/' => (0x35, vk::OEM_2, '?'),
        ' ' => (0x39, vk::SPACE, ' '),
        _ => return None,
    };
    Some((scan, vk, shifted))
}

/// QWERTY glyph for this physical key. Scan code wins over the virtual key so
/// a non-US layout still feeds 세벌식 390 by position. Extended scans are not
/// characters (they are arrows and the numeric keypad's navigation aliases).
pub fn qwerty_char(key: &WinKey) -> Option<char> {
    if !key.extended
        && let Some((plain, shifted)) = scan_pair(key.scan)
    {
        return Some(if key.shift { shifted } else { plain });
    }
    vk_char(key.vk, key.shift)
}

fn vk_char(vk: u16, shift: bool) -> Option<char> {
    if (b'A' as u16..=b'Z' as u16).contains(&vk) {
        let lower = (b'a' + (vk - b'A' as u16) as u8) as char;
        return Some(if shift { lower.to_ascii_uppercase() } else { lower });
    }
    if (b'0' as u16..=b'9' as u16).contains(&vk) {
        let index = (vk - b'0' as u16) as usize;
        let plain = b"0123456789"[index] as char;
        let shifted = b")!@#$%^&*("[index] as char;
        return Some(if shift { shifted } else { plain });
    }
    let (plain, shifted) = match vk {
        vk::OEM_3 => ('`', '~'),
        vk::OEM_MINUS => ('-', '_'),
        vk::OEM_PLUS => ('=', '+'),
        vk::OEM_4 => ('[', '{'),
        vk::OEM_6 => (']', '}'),
        vk::OEM_5 | vk::OEM_102 => ('\\', '|'),
        vk::OEM_1 => (';', ':'),
        vk::OEM_7 => ('\'', '"'),
        vk::OEM_COMMA => (',', '<'),
        vk::OEM_PERIOD => ('.', '>'),
        vk::OEM_2 => ('/', '?'),
        vk::SPACE => (' ', ' '),
        _ => return None,
    };
    Some(if shift { shifted } else { plain })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn down(key: WinKey, state: &mut DecisionState) -> DownClass {
        step_down(state, &key)
    }

    #[test]
    fn scan_code_beats_a_lying_virtual_key() {
        let mut key = WinKey::qwerty('k', false);
        key.vk = b'Q' as u16;
        assert_eq!(qwerty_char(&key), Some('k'));
        key.extended = true;
        key.scan = 0x25;
        key.vk = b'K' as u16;
        assert_eq!(qwerty_char(&key), Some('k'));
    }

    #[test]
    fn letters_digits_and_punctuation_follow_ansi() {
        assert_eq!(qwerty_char(&WinKey::qwerty('a', false)), Some('a'));
        assert_eq!(qwerty_char(&WinKey::qwerty('a', true)), Some('A'));
        assert_eq!(qwerty_char(&WinKey::qwerty('1', false)), Some('1'));
        assert_eq!(qwerty_char(&WinKey::qwerty('1', true)), Some('!'));
        assert_eq!(qwerty_char(&WinKey::qwerty('/', false)), Some('/'));
        assert_eq!(qwerty_char(&WinKey::qwerty('/', true)), Some('?'));
        let mut vk_only = WinKey::bare(b'K' as u16);
        assert_eq!(qwerty_char(&vk_only), Some('k'));
        vk_only.shift = true;
        assert_eq!(qwerty_char(&vk_only), Some('K'));
    }

    #[test]
    fn shortcuts_pass_through_and_hangul_keys_toggle() {
        let mut state = DecisionState::default();
        let mut ctrl_c = WinKey::qwerty('c', false);
        ctrl_c.control = true;
        assert!(matches!(down(ctrl_c, &mut state), DownClass::Pass { commit: true, .. }));

        let mut alt_f = WinKey::qwerty('f', false);
        alt_f.left_alt = true;
        assert!(matches!(down(alt_f, &mut state), DownClass::Pass { commit: true, .. }));

        let mut win_r = WinKey::qwerty('r', false);
        win_r.win = true;
        assert!(matches!(down(win_r, &mut state), DownClass::Pass { commit: true, .. }));

        assert!(matches!(down(WinKey::bare(vk::HANGUL), &mut state), DownClass::Toggle));
        let mut repeat = WinKey::bare(vk::HANGUL);
        repeat.repeat = true;
        assert!(matches!(down(repeat, &mut state), DownClass::Swallow { begin_right_alt: false }));
    }

    #[test]
    fn right_alt_tap_toggles_and_a_chord_does_not() {
        let mut state = DecisionState::default();
        let right_alt = WinKey { vk: vk::RMENU, right_alt: true, ..WinKey::bare(vk::RMENU) };
        assert!(matches!(down(right_alt, &mut state), DownClass::Swallow { begin_right_alt: true }));
        assert!(state.right_alt_down);
        assert!(matches!(step_up(&mut state, &right_alt), UpClass::Eat { toggle: true }));
        assert!(!state.right_alt_down);

        assert!(matches!(down(right_alt, &mut state), DownClass::Swallow { begin_right_alt: true }));
        let mut chord = WinKey::qwerty('s', false);
        chord.right_alt = true;
        assert!(matches!(down(chord, &mut state), DownClass::Pass { commit: true, mark_right_alt_used: true, .. }));
        assert!(state.right_alt_used);
        assert!(matches!(step_up(&mut state, &right_alt), UpClass::Eat { toggle: false }));
    }

    #[test]
    fn shift_space_tracks_other_shifted_keys() {
        let mut state = DecisionState::default();
        assert!(matches!(down(WinKey::bare(vk::LSHIFT), &mut state), DownClass::Shift { down: true }));
        let space = WinKey::qwerty(' ', true);
        assert!(matches!(down(space, &mut state), DownClass::Toggle));

        assert!(matches!(down(WinKey::bare(vk::LSHIFT), &mut state), DownClass::Shift { down: true }));
        assert!(matches!(down(WinKey::qwerty('/', true), &mut state), DownClass::Input('?')));
        assert!(matches!(down(WinKey::qwerty(' ', true), &mut state), DownClass::Input(' ')));
    }

    #[test]
    fn backspace_enter_and_navigation() {
        let mut state = DecisionState { open_word: true, ..DecisionState::default() };
        assert!(matches!(down(WinKey::bare(vk::BACK), &mut state), DownClass::Backspace));
        state.open_word = false;
        assert!(matches!(down(WinKey::bare(vk::BACK), &mut state), DownClass::AppBackspace));
        assert!(matches!(
            down(WinKey::bare(vk::RETURN), &mut state),
            DownClass::Pass { commit: true, ending_run: true, .. }
        ));
        assert!(matches!(
            down(WinKey::bare(vk::LEFT), &mut state),
            DownClass::Pass { commit: true, ending_run: false, .. }
        ));
        let mut ctrl_back = WinKey::bare(vk::BACK);
        ctrl_back.control = true;
        state.open_word = true;
        assert!(matches!(down(ctrl_back, &mut state), DownClass::Pass { commit: true, .. }));
    }
}
