mod common;

use seto_core::{Language, Lexicon, Session};
use std::sync::Arc;

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
