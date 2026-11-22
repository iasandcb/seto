//! Hosts that cannot keep a composing span (Android TYPE_NULL) still compose
//! Hangul, but the editor only receives `commitText` of finished text.
//! The open syllable stays in the session. Nothing is deleted.

mod common;

use seto_core::{FieldEdit, Language, Lexicon, Session};
use std::sync::{Arc, OnceLock};

fn lexicon() -> Arc<Lexicon> {
    static SHARED: OnceLock<Arc<Lexicon>> = OnceLock::new();
    SHARED
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

fn append_only(field: &FieldEdit) -> bool {
    matches!(field, FieldEdit::None | FieldEdit::Insert { .. })
}

fn push_insert(paper: &mut String, field: &FieldEdit) {
    assert!(append_only(field), "raw field was asked to delete or mark: {field:?}");
    if let FieldEdit::Insert { text } = field {
        paper.push_str(text);
    }
}

fn commit_session() -> Session {
    let mut session = Session::new(lexicon());
    session.set_composing(false, true);
    session
}

fn assert_appends_until_boundary(keys: &str) {
    let mut marked = Session::new(lexicon());
    let mut bare = commit_session();
    let mut paper = String::new();
    for key in keys.chars() {
        marked.input_char(key);
        let update = bare.input_char(key);
        assert_eq!(bare.document(), marked.document(), "{keys} after {key} {}", bare.debug_line());
        push_insert(&mut paper, &update.field);
        assert!(bare.document().starts_with(&paper), "{keys} showed {:?}, document {}", paper, bare.document());
    }
    assert_eq!(paper, bare.document(), "{keys} did not flush on the boundary");
}

#[test]
fn raw_field_commits_finished_syllables_without_deleting() {
    for keys in ["itld ", "itldmfkv ", "jj ", "jj.", "kvaj5 ", "hello ", "AIhgs ", "k "] {
        assert_appends_until_boundary(keys);
    }
}

#[test]
fn open_syllable_is_not_sent_and_backspace_does_not_delete() {
    let mut bare = commit_session();
    let first = bare.input_char('i');
    assert_eq!(first.field, FieldEdit::None, "the first jamo must stay buffered: {:?}", first.field);
    assert!(!bare.preedit().is_empty());
    let erased = bare.backspace();
    assert!(append_only(&erased.field), "{:?}", erased.field);
    assert_eq!(bare.document(), "");
    assert!(matches!(erased.field, FieldEdit::None));
}

#[test]
fn english_mode_still_inserts_letters() {
    let mut bare = commit_session();
    bare.force_mode(Language::English);
    let mut paper = String::new();
    for key in "hello ".chars() {
        let update = bare.input_char(key);
        push_insert(&mut paper, &update.field);
    }
    assert_eq!(paper, "hello ");
    assert_eq!(bare.document(), "hello ");
}

#[test]
fn mode_switch_flushes_the_buffered_syllable() {
    let mut bare = commit_session();
    let held = bare.input_char('i');
    assert_eq!(held.field, FieldEdit::None);
    let flushed = bare.toggle();
    let FieldEdit::Insert { text } = flushed.field else { panic!("{:?}", flushed.field) };
    assert_eq!(text, bare.document());
    assert!(!text.is_empty());
    assert_eq!(flushed.preedit, "");
}
