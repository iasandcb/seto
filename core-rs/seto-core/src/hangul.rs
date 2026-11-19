//! Port of `Sources/SetoCore/Hangul.swift`.

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum JamoKind {
    Choseong,
    Jungseong,
    Jongseong,
}

/// A conjoining jamo (U+1100 block) tagged with its syllable position.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Jamo {
    pub scalar: u32,
    pub kind: JamoKind,
}

impl Jamo {
    pub const fn new(scalar: u32, kind: JamoKind) -> Self {
        Jamo { scalar, kind }
    }

    pub const fn cho(scalar: u32) -> Self {
        Jamo::new(scalar, JamoKind::Choseong)
    }

    pub const fn jung(scalar: u32) -> Self {
        Jamo::new(scalar, JamoKind::Jungseong)
    }

    pub const fn jong(scalar: u32) -> Self {
        Jamo::new(scalar, JamoKind::Jongseong)
    }

    /// Compatibility jamo (U+3130 block) so an unfinished syllable is visible.
    /// The compatibility block inserts ㄳ·ㄵ·ㄶ·ㄺ… and ㄸ·ㅃ·ㅉ, so neither
    /// choseong nor jongseong is a constant offset from U+3131.
    pub fn compat(&self) -> char {
        let value = match self.kind {
            JamoKind::Choseong => cho_compat(self.scalar).unwrap_or(0x3131),
            JamoKind::Jungseong => 0x314F + self.scalar.wrapping_sub(0x1161),
            JamoKind::Jongseong => jong_compat(self.scalar).unwrap_or(0x3131),
        };
        char::from_u32(value).unwrap_or('\u{3131}')
    }
}

fn cho_compat(scalar: u32) -> Option<u32> {
    const TABLE: [u32; 19] = [
        0x3131, 0x3132, 0x3134, 0x3137, 0x3138, 0x3139, 0x3141, 0x3142, 0x3143, 0x3145, 0x3146, 0x3147, 0x3148, 0x3149,
        0x314A, 0x314B, 0x314C, 0x314D, 0x314E,
    ];
    let index = scalar.checked_sub(0x1100)? as usize;
    TABLE.get(index).copied()
}

fn jong_compat(scalar: u32) -> Option<u32> {
    const TABLE: [u32; 27] = [
        0x3131, 0x3132, 0x3133, 0x3134, 0x3135, 0x3136, 0x3137, 0x3139, 0x313A, 0x313B, 0x313C, 0x313D, 0x313E, 0x313F,
        0x3140, 0x3141, 0x3142, 0x3144, 0x3145, 0x3146, 0x3147, 0x3148, 0x314A, 0x314B, 0x314C, 0x314D, 0x314E,
    ];
    let index = scalar.checked_sub(0x11A8)? as usize;
    TABLE.get(index).copied()
}

/// Same-class merges: (first, second, result).
const MERGES: [(u32, u32, u32); 25] = [
    // Choseong doubles.
    (0x1100, 0x1100, 0x1101), // ㄱㄱ=ㄲ
    (0x1103, 0x1103, 0x1104), // ㄷㄷ=ㄸ
    (0x1107, 0x1107, 0x1108), // ㅂㅂ=ㅃ
    (0x1109, 0x1109, 0x110A), // ㅅㅅ=ㅆ
    (0x110C, 0x110C, 0x110D), // ㅈㅈ=ㅉ
    // Compound vowels.
    (0x1169, 0x1161, 0x116A), // ㅗㅏ=ㅘ
    (0x1169, 0x1162, 0x116B), // ㅗㅐ=ㅙ
    (0x1169, 0x1175, 0x116C), // ㅗㅣ=ㅚ
    (0x116E, 0x1165, 0x116F), // ㅜㅓ=ㅝ
    (0x116E, 0x1166, 0x1170), // ㅜㅔ=ㅞ
    (0x116E, 0x1175, 0x1171), // ㅜㅣ=ㅟ
    (0x1173, 0x1175, 0x1174), // ㅡㅣ=ㅢ
    // Compound batchim.
    (0x11A8, 0x11A8, 0x11A9), // ㄱㄱ=ㄲ
    (0x11A8, 0x11BA, 0x11AA), // ㄱㅅ=ㄳ
    (0x11AB, 0x11BD, 0x11AC), // ㄴㅈ=ㄵ
    (0x11AB, 0x11C2, 0x11AD), // ㄴㅎ=ㄶ
    (0x11AF, 0x11A8, 0x11B0), // ㄹㄱ=ㄺ
    (0x11AF, 0x11B7, 0x11B1), // ㄹㅁ=ㄻ
    (0x11AF, 0x11B8, 0x11B2), // ㄹㅂ=ㄼ
    (0x11AF, 0x11BA, 0x11B3), // ㄹㅅ=ㄽ
    (0x11AF, 0x11C0, 0x11B4), // ㄹㅌ=ㄾ
    (0x11AF, 0x11C1, 0x11B5), // ㄹㅍ=ㄿ
    (0x11AF, 0x11C2, 0x11B6), // ㄹㅎ=ㅀ
    (0x11B8, 0x11BA, 0x11B9), // ㅂㅅ=ㅄ
    (0x11BA, 0x11BA, 0x11BB), // ㅅㅅ=ㅆ
];

/// Modern syllable composition. Same-class pairs only (세벌식 does not turn
/// two choseong into a jongseong).
pub fn merge(first: Jamo, second: Jamo) -> Option<Jamo> {
    if first.kind != second.kind {
        return None;
    }
    MERGES
        .iter()
        .find(|(a, b, _)| *a == first.scalar && *b == second.scalar)
        .map(|&(_, _, result)| Jamo::new(result, first.kind))
}

