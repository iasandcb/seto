mod common;

use seto_core::{KeyboardLayout, Language, Lexicon, Session, SessionOptions};
use std::sync::Arc;

/// English-mode `0` is choseong ㅋ on 390. A code-like token must keep every
/// digit, including the intermediate `zou20`, while `kvaj5` still becomes 공유.
#[test]
fn alphanumeric_token_keeps_every_digit() {
    for lexicon in [
        Lexicon::load(&common::resources()).unwrap(),
        Lexicon::load_for_keyboard_files(
            &common::keyboard_resources().join("keyboard-english.txt"),
            &common::keyboard_resources().join("keyboard-korean-valid.txt"),
            &common::resources().join("korean-words.txt"),
        )
        .unwrap(),
    ] {
        let lexicon = Arc::new(lexicon);
        let mut session = Session::new(lexicon.clone());
        session.force_mode(Language::English);
        let mut typed = String::new();
        for key in "zou2026".chars() {
            typed.push(key);
            let update = session.input_char(key);
            assert_eq!(session.document(), typed, "{}", session.debug_line());
            assert_eq!(update.preedit, "", "{typed}");
            assert_eq!(session.mode(), Language::English, "{typed}");
        }

        for token in ["v20", "html50", "utf80", "i18n0", "a11y0", "AI0", "ML0", "0", "102", "2020", "zou2", "zou202"] {
            let mut session = Session::new(lexicon.clone());
            session.force_mode(Language::English);
            let mut typed = String::new();
            for key in token.chars() {
                typed.push(key);
                let update = session.input_char(key);
                assert_eq!(session.document(), typed, "{} {}", token, session.debug_line());
                assert!(
                    update.preedit.chars().all(|character| character.is_ascii_alphanumeric()),
                    "{token} {typed} preedit {}",
                    update.preedit
                );
                assert_eq!(session.mode(), Language::English, "{token}");
            }
        }

        let mut gongyu = Session::new(lexicon.clone());
        gongyu.force_mode(Language::English);
        for key in "kvaj5".chars() {
            gongyu.input_char(key);
        }
        assert_eq!(gongyu.document(), "공유", "{}", gongyu.debug_line());
        assert_eq!(gongyu.mode(), Language::Korean);

        let mut particle = Session::new(lexicon.clone());
        particle.force_mode(Language::English);
        for key in "AIhgs".chars() {
            particle.input_char(key);
        }
        assert_eq!(particle.document(), "AI는", "{}", particle.debug_line());

        let mut chat = Session::new(lexicon);
        chat.force_mode(Language::English);
        chat.input_char('j');
        chat.input_char('0');
        assert_eq!(chat.document(), "ㅇㅋ", "{}", chat.debug_line());
    }
}

#[test]
fn jj_chat_reaction_from_english_mode() {
    for lexicon in [
        Lexicon::load(&common::resources()).unwrap(),
        Lexicon::load_for_keyboard_files(
            &common::keyboard_resources().join("keyboard-english.txt"),
            &common::keyboard_resources().join("keyboard-korean-valid.txt"),
            &common::resources().join("korean-words.txt"),
        )
        .unwrap(),
    ] {
        assert!(lexicon.is_english_prefix("jj"));
        let lexicon = Arc::new(lexicon);
        for (keys, expected) in
            [("jj", "ㅇㅇ"), ("jj ", "ㅇㅇ "), ("jj.", "jj."), ("jj\n", "ㅇㅇ\n"), ("jjs ", "jjs "), ("JJ ", "JJ ")]
        {
            let mut session = Session::new(lexicon.clone());
            session.force_mode(Language::English);
            for key in keys.chars() {
                session.input_char(key);
            }
            assert_eq!(session.document(), expected, "{keys}");
        }
    }
}

#[test]
fn merge_stays_korean_at_word_boundary() {
    // Same 390 keys as Swift's mergeStaysKoreanAtWordBoundary; also exercise
    // the trimmed validity list shipped on Android.
    for lexicon in [
        Lexicon::load(&common::resources()).unwrap(),
        Lexicon::load_for_keyboard_files(
            &common::keyboard_resources().join("keyboard-english.txt"),
            &common::keyboard_resources().join("keyboard-korean-valid.txt"),
            &common::resources().join("korean-words.txt"),
        )
        .unwrap(),
    ] {
        let lexicon = Arc::new(lexicon);
        for (keys, expected) in [("itld", "머지"), ("itldmfkv", "머지하고")] {
            let mut session = Session::new(lexicon.clone());
            for key in keys.chars() {
                session.input_char(key);
            }
            assert_eq!(session.document(), expected);
            session.input_char(' ');
            assert_eq!(session.document(), format!("{expected} "));
        }
    }
}

