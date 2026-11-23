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

/// `e2e` is end-to-end. On 390 the keys are bare jamo ㅕㅆㅕ (ㅕ, ㅆ, ㅕ), not a
/// syllable, so Hangul mode used to keep that reading. The same letter-2-letter
/// shape (`b2b`, `p2p`, `b2c`) is an alphanumeric token. A vowel-row digit can
/// still be a real syllable (`k8s`), and `kvaj5` is still 공유.
#[test]
fn e2e_in_hangul_mode() {
    let lexicons = [
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
    for lexicon in &lexicons {
        for token in ["e2e", "b2b", "p2p", "b2c", "c2c"] {
            assert!(lexicon.is_code_token(token), "{token}");
        }
        assert!(!lexicon.is_code_token("k8s"));
        assert!(!lexicon.is_code_token("v2a"));
        for layout in [KeyboardLayout::Sebeol390, KeyboardLayout::SebeolFinal, KeyboardLayout::Dubeol] {
            for mode in [Language::Korean, Language::English] {
                for token in ["e2e", "b2b", "p2p", "b2c"] {
                    let (document, _) = type_on(lexicon, layout, mode, token);
                    assert_eq!(document, token, "{layout:?} {mode:?} {token}");
                    let keys = format!("{token} ");
                    let (document, mode_after) = type_on(lexicon, layout, mode, &keys);
                    assert_eq!(document, keys, "{layout:?} {mode:?} {token}");
                    assert_eq!(mode_after, Language::English, "{layout:?} {mode:?} {token}");
                }
            }
            // `2` is also ㅆ on 390/최종. `r2h` is the vowel and batchim of 했
            // plus the next choseong, so that slice must not turn deploy했ㄴ
            // into Latin. Two-set input spells 했 with different keys.
            if layout != KeyboardLayout::Dubeol {
                let (document, mode_after) = type_on(lexicon, layout, Language::Korean, "deploymr2h");
                assert_eq!(document, "deploy했ㄴ", "{layout:?} {mode_after:?}");
                let (document, _) = type_on(lexicon, layout, Language::Korean, "deploymr2hgsuc");
                assert_eq!(document, "deploy했는데", "{layout:?}");
            }
        }
    }
}

/// `an` is the syllable 무 on 두벌식, and `le` is 져 on 390. Without this,
/// scoring keeps that syllable and spells the rest with short English hits
/// (무sible, ansib져). The same split hits other unlisted tech words.
#[test]
fn ansible_stays_english() {
    let lexicons = [
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
    for lexicon in &lexicons {
        assert!(lexicon.is_english_word("ansible"));
        assert!(lexicon.is_english_prefix("ansi"));
        assert!(!lexicon.is_english_word("splunk"));
        for layout in [KeyboardLayout::Dubeol, KeyboardLayout::Sebeol390, KeyboardLayout::SebeolFinal] {
            for mode in [Language::Korean, Language::English] {
                for suffix in ["", " "] {
                    let keys = format!("ansible{suffix}");
                    let (document, mode_after) = type_on(lexicon, layout, mode, &keys);
                    assert_eq!(document, keys, "{layout:?} {mode:?}");
                    if suffix == " " {
                        assert_eq!(mode_after, Language::English, "{layout:?} {mode:?}");
                    }
                }
                // Leading syllable 네, then Latin `lunk`. Not a dictionary word, so
                // this is the same split as ansible rather than the word list.
                // 390 `splunk` is only bare jamo and stays Korean.
                if layout == KeyboardLayout::Dubeol {
                    let (document, _) = type_on(lexicon, layout, mode, "splunk ");
                    assert_eq!(document, "splunk ", "{mode:?}");
                }
            }
        }
    }
}

/// `lean` is 졍ㅅ on 390. The syllable is still open, so the buffer stays
/// Hangul through the last letter (`health` must not leave Hangul at `heal`).
/// A word boundary replaces that unfinished choseong with the English word.
/// The same shape covers leak/leap, neal, heal, helen, and llvm.
#[test]
fn lean_and_similar_trailing_choseong_words_switch_to_english() {
    let lexicons = [
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
    for lexicon in &lexicons {
        for word in ["lean", "leak", "leap", "neal", "heal", "helen", "llvm"] {
            assert!(lexicon.is_english_word(word), "{word}");
        }
        for layout in [KeyboardLayout::Sebeol390, KeyboardLayout::SebeolFinal] {
            // These stay a trailing choseong through the last letter.
            for word in ["lean", "leak", "leap", "neal", "heal", "helen", "llvm", "health"] {
                let open = step_documents(lexicon, layout, word);
                assert!(
                    open.last().is_some_and(|text| text != word),
                    "{layout:?} {word} flipped before a boundary: {open:?}"
                );
                let (committed, _) = type_on(lexicon, layout, Language::Korean, &format!("{word} "));
                assert_eq!(committed, format!("{word} "), "{layout:?}");
            }
            // Longer words failed the Swift sweep at the shorter English word.
            for (word, at, hangul) in [
                ("leaning", 4, "졍ㅅ"),
                ("leaky", 4, "졍ㄱ"),
                ("leaks", 4, "졍ㄱ"),
                ("healer", 4, "녕ㅈ"),
                ("health", 4, "녕ㅈ"),
                ("height", 5, "녀므ㄴ"),
            ] {
                let open = step_documents(lexicon, layout, word);
                assert_eq!(open.get(at - 1).map(String::as_str), Some(hangul), "{layout:?} {word}");
            }

            let lean_steps = step_documents(lexicon, layout, "lean");
            assert_eq!(lean_steps, ["ㅈ", "져", "졍", "졍ㅅ"], "{layout:?}");

            // 녀ㅉ is still one choseong. The next letter is what makes hello.
            let hello_steps = step_documents(lexicon, layout, "hello");
            assert_eq!(hello_steps, ["ㄴ", "녀", "녀ㅈ", "녀ㅉ", "hello"], "{layout:?}");
            let (hell, mode_after) = type_on(lexicon, layout, Language::Korean, "hell ");
            assert_eq!(hell, "hell ", "{layout:?}");
            // The conversion happens at the boundary, after the doubled choseong
            // had already kept the buffer in Korean, so the mode stays Korean.
            assert_eq!(mode_after, Language::Korean, "{layout:?}");

            // 형식 is meandx. `mean` must not become English in the middle.
            let mean_steps = step_documents(lexicon, layout, "meandx");
            assert_eq!(mean_steps.last().map(String::as_str), Some("형식"), "{layout:?} {mean_steps:?}");
            assert_eq!(mean_steps.get(3).map(String::as_str), Some("형ㅅ"), "{layout:?}");
            let (mean, _) = type_on(lexicon, layout, Language::Korean, "mean ");
            assert_eq!(mean, "mean ", "{layout:?}");

            let ivy_steps = step_documents(lexicon, layout, "ivyguf");
            assert_eq!(ivy_steps.get(2).map(String::as_str), Some("모ㄹ"), "{layout:?}");
            assert_eq!(ivy_steps.last().map(String::as_str), Some("모르다"), "{layout:?}");
            let (ivy, mode_after) = type_on(lexicon, layout, Language::Korean, "ivy ");
            assert_eq!(ivy, "모ㄹ ", "{layout:?}");
            assert_eq!(mode_after, Language::Korean, "{layout:?}");

            let (input, _) = type_on(lexicon, layout, Language::Korean, "jd3yex ");
            assert_eq!(input, "입력 ", "{layout:?}");
        }
    }
}

/// `wsl` is ㄹㄴㅈ on 390: jongseong, jongseong, choseong, with no vowel.
/// That is not a Korean syllable. English mode already kept the QWERTY
/// letters (only chat reactions such as `jj` and `mm` → ㅎㅎ leave English).
/// Korean mode was keeping the consonant run because the word was missing
/// from the dictionary, so `ws` — now a prefix — flipped the leading `w`
/// back to ㄹㄴ. The same shape covers other consonant-only tech words.
#[test]
fn consonant_tech_words_stay_english() {
    let words = ["wsl", "jsx", "qml", "pwsh", "ssl"];
    let lexicons = [
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
    for lexicon in &lexicons {
        for word in words {
            assert!(lexicon.is_english_word(word), "{word}");
            assert!(lexicon.is_english_prefix(&word[..word.len() - 1]), "{word} prefix");
        }
        for layout in [KeyboardLayout::Sebeol390, KeyboardLayout::SebeolFinal] {
            for mode in [Language::Korean, Language::English] {
                for word in words {
                    let open = step_documents(lexicon, layout, word);
                    assert_eq!(open.last().map(String::as_str), Some(word), "{layout:?} {mode:?} {open:?}");
                    assert!(
                        !mid_word_latin_flipped(lexicon, layout, mode, word),
                        "{layout:?} {mode:?} {word} flipped mid-word: {open:?}"
                    );
                    let (committed, mode_after) = type_on(lexicon, layout, mode, &format!("{word} "));
                    assert_eq!(committed, format!("{word} "), "{layout:?} {mode:?}");
                    assert_eq!(mode_after, Language::English, "{layout:?} {mode:?} {word}");
                }
                // English mode must not adopt ㄹㄴㅈ even before the word is known.
                let mut session = Session::with_options(
                    Arc::clone(lexicon),
                    SessionOptions { layout, mode: Language::English, ..SessionOptions::default() },
                );
                for key in "wsl".chars() {
                    session.input_char(key);
                    assert_eq!(session.mode(), Language::English, "{layout:?}");
                }
                assert_eq!(session.document(), "wsl", "{layout:?}");
            }
            // Korean mode shows each letter of `wsl` as Latin, including the
            // prefix `ws`, instead of rewriting it to ㄹㄴㅈ.
            let steps = step_documents(lexicon, layout, "wsl");
            assert_eq!(steps, ["w", "ws", "wsl"], "{layout:?}");
            let (bare, mode_after) = type_on(lexicon, layout, Language::Korean, "wsl");
            assert_eq!(bare, "wsl", "{layout:?}");
            assert_eq!(mode_after, Language::English, "{layout:?}");
        }
    }

    // The rule is the dictionary, not a special case for these letters.
    let custom = Arc::new(Lexicon::new(&["qzp"], &["한글"]));
    for mode in [Language::Korean, Language::English] {
        let (known, mode_after) = type_on(&custom, KeyboardLayout::Sebeol390, mode, "qzp ");
        assert_eq!(known, "qzp ", "{mode:?}");
        assert_eq!(mode_after, Language::English, "{mode:?}");
    }
    let (unknown, mode_after) = type_on(&custom, KeyboardLayout::Sebeol390, Language::Korean, "qzq ");
    assert_ne!(unknown, "qzq ", "{unknown}");
    assert_eq!(mode_after, Language::Korean);
    let (english_unknown, mode_after) = type_on(&custom, KeyboardLayout::Sebeol390, Language::English, "qzq ");
    assert_eq!(english_unknown, "qzq ");
    assert_eq!(mode_after, Language::English);

    // Chat reactions still leave English. `jj` is ㅇㅇ, `mm` is ㅎㅎ.
    let desktop = Arc::new(Lexicon::load(&common::resources()).unwrap());
    let (jj, _) = type_on(&desktop, KeyboardLayout::Sebeol390, Language::English, "jj");
    assert_eq!(jj, "ㅇㅇ");
    let (mm, _) = type_on(&desktop, KeyboardLayout::Sebeol390, Language::English, "mm");
    assert_eq!(mm, "ㅎㅎ");
}

/// Mirrors `commonEnglishWordsDoNotFlipMidWord`: once a prefix is on screen as
/// Latin, a still-plausible English continuation must not turn back into Hangul.
fn mid_word_latin_flipped(lexicon: &Arc<Lexicon>, layout: KeyboardLayout, mode: Language, word: &str) -> bool {
    let mut session =
        Session::with_options(Arc::clone(lexicon), SessionOptions { layout, mode, ..SessionOptions::default() });
    let mut typed = String::new();
    let mut latin = false;
    for character in word.chars() {
        typed.push(character);
        session.input_char(character);
        if session.document() == typed {
            latin = true;
            continue;
        }
        let lower = typed.to_lowercase();
        if latin && (lexicon.is_english_word(&lower) || lexicon.is_english_prefix(&lower)) {
            return true;
        }
    }
    false
}

fn step_documents(lexicon: &Arc<Lexicon>, layout: KeyboardLayout, keys: &str) -> Vec<String> {
    let mut session =
        Session::with_options(Arc::clone(lexicon), SessionOptions { layout, ..SessionOptions::default() });
    let mut steps = Vec::new();
    for key in keys.chars() {
        session.input_char(key);
        steps.push(session.document());
    }
    steps
}
