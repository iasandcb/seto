//! Mirrors Tests/Sebeol390CoreTests/KeyboardLexiconTests.swift: the mapped
//! keyboard files answer exactly like the desktop lexicon built from Resources.

mod common;

use std::collections::BTreeSet;

use common::{desktop_lexicon, keyboard_lexicon, keyboard_resources, resources};
use seto_core::Lexicon;

#[test]
fn mapped_keyboard_lexicon_matches_desktop() {
    let desktop = desktop_lexicon();
    let keyboard = keyboard_lexicon();
    for word in ["hello", "world", "baby", "babies", "boxes", "cats", "API", "ios", "zzzznonword"] {
        assert_eq!(keyboard.is_english_word(word), desktop.is_english_word(word), "{word}");
        assert_eq!(keyboard.is_english_prefix(word), desktop.is_english_prefix(word), "{word}");
    }
    assert!(!keyboard.is_english_prefix(""));
    assert_eq!(keyboard.valid_korean_word_count(), desktop.valid_korean_word_count());
    for word in ["안녕하세요", "사람", "키보드", "없는없는단어"] {
        assert_eq!(keyboard.is_valid_korean(word), desktop.is_valid_korean(word), "{word}");
        assert_eq!(keyboard.is_korean_word(word), desktop.is_korean_word(word), "{word}");
    }
    let mapped: BTreeSet<_> = keyboard.english_words(1..=4).into_iter().collect();
    let built: BTreeSet<_> = desktop.english_words(1..=4).into_iter().collect();
    assert_eq!(mapped, built);
}

#[test]
fn mapped_english_is_the_expanded_desktop_list() {
    // Every word of the in-memory expansion is in the mapped sidecar and
    // vice versa, so the two loaders are interchangeable.
    let desktop = desktop_lexicon();
    let keyboard = keyboard_lexicon();
    let mapped = keyboard.english_words(1..=usize::MAX);
    let built = desktop.english_words(1..=usize::MAX);
    assert_eq!(mapped.len(), built.len());
    assert!(mapped == built);
}

#[test]
fn load_for_keyboard_from_one_directory() {
    let directory = std::env::temp_dir().join(format!("seto-core-keyboard-{}", std::process::id()));
    std::fs::create_dir_all(&directory).unwrap();
    for name in ["keyboard-english.txt", "keyboard-korean-valid.txt"] {
        link_word_list(&keyboard_resources().join(name), &directory.join(name));
    }
    link_word_list(&resources().join("korean-words.txt"), &directory.join("korean-words.txt"));
    let lexicon = Lexicon::load_for_keyboard(&directory).unwrap();
    assert!(lexicon.is_english_word("hello"));
    assert!(lexicon.is_valid_korean("사람"));
    assert!(lexicon.is_korean_word("돼"));
    std::fs::remove_dir_all(&directory).unwrap();
}

/// The keyboard loader only needs the files in one directory. Unix keeps the
/// originals via a symlink; Windows copies them because symlink creation is
/// not available to a normal test process.
fn link_word_list(source: &std::path::Path, destination: &std::path::Path) {
    #[cfg(unix)]
    std::os::unix::fs::symlink(source, destination).unwrap();
    #[cfg(windows)]
    std::fs::copy(source, destination).unwrap();
}
