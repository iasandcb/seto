//! Ports of `KeyboardLayout.swift`, `Layout390.swift`, `LayoutFinal.swift`
//! and `LayoutDubeol.swift`.

use serde::{Deserialize, Serialize};

use crate::hangul::Jamo;

/// What a key produces in the Korean reading.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum KeyOutput {
    Jamo(Jamo),
    Character(char),
}

/// One physical key: its QWERTY character and its Korean reading.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct KeyAtom {
    pub layout: KeyboardLayout,
    pub english: char,
    pub korean: KeyOutput,
}

impl KeyAtom {
    pub fn is_dubeol(&self) -> bool {
        self.layout == KeyboardLayout::Dubeol
    }

    /// Punctuation that is the same in both readings and ends a word.
    pub fn is_neutral_breaker(&self) -> bool {
        match self.korean {
            KeyOutput::Character(korean) if korean == self.english => !(korean.is_alphabetic() || korean.is_numeric()),
            _ => false,
        }
    }
}

/// Korean layout is independent of the current Korean/English language.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum KeyboardLayout {
    #[default]
    Sebeol390,
    Dubeol,
    SebeolFinal,
}

impl KeyboardLayout {
    /// Same order as Swift's `CaseIterable`.
    pub const ALL: [KeyboardLayout; 3] =
        [KeyboardLayout::Sebeol390, KeyboardLayout::Dubeol, KeyboardLayout::SebeolFinal];

    /// Swift `rawValue`.
    pub fn raw_value(self) -> &'static str {
        match self {
            KeyboardLayout::Sebeol390 => "sebeol390",
            KeyboardLayout::Dubeol => "dubeol",
            KeyboardLayout::SebeolFinal => "sebeolFinal",
        }
    }

    pub fn from_raw_value(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|layout| layout.raw_value() == raw)
    }

    pub fn title(self) -> &'static str {
        match self {
            KeyboardLayout::Sebeol390 => "세벌식 390",
            KeyboardLayout::Dubeol => "두벌식",
            KeyboardLayout::SebeolFinal => "세벌식 최종",
        }
    }

    pub fn atom(self, key: char) -> KeyAtom {
        match self {
            KeyboardLayout::Sebeol390 => layout390::atom(key),
            KeyboardLayout::Dubeol => dubeol::atom(key),
            KeyboardLayout::SebeolFinal => final_layout::atom(key),
        }
    }
}

const fn j(jamo: Jamo) -> Option<KeyOutput> {
    Some(KeyOutput::Jamo(jamo))
}

const fn c(character: char) -> Option<KeyOutput> {
    Some(KeyOutput::Character(character))
}

/// 한글문화원 IBM-3-90 (1990), the layout macOS calls 세벌식 390.
///
/// Choseong sits on the right, jungseong and jongseong on the left. Digits on
/// the number row are jamo; the digits 0–9 themselves sit on the shifted
/// right-hand "keypad" (7 8 9 / 4 5 6 / 1 2 3 / 0). Six symbols move off the
/// QWERTY positions: ! / ; < > '
pub mod layout390 {
    use super::{KeyAtom, KeyOutput, KeyboardLayout, c, j};
    use crate::hangul::Jamo;

    pub fn atom(english: char) -> KeyAtom {
        let korean = table(english).unwrap_or(KeyOutput::Character(english));
        KeyAtom { layout: KeyboardLayout::Sebeol390, english, korean }
    }

    pub fn contains(english: char) -> bool {
        table(english).is_some()
    }

