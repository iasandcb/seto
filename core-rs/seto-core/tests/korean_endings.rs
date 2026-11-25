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

/// `샷에` is `n6qjc` on 390 (and `titdp` on 두벌식). `셋에` differs by ㅑ/ㅔ,
/// and those keys do not touch, so the word boundary must not "correct" it.
/// Windows and macOS feed the same QWERTY characters; the rewrite was the
/// shared one-key corrector, which used to accept any single key change.
#[test]
fn syas_e_is_not_rewritten_as_ses_e() {
    let lexicon = lexicon();
    for layout in [KeyboardLayout::Sebeol390, KeyboardLayout::Dubeol, KeyboardLayout::SebeolFinal] {
        let keys = TypoCorrector::keystrokes("샷에", layout).unwrap_or_else(|| panic!("keys for 샷에 {layout:?}"));
        let atoms: Vec<_> = keys.chars().map(|key| layout.atom(key)).collect();
        assert_eq!(
            TypoCorrector::correction("샷에", &atoms, Language::Korean, &lexicon, None),
            None,
            "{layout:?} keys {keys}"
        );
        // 두벌식 `tit` is an English word, so that layout keeps a Latin prefix.
        // 390 and 최종 compose the syllables directly.
        if layout != KeyboardLayout::Dubeol {
            let open = type_with(lexicon.clone(), layout, &keys);
            assert_eq!(open, "샷에", "{layout:?}");
            for boundary in [" ", ".", "\n"] {
                let typed = type_with(lexicon.clone(), layout, &format!("{keys}{boundary}"));
                assert_eq!(typed, format!("샷에{boundary}"), "{layout:?} {boundary:?}");
            }
        }
    }
}

/// ㄲ and ㄺ sit on neighboring shifted keys (`!`/`@` on 최종, `F`/`D` on 390).
#[test]
fn adjacent_shifted_batchim_still_corrects() {
    let lexicon = Arc::new(Lexicon::new(&[], &["맑다"]));
    for (layout, keys) in [(KeyboardLayout::SebeolFinal, "if!uf"), (KeyboardLayout::Sebeol390, "ifFuf")] {
        let atoms: Vec<_> = keys.chars().map(|key| layout.atom(key)).collect();
        assert_eq!(
            TypoCorrector::correction("맊다", &atoms, Language::Korean, &lexicon, None),
            Some("맑다".to_owned()),
            "{layout:?}"
        );
    }
}

/// `거라는` is 거 + quotative 라는. It is not in the validity list. On 390
/// and 최종, ㄹ is `y` and ㄴ is `h`, and those keys share an edge, so the
/// finished word was rewritten as 거나 + 는. Composition itself is 거라는
/// the whole time; the change happens at the word boundary.
///
/// The Android touch keyboard sends 두벌식 atoms (`f` is ㄹ, `s` is ㄴ).
/// Those keys do not share an edge, so the on-screen keyboard already kept
/// 거라는. Android hardware defaults to 390, which hit the corrector.
#[test]
fn quotative_raneun_is_not_rewritten_as_geoneun() {
    for lexicon in [lexicon(), keyboard_lexicon()] {
        assert!(lexicon.is_valid_korean("거"), "거");
        assert!(lexicon.is_korean_word("거나") || lexicon.is_valid_korean("거나"));
        assert!(!lexicon.is_korean_word("거라는") && !lexicon.is_valid_korean("거라는"));
        assert!(lexicon.is_korean_word("뭐") || lexicon.is_valid_korean("뭐"));
        assert!(lexicon.is_korean_word("사람") || lexicon.is_valid_korean("사람"));
        for layout in [KeyboardLayout::Sebeol390, KeyboardLayout::SebeolFinal, KeyboardLayout::Dubeol] {
            for word in ["거라는", "뭐라는", "사람이라는"] {
                let keys = TypoCorrector::keystrokes(word, layout).unwrap_or_else(|| panic!("keys for {word}"));
                let atoms: Vec<_> = keys.chars().map(|key| layout.atom(key)).collect();
                assert_eq!(
                    TypoCorrector::correction(word, &atoms, Language::Korean, &lexicon, None),
                    None,
                    "{layout:?}: {word} keys {keys}"
                );
                let open = type_with(lexicon.clone(), layout, &keys);
                assert_eq!(open, word, "{layout:?}: open {word}");
                for boundary in [" ", ".", "\n"] {
                    let typed = type_with(lexicon.clone(), layout, &format!("{keys}{boundary}"));
                    assert_eq!(typed, format!("{word}{boundary}"), "{layout:?}: {word} {boundary:?}");
                }
            }
            // 거나는 stays the word it is. The exemption must not rewrite it back.
            let neighbor = TypoCorrector::keystrokes("거나는", layout).unwrap();
            let atoms: Vec<_> = neighbor.chars().map(|key| layout.atom(key)).collect();
            assert_eq!(
                TypoCorrector::correction("거나는", &atoms, Language::Korean, &lexicon, None),
                None,
                "{layout:?}"
            );
        }
    }
}