fn type_on(lexicon: &Arc<Lexicon>, layout: KeyboardLayout, mode: Language, keys: &str) -> (String, Language) {
    let mut session =
        Session::with_options(Arc::clone(lexicon), SessionOptions { layout, mode, ..SessionOptions::default() });
    for key in keys.chars() {
        session.input_char(key);
    }
    (session.document(), session.mode())
}

/// `sody` is a Webster headword only as a US dialect of soda. On 두벌식 those
/// keys are 내요, so the Hangul reading wins. 해요/돼요/가요 follow the same
/// rule. Real English words whose two-set reading also ends in 요 stay English.
#[test]
fn sody_and_common_yo_forms_beat_obscure_english() {
    let listed = Arc::new(Lexicon::new(
        &[
            "sody", "gody", "ehody", "rkdy", "ehldy", "hello", "giddy", "world", "wordy", "shady", "toddy", "ready",
            "body", "study", "rhapsody", "soda", "andy", "rudy",
        ],
        &["내", "해", "가", "돼", "되", "나"],
    ));
    for mode in [Language::Korean, Language::English] {
        for (keys, expected) in [
            ("sody", "내요"),
            ("sody ", "내요 "),
            ("sody.", "내요."),
            ("gody ", "해요 "),
            ("ehody ", "돼요 "),
            ("rkdy ", "가요 "),
            ("ehldy ", "되요 "),
            ("skdy ", "나요 "),
            ("hello sody ", "hello 내요 "),
        ] {
            let (document, _) = type_on(&listed, KeyboardLayout::Dubeol, mode, keys);
            assert_eq!(document, expected, "listed lexicon {mode:?} {keys}");
        }
        for word in
            ["giddy", "world", "wordy", "shady", "toddy", "ready", "body", "study", "rhapsody", "soda", "andy", "rudy"]
        {
            let keys = format!("{word} ");
            let (document, mode_after) = type_on(&listed, KeyboardLayout::Dubeol, mode, &keys);
            assert_eq!(document, keys, "listed lexicon {mode:?} {word}");
            assert_eq!(mode_after, Language::English, "listed lexicon {mode:?} {word}");
        }
    }

    let bundled = [
        Arc::new(Lexicon::load(&common::resources()).unwrap()),
        Arc::new(
            Lexicon::load_for_keyboard_files(
                &common::keyboard_resources().join("keyboard-english.txt"),
                &common::keyboard_resources().join("keyboard-korean-valid.txt"),
                &common::resources().join("korean-words.txt"),
            )
            .unwrap(),
        ),
    ];
    for lexicon in &bundled {
        assert!(!lexicon.is_english_word("sody"));
        assert!(!lexicon.is_english_word("sodies"));
        assert!(!lexicon.is_english_prefix("sody"));
        for mode in [Language::Korean, Language::English] {
            for (keys, expected) in [
                ("sody", "내요"),
                ("sody ", "내요 "),
                ("gody ", "해요 "),
                ("ehody ", "돼요 "),
                ("rkdy ", "가요 "),
                ("ehldy ", "되요 "),
                ("skdy ", "나요 "),
                ("hello sody ", "hello 내요 "),
            ] {
                let (document, mode_after) = type_on(lexicon, KeyboardLayout::Dubeol, mode, keys);
                assert_eq!(document, expected, "{mode:?} {keys}");
                if keys.ends_with(' ') {
                    assert_eq!(mode_after, Language::Korean, "{mode:?} {keys}");
                }
            }
            for word in ["world", "giddy", "shady", "wordy", "ready", "body", "study", "rhapsody", "soda"] {
                let keys = format!("{word} ");
                let (document, mode_after) = type_on(lexicon, KeyboardLayout::Dubeol, mode, &keys);
                assert_eq!(document, keys, "{mode:?} {word}");
                assert_eq!(mode_after, Language::English, "{mode:?} {word}");
            }
            for layout in [KeyboardLayout::Sebeol390, KeyboardLayout::SebeolFinal] {
                let (document, mode_after) = type_on(lexicon, layout, mode, "hrj4 ");
                assert_eq!(document, "내요 ", "{layout:?} {mode:?}");
                assert_eq!(mode_after, Language::Korean, "{layout:?} {mode:?}");
            }
        }
    }
}