    pub(crate) fn table(key: char) -> Option<KeyOutput> {
        match key {
            '`' => c('`'),
            '1' => j(Jamo::jong(0x11C2)), // ㅎ
            '2' => j(Jamo::jong(0x11BB)), // ㅆ
            '3' => j(Jamo::jong(0x11B8)), // ㅂ
            '4' => j(Jamo::jung(0x116D)), // ㅛ
            '5' => j(Jamo::jung(0x1172)), // ㅠ
            '6' => j(Jamo::jung(0x1163)), // ㅑ
            '7' => j(Jamo::jung(0x1168)), // ㅖ
            '8' => j(Jamo::jung(0x1174)), // ㅢ
            '9' => j(Jamo::jung(0x116E)), // ㅜ
            '0' => j(Jamo::cho(0x110F)),  // ㅋ
            '-' => c('-'),
            '=' => c('='),

            'q' => j(Jamo::jong(0x11BA)), // ㅅ
            'w' => j(Jamo::jong(0x11AF)), // ㄹ
            'e' => j(Jamo::jung(0x1167)), // ㅕ
            'r' => j(Jamo::jung(0x1162)), // ㅐ
            't' => j(Jamo::jung(0x1165)), // ㅓ
            'y' => j(Jamo::cho(0x1105)),  // ㄹ
            'u' => j(Jamo::cho(0x1103)),  // ㄷ
            'i' => j(Jamo::cho(0x1106)),  // ㅁ
            'o' => j(Jamo::cho(0x110E)),  // ㅊ
            'p' => j(Jamo::cho(0x1111)),  // ㅍ
            '[' => c('['),
            ']' => c(']'),
            '\\' => c('\\'),

            'a' => j(Jamo::jong(0x11BC)), // ㅇ
            's' => j(Jamo::jong(0x11AB)), // ㄴ
            'd' => j(Jamo::jung(0x1175)), // ㅣ
            'f' => j(Jamo::jung(0x1161)), // ㅏ
            'g' => j(Jamo::jung(0x1173)), // ㅡ
            'h' => j(Jamo::cho(0x1102)),  // ㄴ
            'j' => j(Jamo::cho(0x110B)),  // ㅇ
            'k' => j(Jamo::cho(0x1100)),  // ㄱ
            'l' => j(Jamo::cho(0x110C)),  // ㅈ
            ';' => j(Jamo::cho(0x1107)),  // ㅂ
            '\'' => j(Jamo::cho(0x1110)), // ㅌ

            'z' => j(Jamo::jong(0x11B7)), // ㅁ
            'x' => j(Jamo::jong(0x11A8)), // ㄱ
            'c' => j(Jamo::jung(0x1166)), // ㅔ
            'v' => j(Jamo::jung(0x1169)), // ㅗ
            'b' => j(Jamo::jung(0x116E)), // ㅜ
            'n' => j(Jamo::cho(0x1109)),  // ㅅ
            'm' => j(Jamo::cho(0x1112)),  // ㅎ
            ',' => c(','),
            '.' => c('.'),
            '/' => j(Jamo::jung(0x1169)), // ㅗ

            '~' => c('~'),
            '!' => j(Jamo::jong(0x11BD)), // ㅈ
            '@' => c('@'),
            '#' => c('#'),
            '$' => c('$'),
            '%' => c('%'),
            '^' => c('^'),
            '&' => c('&'),
            '*' => c('*'),
            '(' => c('('),
            ')' => c(')'),
            '_' => c('_'),
            '+' => c('+'),

            'Q' => j(Jamo::jong(0x11C1)), // ㅍ
            'W' => j(Jamo::jong(0x11C0)), // ㅌ
            'E' => j(Jamo::jong(0x11BF)), // ㅋ
            'R' => j(Jamo::jung(0x1164)), // ㅒ
            'T' => c(';'),
            'Y' => c('<'),
            'U' => c('7'),
            'I' => c('8'),
            'O' => c('9'),
            'P' => c('>'),
            '{' => c('{'),
            '}' => c('}'),
            '|' => c('|'),

            'A' => j(Jamo::jong(0x11AE)), // ㄷ
            'S' => j(Jamo::jong(0x11AD)), // ㄶ
            'D' => j(Jamo::jong(0x11B0)), // ㄺ
            'F' => j(Jamo::jong(0x11A9)), // ㄲ
            'G' => c('/'),
            'H' => c('\''),
            'J' => c('4'),
            'K' => c('5'),
            'L' => c('6'),
            ':' => c(':'),
            '"' => c('"'),

            'Z' => j(Jamo::jong(0x11BE)), // ㅊ
            'X' => j(Jamo::jong(0x11B9)), // ㅄ
            'C' => j(Jamo::jong(0x11B1)), // ㄻ
            'V' => j(Jamo::jong(0x11B6)), // ㅀ
            'B' => c('!'),
            'N' => c('0'),
            'M' => c('1'),
            '<' => c('2'),
            '>' => c('3'),
            '?' => c('?'),
            ' ' => c(' '),
            _ => None,
        }
    }
}

/// 공병우 세벌식 최종 (1991). Unshifted letters and digits match 390.
/// Layout checked against libhangul's hangul_keyboard_table_3final.
pub mod final_layout {
    use super::{KeyAtom, KeyOutput, KeyboardLayout, c, j, layout390};
    use crate::hangul::Jamo;

    pub fn atom(key: char) -> KeyAtom {
        let korean = overrides(key).unwrap_or_else(|| layout390::atom(key).korean);
        KeyAtom { layout: KeyboardLayout::SebeolFinal, english: key, korean }
    }

