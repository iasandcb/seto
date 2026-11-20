#![allow(dead_code)]

use std::path::PathBuf;
use std::sync::OnceLock;

use seto_core::{KeyAtom, KeyboardLayout, Lexicon, compose, dubeol, final_layout, layout390};

/// Repository root (core-rs/..).
pub fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

pub fn resources() -> PathBuf {
    repo_root().join("Resources")
}

pub fn keyboard_resources() -> PathBuf {
    repo_root().join("iOS/Keyboard/Resources")
}

/// `Lexicon.load(from: Resources)`, shared like Swift's file-level `lexicon`.
pub fn desktop_lexicon() -> &'static Lexicon {
    static LEXICON: OnceLock<Lexicon> = OnceLock::new();
    LEXICON.get_or_init(|| Lexicon::load(&resources()).expect("Resources lexicon"))
}

/// `Lexicon.loadForKeyboard`, without copying the files into one directory.
pub fn keyboard_lexicon() -> &'static Lexicon {
    static LEXICON: OnceLock<Lexicon> = OnceLock::new();
    LEXICON.get_or_init(|| {
        Lexicon::load_for_keyboard_files(
            &keyboard_resources().join("keyboard-english.txt"),
            &keyboard_resources().join("keyboard-korean-valid.txt"),
            &resources().join("korean-words.txt"),
        )
        .expect("keyboard lexicon")
    })
}

pub fn atoms(layout: KeyboardLayout, keys: &str) -> Vec<KeyAtom> {
    keys.chars().map(|key| layout.atom(key)).collect()
}

pub fn atoms390(keys: &str) -> Vec<KeyAtom> {
    keys.chars().map(layout390::atom).collect()
}

pub fn compose390(keys: &str) -> String {
    compose(&atoms390(keys)).text
}

pub fn compose_final(keys: &str) -> String {
    compose(&keys.chars().map(final_layout::atom).collect::<Vec<_>>()).text
}

pub fn compose_dubeol(keys: &str) -> String {
    compose(&keys.chars().map(dubeol::atom).collect::<Vec<_>>()).text
}

/// testdata/session-golden.json, parsed once per test binary.
pub fn golden() -> &'static seto_core::golden::GoldenFile {
    static GOLDEN: OnceLock<seto_core::golden::GoldenFile> = OnceLock::new();
    GOLDEN.get_or_init(|| {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../testdata/session-golden.json");
        let text = std::fs::read_to_string(&path).expect("golden corpus testdata/session-golden.json");
        serde_json::from_str(&text).expect("golden corpus matches the Rust schema")
    })
}