/// The two same-class jamo that merge into `compound` (ㅘ is ㅗ then ㅏ).
/// Every compound has exactly one such pair.
pub fn merge_parts(compound: Jamo) -> Option<(Jamo, Jamo)> {
    MERGES
        .iter()
        .find(|(_, _, result)| *result == compound.scalar)
        .map(|&(first, second, _)| (Jamo::new(first, compound.kind), Jamo::new(second, compound.kind)))
        .filter(|&(first, second)| merge(first, second) == Some(compound))
}

/// Precomposed syllable U+AC00 + (cho * 21 + jung) * 28 + jong.
pub fn syllable(cho: u32, jung: u32, jong: Option<u32>) -> char {
    let ci = cho - 0x1100;
    let vi = jung - 0x1161;
    let ti = jong.map_or(0, |value| value - 0x11A8 + 1);
    let code = 0xAC00 + (ci * 21 + vi) * 28 + ti;
    char::from_u32(code).expect("modern syllable")
}

/// True when one jamo is a single merge step away from the other (ㅗ and ㅘ,
/// ㄱ and ㄲ). Used by typo distance, not by composition.
pub fn differs_by_one_component(first: Jamo, second: Jamo) -> bool {
    if first.kind != second.kind || first.scalar == second.scalar {
        return false;
    }
    let (a, b) = (first.scalar, second.scalar);
    MERGES.iter().any(|&(left, right, value)| {
        ((a == left || a == right) && b == value) || (a == value && (b == left || b == right))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compat_covers_every_modern_jamo() {
        assert_eq!(Jamo::cho(0x1100).compat(), 'ㄱ');
        assert_eq!(Jamo::cho(0x1104).compat(), 'ㄸ');
        assert_eq!(Jamo::cho(0x1112).compat(), 'ㅎ');
        assert_eq!(Jamo::jung(0x1161).compat(), 'ㅏ');
        assert_eq!(Jamo::jung(0x1174).compat(), 'ㅢ');
        assert_eq!(Jamo::jung(0x1175).compat(), 'ㅣ');
        assert_eq!(Jamo::jong(0x11AA).compat(), 'ㄳ');
        assert_eq!(Jamo::jong(0x11B9).compat(), 'ㅄ');
        assert_eq!(Jamo::jong(0x11C2).compat(), 'ㅎ');
        for scalar in 0x1100..=0x1112 {
            assert!(('\u{3131}'..='\u{314E}').contains(&Jamo::cho(scalar).compat()));
        }
        for scalar in 0x11A8..=0x11C2 {
            assert!(('\u{3131}'..='\u{314E}').contains(&Jamo::jong(scalar).compat()));
        }
    }

    #[test]
    fn merges_are_same_class_only() {
        assert_eq!(merge(Jamo::cho(0x1100), Jamo::cho(0x1100)), Some(Jamo::cho(0x1101)));
        assert_eq!(merge(Jamo::jung(0x1169), Jamo::jung(0x1161)), Some(Jamo::jung(0x116A)));
        assert_eq!(merge(Jamo::jong(0x11A8), Jamo::jong(0x11BA)), Some(Jamo::jong(0x11AA)));
        assert_eq!(merge(Jamo::jong(0x11A8), Jamo::cho(0x1100)), None);
        // Vowel order is not reversed: ㅏㅗ is not ㅘ.
        assert_eq!(merge(Jamo::jung(0x1161), Jamo::jung(0x1169)), None);
    }

    #[test]
    fn merge_parts_invert_merge() {
        assert_eq!(merge_parts(Jamo::jung(0x116A)), Some((Jamo::jung(0x1169), Jamo::jung(0x1161))));
        assert_eq!(merge_parts(Jamo::jong(0x11B0)), Some((Jamo::jong(0x11AF), Jamo::jong(0x11A8))));
        assert_eq!(merge_parts(Jamo::cho(0x1100)), None);
        for (first, second, result) in MERGES {
            let kind = if result < 0x1161 {
                JamoKind::Choseong
            } else if result < 0x11A8 {
                JamoKind::Jungseong
            } else {
                JamoKind::Jongseong
            };
            let compound = Jamo::new(result, kind);
            assert_eq!(merge_parts(compound), Some((Jamo::new(first, kind), Jamo::new(second, kind))));
            assert_eq!(MERGES.iter().filter(|(_, _, other)| *other == result).count(), 1);
        }
    }

    #[test]
    fn syllables() {
        assert_eq!(syllable(0x1100, 0x1161, None), '가');
        assert_eq!(syllable(0x1112, 0x1161, Some(0x11AB)), '한');
        assert_eq!(syllable(0x1112, 0x1175, Some(0x11C2)), '힣');
    }

    #[test]
    fn one_component_differences() {
        assert!(differs_by_one_component(Jamo::jung(0x1169), Jamo::jung(0x116A)));
        assert!(differs_by_one_component(Jamo::jung(0x116A), Jamo::jung(0x1161)));
        assert!(differs_by_one_component(Jamo::cho(0x1100), Jamo::cho(0x1101)));
        assert!(!differs_by_one_component(Jamo::cho(0x1100), Jamo::cho(0x1100)));
        assert!(!differs_by_one_component(Jamo::jung(0x1161), Jamo::jung(0x1169)));
        assert!(!differs_by_one_component(Jamo::cho(0x1100), Jamo::jong(0x11A9)));
    }
}