    fn overrides(key: char) -> Option<KeyOutput> {
        match key {
            '!' => j(Jamo::jong(0x11A9)),
            '@' => j(Jamo::jong(0x11B0)),
            '#' => j(Jamo::jong(0x11BD)),
            '$' => j(Jamo::jong(0x11B5)),
            '%' => j(Jamo::jong(0x11B4)),
            '^' => c('='),
            '&' => c('“'),
            '*' => c('”'),
            '(' => c('\''),
            ')' => c('~'),
            '-' => c(')'),
            '=' => c('>'),
            '_' => c(';'),
            '`' => c('*'),
            '~' => c('※'),
            'Q' => j(Jamo::jong(0x11C1)),
            'W' => j(Jamo::jong(0x11C0)),
            'E' => j(Jamo::jong(0x11AC)),
            'R' => j(Jamo::jong(0x11B6)),
            'T' => j(Jamo::jong(0x11B3)),
            'Y' => c('5'),
            'U' => c('6'),
            'I' => c('7'),
            'O' => c('8'),
            'P' => c('9'),
            '[' => c('('),
            ']' => c('<'),
            '\\' => c(':'),
            '{' => c('%'),
            '}' => c('/'),
            '|' => c('\\'),
            'A' => j(Jamo::jong(0x11AE)),
            'S' => j(Jamo::jong(0x11AD)),
            'D' => j(Jamo::jong(0x11B2)),
            'F' => j(Jamo::jong(0x11B1)),
            'G' => j(Jamo::jung(0x1164)),
            'H' => c('0'),
            'J' => c('1'),
            'K' => c('2'),
            'L' => c('3'),
            ':' => c('4'),
            '"' => c('·'),
            'Z' => j(Jamo::jong(0x11BE)),
            'X' => j(Jamo::jong(0x11B9)),
            'C' => j(Jamo::jong(0x11BF)),
            'V' => j(Jamo::jong(0x11AA)),
            'B' => c('?'),
            'N' => c('-'),
            'M' => c('"'),
            '<' => c(','),
            '>' => c('.'),
            '?' => c('!'),
            _ => None,
        }
    }
}

/// Standard Korean two-set QWERTY layout used by the touch keyboard.
pub mod dubeol {
    use super::{KeyAtom, KeyOutput, KeyboardLayout};
    use crate::hangul::{Jamo, JamoKind};

    const LETTERS: &[u8; 26] = b"qwertyuiopasdfghjklzxcvbnm";
    const SCALARS: [u32; 26] = [
        0x1107, 0x110C, 0x1103, 0x1100, 0x1109, 0x116D, 0x1167, 0x1163, 0x1162, 0x1166, 0x1106, 0x1102, 0x110B, 0x1105,
        0x1112, 0x1169, 0x1165, 0x1161, 0x1175, 0x110F, 0x1110, 0x110E, 0x1111, 0x1172, 0x116E, 0x1173,
    ];
    /// Initial → final for the consonants that can close a syllable.
    const FINALS: [(u32, u32); 16] = [
        (0x1100, 0x11A8),
        (0x1101, 0x11A9),
        (0x1102, 0x11AB),
        (0x1103, 0x11AE),
        (0x1105, 0x11AF),
        (0x1106, 0x11B7),
        (0x1107, 0x11B8),
        (0x1109, 0x11BA),
        (0x110A, 0x11BB),
        (0x110B, 0x11BC),
        (0x110C, 0x11BD),
        (0x110E, 0x11BE),
        (0x110F, 0x11BF),
        (0x1110, 0x11C0),
        (0x1111, 0x11C1),
        (0x1112, 0x11C2),
    ];

    pub fn atom(key: char) -> KeyAtom {
        let mut lower = key.to_lowercase();
        let single = match (lower.next(), lower.next()) {
            (Some(first), None) => Some(first),
            _ => None,
        };
        let index = single.and_then(|lower| {
            u8::try_from(lower).ok().and_then(|byte| LETTERS.iter().position(|&letter| letter == byte))
        });
        let Some(index) = index else {
            return KeyAtom { layout: KeyboardLayout::Dubeol, english: key, korean: KeyOutput::Character(key) };
        };
        let scalar = match key {
            'Q' => 0x1108,
            'W' => 0x110D,
            'E' => 0x1104,
            'R' => 0x1101,
            'T' => 0x110A,
            'O' => 0x1164,
            'P' => 0x1168,
            _ => SCALARS[index],
        };
        let kind = if scalar >= 0x1161 { JamoKind::Jungseong } else { JamoKind::Choseong };
        KeyAtom { layout: KeyboardLayout::Dubeol, english: key, korean: KeyOutput::Jamo(Jamo::new(scalar, kind)) }
    }

    pub fn final_for_initial(jamo: Jamo) -> Option<Jamo> {
        FINALS.iter().find(|(initial, _)| *initial == jamo.scalar).map(|&(_, last)| Jamo::jong(last))
    }

    pub fn initial_for_final(jamo: Jamo) -> Option<Jamo> {
        FINALS.iter().find(|(_, last)| *last == jamo.scalar).map(|&(initial, _)| Jamo::cho(initial))
    }
}