/// ㄹ/ㄴ are still an adjacent slip when the typed word is not noun + 라는.
/// 가라 → 가나 on 390 (`y`/`h`). 두벌식 `f`/`s` are not adjacent, so that
/// layout does not call the pair a slip.
#[test]
fn adjacent_rieul_nieun_still_corrects_when_not_quotative() {
    let lexicon = Arc::new(Lexicon::new(&[], &["가나"]));
    for layout in [KeyboardLayout::Sebeol390, KeyboardLayout::SebeolFinal] {
        let keys = TypoCorrector::keystrokes("가라", layout).expect("keys for 가라");
        let atoms: Vec<_> = keys.chars().map(|key| layout.atom(key)).collect();
        assert_eq!(
            TypoCorrector::correction("가라", &atoms, Language::Korean, &lexicon, None),
            Some("가나".to_owned()),
            "{layout:?} {keys}"
        );
        assert_eq!(type_with(lexicon.clone(), layout, &format!("{keys} ")), "가나 ");
    }
    let dubeol = TypoCorrector::keystrokes("가라", KeyboardLayout::Dubeol).unwrap();
    let atoms: Vec<_> = dubeol.chars().map(|key| KeyboardLayout::Dubeol.atom(key)).collect();
    assert_eq!(
        TypoCorrector::correction("가라", &atoms, Language::Korean, &lexicon, None),
        None,
        "dubeol {dubeol} is not an adjacent slip"
    );
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

/// `이번에는` is 이번 + 에 + 는. 이번 is a dictionary noun, but 이번에 is not,
/// so peeling the single particle 는 left an unknown stem. On 390 and 최종,
/// ㅂ is `;` and ㅈ is `l`; on 두벌식, ㅂ is `q` and ㅈ is `w`. Those keys
/// share an edge, and 이전에는 is the frequent word 이전에 plus 는, so the
/// word boundary rewrote a real noun phrase.
///
/// A wrong allomorph is still a slip: 문와는 (와 after ㄴ) becomes 문화는,
/// and 아직로는 (로 after ㄱ) becomes 아직도는. 하는 is an ending, not a
/// noun, so 하는에는 still becomes 하는데는.
#[test]
fn noun_plus_compound_particle_is_not_rewritten() {
    for lexicon in [lexicon(), keyboard_lexicon()] {
        assert!(lexicon.is_valid_korean("이번"), "이번");
        assert!(!lexicon.is_korean_word("이번에") && !lexicon.is_valid_korean("이번에"));
        assert!(lexicon.is_korean_word("이전에") || lexicon.is_valid_korean("이전에"));
        assert!(lexicon.is_korean_word("마음") || lexicon.is_valid_korean("마음"));
        assert!(lexicon.is_korean_word("사람") || lexicon.is_valid_korean("사람"));
        assert!(lexicon.is_korean_word("나") || lexicon.is_valid_korean("나"));
        for layout in [KeyboardLayout::Sebeol390, KeyboardLayout::SebeolFinal, KeyboardLayout::Dubeol] {
            for word in ["이번에는", "마음에는", "사람에는", "나에는", "학교에서는", "서울로는"]
            {
                let keys = TypoCorrector::keystrokes(word, layout).unwrap_or_else(|| panic!("keys for {word}"));
                let atoms: Vec<_> = keys.chars().map(|key| layout.atom(key)).collect();
                assert_eq!(
                    TypoCorrector::correction(word, &atoms, Language::Korean, &lexicon, None),
                    None,
                    "{layout:?}: {word} keys {keys}"
                );
                let open = type_with(lexicon.clone(), layout, &keys);
                assert_eq!(open, word, "{layout:?}: open {word}");
                for boundary in [" ", ".", "\n"] {
                    let typed = type_with(lexicon.clone(), layout, &format!("{keys}{boundary}"));
                    assert_eq!(typed, format!("{word}{boundary}"), "{layout:?}: {word} {boundary:?}");
                }
            }
        }
        // 이전에는 is 이전에 + 는, so the exemption must not rewrite it either.
        for layout in [KeyboardLayout::Sebeol390, KeyboardLayout::SebeolFinal, KeyboardLayout::Dubeol] {
            let neighbor = TypoCorrector::keystrokes("이전에는", layout).unwrap();
            let atoms: Vec<_> = neighbor.chars().map(|key| layout.atom(key)).collect();
            assert_eq!(
                TypoCorrector::correction("이전에는", &atoms, Language::Korean, &lexicon, None),
                None,
                "{layout:?}"
            );
        }
    }

    let lexicon = lexicon();
    for (typed, corrected) in [("문와는", "문화는"), ("아직로는", "아직도는"), ("하는에는", "하는데는")]
    {
        for layout in [KeyboardLayout::Sebeol390, KeyboardLayout::SebeolFinal] {
            let keys = TypoCorrector::keystrokes(typed, layout).unwrap_or_else(|| panic!("keys for {typed}"));
            let atoms: Vec<_> = keys.chars().map(|key| layout.atom(key)).collect();
            assert_eq!(
                TypoCorrector::correction(typed, &atoms, Language::Korean, &lexicon, None),
                Some(corrected.to_owned()),
                "{layout:?}: {typed} keys {keys}"
            );
            assert_eq!(
                type_with(lexicon.clone(), layout, &format!("{keys} ")),
                format!("{corrected} "),
                "{layout:?}: {typed}"
            );
        }
    }
}
