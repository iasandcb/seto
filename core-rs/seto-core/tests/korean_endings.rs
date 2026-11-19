//! Regression tests for the Swift ending fixes:
//! 하기/하다/하면/해서/하자 and nominal 기 (PR #19),
//! colloquial particle 두 (PR #20),
//! and short 하다 endings 한/할/함 (PR #22).

mod common;

use std::sync::{Arc, OnceLock};

use seto_core::{
    KeyboardLayout, Language, Lexicon, Session, SessionOptions, TypoCorrector, korean_endings, korean_verb_endings,
};

fn lexicon() -> Arc<Lexicon> {
    static LEXICON: OnceLock<Arc<Lexicon>> = OnceLock::new();
    LEXICON.get_or_init(|| Arc::new(Lexicon::load(&common::resources()).expect("Resources lexicon"))).clone()
}

fn type_with(lexicon: Arc<Lexicon>, layout: KeyboardLayout, keys: &str) -> String {
    let mut session = Session::with_options(lexicon, SessionOptions { layout, ..SessionOptions::default() });
    for key in keys.chars() {
        session.input(layout.atom(key));
    }
    session.document()
}

fn type_word(layout: KeyboardLayout, keys: &str) -> String {
    type_with(lexicon(), layout, keys)
}

fn keyboard_lexicon() -> Arc<Lexicon> {
    static LEXICON: OnceLock<Arc<Lexicon>> = OnceLock::new();
    LEXICON
        .get_or_init(|| {
            Arc::new(
                Lexicon::load_for_keyboard_files(
                    &common::keyboard_resources().join("keyboard-english.txt"),
                    &common::keyboard_resources().join("keyboard-korean-valid.txt"),
                    &common::resources().join("korean-words.txt"),
                )
                .expect("keyboard lexicon"),
            )
        })
        .clone()
}

#[test]
fn hada_forms_and_nominal_gi_are_not_typo_corrections() {
    let lexicon = lexicon();
    assert!(lexicon.is_korean_word("말") || lexicon.is_valid_korean("말"));
    assert!(lexicon.is_korean_word("공부") || lexicon.is_valid_korean("공부"));
    for ending in ["하기", "하다", "하면", "해서", "하자", "하고", "하는"] {
        assert_eq!(korean_endings::split(&format!("공부{ending}")), Some(("공부", ending)));
    }
    assert!(korean_verb_endings::is_inflected("먹기", |word| word == "먹"));
    assert!(korean_verb_endings::is_inflected("가기", |word| word == "가다"));

    for layout in [KeyboardLayout::Sebeol390, KeyboardLayout::Dubeol] {
        for word in ["말하기", "공부하기", "말하다", "공부하다", "말하면", "공부해서", "공부하자"]
        {
            let keys = TypoCorrector::keystrokes(word, layout).unwrap_or_else(|| panic!("keys for {word}"));
            let atoms: Vec<_> = keys.chars().map(|key| layout.atom(key)).collect();
            assert_eq!(
                TypoCorrector::correction(word, &atoms, Language::Korean, &lexicon, None),
                None,
                "{layout:?}: {word} must not be rewritten (말하기 must not become 말하고)"
            );
            for boundary in [" ", ".", "\n"] {
                let typed = type_word(layout, &format!("{keys}{boundary}"));
                assert_eq!(typed, format!("{word}{boundary}"), "{layout:?}: {word}");
            }
        }
    }
}

#[test]
fn short_hada_endings_stay_typed() {
    let lexicon = lexicon();
    for stem in ["못", "안", "공부"] {
        assert!(lexicon.is_korean_word(stem) || lexicon.is_valid_korean(stem), "{stem}");
        for ending in ["한", "할", "함", "했", "해"] {
            assert_eq!(korean_endings::split(&format!("{stem}{ending}")), Some((stem, ending)));
        }
    }
    assert!(korean_endings::contains("만"));

    for layout in [KeyboardLayout::Sebeol390, KeyboardLayout::Dubeol] {
        for stem in ["못", "안", "공부"] {
            for ending in ["한", "할", "함", "했", "해"] {
                let word = format!("{stem}{ending}");
                let keys = TypoCorrector::keystrokes(&word, layout).unwrap_or_else(|| panic!("keys for {word}"));
                let atoms: Vec<_> = keys.chars().map(|key| layout.atom(key)).collect();
                assert_eq!(
                    TypoCorrector::correction(&word, &atoms, Language::Korean, &lexicon, None),
                    None,
                    "{layout:?}: {word} must stay (못한 must not become 못만)"
                );
                for boundary in [" ", ".", "\n"] {
                    let typed = type_word(layout, &format!("{keys}{boundary}"));
                    assert_eq!(typed, format!("{word}{boundary}"), "{layout:?}: {word} boundary {boundary:?}");
                }
            }
        }
    }
}

