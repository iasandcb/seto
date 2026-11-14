//! Mirrors Tests/Sebeol390CoreTests/ComposerTests.swift.

mod common;

use common::{atoms390, compose390};
use seto_core::{CompositionPiece, Jamo, compose, jamo_sequence, preserves_boundary};

#[test]
fn language_boundaries_preserve_hangul_units() {
    for (keys, boundary) in [
        ("kf", 1),    // ㄱ | ㅏ
        ("kkf", 1),   // ㄱ | ㄱㅏ (ㄲ)
        ("kvf", 2),   // 고 | ㅏ (과)
        ("kfx", 2),   // 가 | ㄱ (각)
        ("kfxq", 3),  // 각 | ㅅ (갃)
        ("kvif3", 4), // 고마 | ㅂ (고맙)
    ] {
        assert!(!preserves_boundary(boundary, &atoms390(keys)), "{keys} at {boundary}");
    }
    for (keys, boundary) in [
        ("kfhf", 2),      // 가 | 나
        ("kvif3", 2),     // 고 | 맙
        ("ktx hgs", 3),   // 걱 | space
        ("deploymr2", 6), // deploy | 했
        ("apiyhw", 3),    // api | 를
    ] {
        assert!(preserves_boundary(boundary, &atoms390(keys)), "{keys} at {boundary}");
    }
}

#[test]
fn common_words_compose() {
    for (keys, word) in [
        ("mfskgw", "한글"),
        ("jfsheamfncj4", "안녕하세요"),
        ("nc;twndx", "세벌식"),
        ("mr2ng3hduf", "했습니다"),
        ("lv1jfj4", "좋아요"),
        ("jd2uf", "있다"),
        ("mr2hgsuc", "했는데"),
        ("mrnt", "해서"),
    ] {
        assert_eq!(compose390(keys), word, "{keys}");
    }
}

#[test]
fn compounds_compose() {
    for (keys, word) in [
        ("kvf", "과"),
        ("j8", "의"),
        ("jgd", "의"),
        ("kkf", "까"),
        ("kf3q", "값"),
        ("kfX", "값"),
        ("kfxq", "갃"),
        ("kfF", "갂"),
        ("hfwq", "낤"),
        ("hfW", "낱"),
    ] {
        assert_eq!(compose390(keys), word, "{keys}");
    }
}

#[test]
fn vowel_order_is_not_reversed() {
    let text = compose390("fk");
    assert_ne!(text, "과");
    assert!(text.contains('ㅏ'));
}

#[test]
fn symbol_breaks_syllable() {
    assert_eq!(compose390("kf."), "가.");
}

#[test]
fn shorter_prefix_drops_last_jamo() {
    assert_eq!(compose390("kk"), "ㄲ");
    assert_eq!(compose390("k"), "ㄱ");
}

#[test]
fn pieces_and_units() {
    let composition = compose(&atoms390("kfM ux"));
    assert_eq!(composition.text, "가1 ㄷㄱ");
    assert_eq!(
        composition.pieces,
        [
            CompositionPiece::Syllable,
            CompositionPiece::Digit,
            CompositionPiece::BareChoseong,
            CompositionPiece::BareJongseong,
        ]
    );
    assert_eq!(composition.syllable_count(), 1);
    assert_eq!(jamo_sequence(&atoms390("kkfx")), Some(vec![Jamo::cho(0x1101), Jamo::jung(0x1161), Jamo::jong(0x11A8)]));
    assert_eq!(jamo_sequence(&atoms390("kf.")), None);
    // Orphan vowel after a syllable stays a separate bare vowel (수ㅗ).
    assert_eq!(compose390("nbv"), "수ㅗ");
    // Digit-key Hangul: 공유.
    assert_eq!(compose390("kvaj5"), "공유");
    assert_eq!(compose390("uvr"), "돼");
}
