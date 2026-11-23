//! Mirrors Tests/Sebeol390CoreTests/KeyboardLayoutTests.swift. Assertions
//! that go through Session or TypoCorrector are recorded in
//! testdata/session-golden.json and wait for those ports.

mod common;

use std::sync::Arc;

use common::{atoms, compose_final};
use seto_core::{FieldEdit, KeyOutput, KeyboardLayout, Lexicon, Session, SessionOptions, compose, final_layout};

#[test]
fn layout_metadata() {
    assert_eq!(KeyboardLayout::ALL, [KeyboardLayout::Sebeol390, KeyboardLayout::Dubeol, KeyboardLayout::SebeolFinal]);
    assert_eq!(KeyboardLayout::Sebeol390.title(), "세벌식 390");
    assert_eq!(KeyboardLayout::Dubeol.title(), "두벌식");
    assert_eq!(KeyboardLayout::SebeolFinal.title(), "세벌식 최종");
    for layout in KeyboardLayout::ALL {
        assert_eq!(KeyboardLayout::from_raw_value(layout.raw_value()), Some(layout));
        assert_eq!(serde_json::to_string(&layout).unwrap(), format!("\"{}\"", layout.raw_value()));
    }
    assert_eq!(KeyboardLayout::default(), KeyboardLayout::Sebeol390);
}

#[test]
fn selected_layout_composes() {
    // selectedLayoutComposesThroughSession: same text in every layout.
    for (layout, keys) in [
        (KeyboardLayout::Sebeol390, "mfs kgw"),
        (KeyboardLayout::SebeolFinal, "mfs kgw"),
        (KeyboardLayout::Dubeol, "gks rmf"),
    ] {
        assert_eq!(compose(&atoms(layout, keys)).text, "한 글", "{layout:?}");
        let shorter: String = keys.chars().take(keys.chars().count() - 1).collect();
        assert_eq!(compose(&atoms(layout, &shorter)).text, "한 그", "{layout:?}");
    }
}

#[test]
fn final_shifted_jamo_and_symbols() {
    for (keys, expected) in [
        ("kf!", "갂"),
        ("kf@", "갉"),
        ("kf#", "갖"),
        ("kf$", "갎"),
        ("kf%", "갍"),
        ("kfE", "갅"),
        ("kfD", "갋"),
        ("kfF", "갊"),
        ("kfR", "갏"),
        ("kfT", "갌"),
        ("kfV", "갃"),
        ("kG", "걔"),
        ("kfC", "갘"),
    ] {
        assert_eq!(compose_final(keys), expected, "{keys}");
    }
    for (key, output) in [
        ('H', '0'),
        ('J', '1'),
        ('K', '2'),
        ('L', '3'),
        (':', '4'),
        ('Y', '5'),
        ('U', '6'),
        ('I', '7'),
        ('O', '8'),
        ('P', '9'),
        ('B', '?'),
        ('N', '-'),
        ('?', '!'),
        ('~', '※'),
        ('"', '·'),
        ('[', '('),
        (']', '<'),
        ('=', '>'),
        ('-', ')'),
        ('<', ','),
        ('>', '.'),
    ] {
        assert_eq!(final_layout::atom(key).korean, KeyOutput::Character(output), "{key}");
    }
}

#[test]
fn final_moved_punctuation_and_digits() {
    // finalMovedPunctuationAndDigitsInSession, through the composer.
    assert_eq!(compose_final("mfsB HJKL:YUIOP"), "한? 0123456789");
}

#[test]
fn selected_layout_typo_composition() {
    // selectedLayoutTypoCorrection: the typo each layout composes.
    for layout in KeyboardLayout::ALL {
        let keys = if layout == KeyboardLayout::Dubeol { "gksrnf" } else { "mfskbw" };
        assert_eq!(compose(&atoms(layout, keys)).text, "한굴", "{}", layout.title());
    }
    assert_eq!(compose_final("if!uf"), "맊다");
}

#[test]
fn final_single_key_compound_final() {
    // finalSingleKeyCompoundFinalDeletion: 맑, then one key less.
    assert_eq!(compose_final("if@"), "맑");
    assert_eq!(compose_final("if"), "마");
}

#[test]
fn inflected_dubeol_verbs_compose() {
    // inflectedVerbsStayUncorrectedOnDubeol: what the keys compose to.
    for (word, keys) in [
        ("오고", "dhrh"),
        ("오면", "dhaus"),
        ("와서", "dhktj"),
        ("왔다", "dhkTek"),
        ("가고", "rkrh"),
        ("주고", "wnrh"),
        ("주면", "wnaus"),
        ("하면", "gkaus"),
        ("먹고", "ajrrh"),
        ("먹었다", "ajrdjTek"),
        ("쓰고", "Tmrh"),
        ("두고", "enrh"),
    ] {
        assert_eq!(compose(&atoms(KeyboardLayout::Dubeol, keys)).text, word, "{keys}");
    }
}

#[test]
fn set_layout_commits_the_open_word_and_keeps_explicit_atoms() {
    let lexicon = Arc::new(Lexicon::new(&[] as &[&str], &[]));
    let mut session = Session::with_options(
        lexicon,
        SessionOptions { auto_switch: false, layout: KeyboardLayout::Sebeol390, ..SessionOptions::default() },
    );
    session.input_char('k');
    session.input_char('f');
    assert_eq!(session.preedit(), "가");
    assert_eq!(session.layout(), KeyboardLayout::Sebeol390);

    let unchanged = session.set_layout(KeyboardLayout::Sebeol390);
    assert_eq!(unchanged.field, FieldEdit::None);
    assert_eq!(session.preedit(), "가");

    let switched = session.set_layout(KeyboardLayout::Dubeol);
    assert!(matches!(switched.field, FieldEdit::Unmark { .. }));
    assert_eq!(session.preedit(), "");
    assert_eq!(session.document(), "가");
    assert_eq!(session.layout(), KeyboardLayout::Dubeol);

    // Hardware keys follow the session layout. 'r' is ㄱ on 두벌식 and ㅐ on 390.
    session.input_char('r');
    assert_eq!(session.preedit(), "ㄱ");

    // A touch-keyboard atom keeps its own layout on a 390 session.
    let mut touch = Session::new(Arc::new(Lexicon::new(&[] as &[&str], &[])));
    touch.auto_switch = false;
    touch.input(KeyboardLayout::Dubeol.atom('r'));
    assert_eq!(touch.preedit(), "ㄱ");
    touch.input_char('f');
    assert_eq!(touch.document(), "가");
}
