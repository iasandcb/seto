//! Mirrors Tests/Sebeol390CoreTests/LexiconTests.swift, plus the lexicon
//! facts SessionTests.swift asserts before driving a Session.

mod common;

use common::{desktop_lexicon, keyboard_lexicon};
use seto_core::{Lexicon, LexiconWords, WordList};

#[test]
fn unix_commands_are_in_bundled_lexicon() {
    let lexicon = desktop_lexicon();
    for command in [
        "chmod",
        "chown",
        "xargs",
        "rsync",
        "launchctl",
        "systemctl",
        "awk",
        "sed",
        "grep",
        "zsh",
        "ssh-keygen",
        "apt-get",
    ] {
        assert!(lexicon.is_english_word(command), "{command}");
        assert!(lexicon.is_english_prefix(&command[..3]), "{command}");
    }
    assert!(lexicon.korean_word_count() > 0);
    assert!(lexicon.valid_korean_word_count() > 0);
}

#[test]
fn regular_plural_forms_also_have_typing_prefixes() {
    let lexicon = Lexicon::new(&["command", "directory", "box", "batch", "process", "key"], &[]);
    for word in ["commands", "directories", "boxes", "batches", "processes", "keys"] {
        assert!(lexicon.is_english_word(word), "{word}");
        assert!(lexicon.is_english_word(&word.to_uppercase()), "{word}");
        for length in 1..=word.len() {
            assert!(lexicon.is_english_prefix(&word[..length]), "{word} {length}");
        }
    }
    assert!(!lexicon.is_english_word("directorys"));
    assert!(!lexicon.is_english_word("keyies"));
}

#[test]
fn session_tests_lexicon_facts() {
    let lexicon = desktop_lexicon();
    // twoLetterPrefixesConvertToFrequentSyllablesAtWordBoundary
    assert!(lexicon.is_english_prefix("jc"));
    assert!(!lexicon.is_english_word("jc"));
    assert!(lexicon.is_korean_word("에"));
    assert!(lexicon.is_english_prefix("jd"));
    assert!(lexicon.is_korean_word("이"));
    assert!(lexicon.is_english_prefix("uv"));
    assert!(lexicon.is_korean_word("도"));
    assert!(lexicon.is_english_word("of"));
    assert!(lexicon.is_english_word("ut"));
    // frequentSyllablesLongerThanTwoKeysConvertAtWordBoundary
    for (keys, syllable) in [("uvr", "돼"), ("ibt", "뭐"), ("nfs", "산"), ("ibs", "문")] {
        assert!(lexicon.is_english_prefix(keys), "{keys}");
        assert!(!lexicon.is_english_word(keys), "{keys}");
        assert!(lexicon.is_korean_word(syllable), "{syllable}");
    }
    assert!(lexicon.is_english_word("uvrou"));
    assert!(lexicon.is_english_word("jew"));
    assert!(lexicon.is_korean_word("열"));
    // digitKeyKoreanWordsConvertFromEnglishMode
    assert!(lexicon.is_valid_korean("공유"));
    assert!(!lexicon.is_korean_word("공유"));
    assert!(lexicon.is_code_token("kvaj5"));
    assert!(!lexicon.is_english_word("kvaj5"));
    assert!(lexicon.is_code_token("ob3"));
    assert!(lexicon.is_valid_korean("춥"));
    // realKoreanWordsStayUncorrected
    assert!(lexicon.valid_korean_word_count() > 100_000);
    assert!(lexicon.is_valid_korean("바탕"));
    assert!(lexicon.is_valid_korean("공간"));
    // roOverridesEnglishNamePrefixAndCanBeUndone
    assert!(lexicon.is_english_prefix("yv"));
}

#[test]
fn code_tokens_and_abbreviations() {
    let lexicon = desktop_lexicon();
    for token in ["v2", "V10", "utf8", "mp3", "html5", "page2", "i18n", "a11y", "b12c"] {
        assert!(lexicon.is_code_token(token), "{token}");
    }
    // One letter plus one digit is the middle of a syllable (r2 in 했).
    for token in ["r2", "x", "v", "abc", "2v", "mr2", "ab12c", "i1n", "v2a", "bcd3", "k8s"] {
        assert!(!lexicon.is_code_token(token), "{token}");
    }
    assert!(lexicon.is_abbreviation("AI"));
    assert!(lexicon.is_abbreviation("HTTPS"));
    assert!(!lexicon.is_abbreviation("Ai"));
    assert!(!lexicon.is_abbreviation("A"));
    assert!(!lexicon.is_abbreviation("ZZZ"));
    let custom =
        Lexicon::from_words(LexiconWords { abbreviations: &["ktx"], tech_stems: &["BC"], ..Default::default() });
    assert!(custom.is_abbreviation("KTX"));
    assert!(custom.is_code_token("bc1"));
}

#[test]
fn korean_lookups_normalize_to_nfc() {
    let lexicon = Lexicon::from_words(LexiconWords {
        korean: &["\u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF}"],
        valid_korean: &["사람"],
        ..Default::default()
    });
    assert!(lexicon.is_korean_word("한글"));
    assert!(lexicon.is_korean_word("\u{1112}\u{1161}\u{11AB}글"));
    assert!(lexicon.is_valid_korean("\u{1109}\u{1161}람"));
    assert_eq!(lexicon.korean_words(), ["한글"]);
    assert!(desktop_lexicon().is_korean_word("\u{1112}\u{1173}\u{11B7}"));
}

#[test]
fn completions_are_bounded_prefix_lookups() {
    let lexicon = keyboard_lexicon();
    assert!(lexicon.english_completions("", 256).is_empty());
    assert!(lexicon.english_completions("hell", 0).is_empty());
    let completions = lexicon.english_completions("hell", 256);
    assert!(completions.len() <= 256);
    assert!(completions.iter().all(|word| word.starts_with("hell")));
    assert!(completions.iter().any(|word| word == "hello"));
    assert_eq!(completions, desktop_lexicon().english_completions("HELL", 256));
    let mut sorted = completions.clone();
    sorted.sort();
    assert_eq!(completions, sorted);
}

#[test]
fn word_list_rejects_unsorted_files() {
    let directory = std::env::temp_dir().join(format!("seto-core-wordlist-{}", std::process::id()));
    std::fs::create_dir_all(&directory).unwrap();
    let good = directory.join("good.txt");
    std::fs::write(&good, "# header\n\nalpha\nbeta\ngamma").unwrap();
    let list = WordList::open(&good).unwrap();
    assert_eq!(list.len(), 3);
    assert_eq!(list.iter().collect::<Vec<_>>(), ["alpha", "beta", "gamma"]);
    assert!(list.contains("gamma"));
    assert!(!list.contains("gam"));
    assert!(list.has_prefix("gam"));
    let bad = directory.join("bad.txt");
    std::fs::write(&bad, "beta\nalpha\n").unwrap();
    assert!(WordList::open(&bad).is_err());
    let empty = directory.join("empty.txt");
    std::fs::write(&empty, "").unwrap();
    assert!(WordList::open(&empty).unwrap().is_empty());
    std::fs::remove_dir_all(&directory).unwrap();
}