#[test]
fn colloquial_du_stays_and_capitalized_english_is_not_read_as_du() {
    let lexicon = lexicon();
    for stem in ["너", "나", "저", "우리"] {
        assert!(lexicon.is_korean_word(stem) || lexicon.is_valid_korean(stem), "{stem}");
        for ending in ["두", "도"] {
            assert_eq!(korean_endings::split(&format!("{stem}{ending}")), Some((stem, ending)));
        }
    }

    for layout in [KeyboardLayout::Sebeol390, KeyboardLayout::Dubeol] {
        for word in ["너두", "나두", "저두", "우리두"] {
            let keys = TypoCorrector::keystrokes(word, layout).unwrap_or_else(|| panic!("keys for {word}"));
            let atoms: Vec<_> = keys.chars().map(|key| layout.atom(key)).collect();
            assert_eq!(
                TypoCorrector::correction(word, &atoms, Language::Korean, &lexicon, None),
                None,
                "{layout:?}: {word}"
            );
            for boundary in [" ", ".", "\n"] {
                let typed = type_word(layout, &format!("{keys}{boundary}"));
                assert_eq!(typed, format!("{word}{boundary}"), "{layout:?}: {word} boundary {boundary:?}");
            }
        }
    }

    // K is 5 and ub is 두, but Kub is the capitalized English prefix of Kubernetes.
    assert_eq!(type_word(KeyboardLayout::Sebeol390, "Kubernetes"), "Kubernetes");
    assert_eq!(type_word(KeyboardLayout::Sebeol390, "Kub"), "Kub");
    // A standard particle still outranks that prefix: Ku/ is 5도.
    assert_eq!(type_word(KeyboardLayout::Sebeol390, "Ku/ "), "5도 ");
    // 8두 is not an English word or prefix, so the colloquial particle stays.
    assert_eq!(type_word(KeyboardLayout::Sebeol390, "Iub "), "8두 ");
}

/// 몇시 is one choseong away from 몇+이 (ㅅ/ㅇ), and 몇살 from 몇+할.
/// Other 시 compounds (한시, 두시) and 몇개·몇번 were already in the validity
/// list, so only the missing 몇-compounds were rewritten.
fn myeot_compounds_stay_typed(lexicon: Arc<Lexicon>) {
    for word in ["몇시", "몇시간", "몇분", "몇개", "몇명", "몇번", "모시", "몇살", "몇년", "몇일", "몇세"]
    {
        assert!(lexicon.is_korean_word(word) || lexicon.is_valid_korean(word), "{word}");
    }
    // 몇시에 is the new headword plus the particle 에, not a separate entry.
    assert_eq!(korean_endings::split("몇시에"), Some(("몇시", "에")));
    assert!(!lexicon.is_korean_word("몇이") && !lexicon.is_valid_korean("몇이"));

    for layout in [KeyboardLayout::Sebeol390, KeyboardLayout::Dubeol, KeyboardLayout::SebeolFinal] {
        for word in
            ["몇시", "몇시에", "몇시간", "몇분", "몇개", "몇명", "몇번", "모시", "몇살", "몇년", "몇일", "몇세", "몇이"]
        {
            let keys = TypoCorrector::keystrokes(word, layout).unwrap_or_else(|| panic!("keys for {word}"));
            let atoms: Vec<_> = keys.chars().map(|key| layout.atom(key)).collect();
            assert_eq!(
                TypoCorrector::correction(word, &atoms, Language::Korean, &lexicon, None),
                None,
                "{layout:?}: {word} must stay (몇시 must not become 몇이)"
            );
            for boundary in [" ", ".", "\n"] {
                let typed = type_with(lexicon.clone(), layout, &format!("{keys}{boundary}"));
                assert_eq!(typed, format!("{word}{boundary}"), "{layout:?}: {word} boundary {boundary:?}");
            }
        }
    }
}

#[test]
fn desktop_lexicon_keeps_myeot_compounds() {
    myeot_compounds_stay_typed(lexicon());
}

#[test]
fn keyboard_lexicon_keeps_myeot_compounds() {
    myeot_compounds_stay_typed(keyboard_lexicon());
}

#[test]
fn unknown_one_key_korean_typos_still_correct() {
    let lexicon = lexicon();
    for layout in [KeyboardLayout::Sebeol390, KeyboardLayout::Dubeol] {
        let keys = TypoCorrector::keystrokes("한굴", layout).expect("keys for 한굴");
        let atoms: Vec<_> = keys.chars().map(|key| layout.atom(key)).collect();
        assert_eq!(
            TypoCorrector::correction("한굴", &atoms, Language::Korean, &lexicon, None),
            Some("한글".to_owned())
        );
        assert_eq!(type_word(layout, &format!("{keys} ")), "한글 ");
    }
}
