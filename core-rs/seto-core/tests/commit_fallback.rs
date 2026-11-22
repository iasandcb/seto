//! Hosts that cannot keep a composing span (Android TYPE_NULL, or an editor
//! that finishComposingText/setText drops the span) still get the same Hangul.
//! Edits only commit and replace; a commitText client can replay them.

mod common;

use seto_core::{FieldEdit, Lexicon, Session, utf16_len};
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

fn composing_edit(field: &FieldEdit) -> bool {
    match field {
        FieldEdit::Mark { .. }
        | FieldEdit::ReplaceBeforeCaret { .. }
        | FieldEdit::InsertThenMark { .. }
        | FieldEdit::InsertReplacingThenMark { .. }
        | FieldEdit::ClearMarkThenMark { .. } => true,
        FieldEdit::Rewrite { then_mark, .. } => !then_mark.is_empty(),
        FieldEdit::ClearMarkThenInsert { .. } => true,
        _ => false,
    }
}

fn pop_utf16(buffer: &mut String, count: usize) {
    let mut units: Vec<u16> = buffer.encode_utf16().collect();
    units.truncate(units.len().saturating_sub(count));
    *buffer = String::from_utf16(&units).expect("utf-16");
}

/// A client with commitText and deleteSurroundingText, and no composing span.
fn apply_committed(buffer: &mut String, before: &str, after: &str, field: &FieldEdit) {
    assert!(!composing_edit(field), "commit-only edit still marks: {field:?}");
    match field {
        FieldEdit::None => {
            if utf16_len(before) == utf16_len(after) + 1 && before.starts_with(after) {
                pop_utf16(buffer, 1);
            }
        }
        FieldEdit::Unmark { .. } => {}
        FieldEdit::Insert { text } => buffer.push_str(text),
        FieldEdit::InsertReplacing { utf16, text } | FieldEdit::Rewrite { utf16, text, .. } => {
            pop_utf16(buffer, *utf16);
            buffer.push_str(text);
        }
        other => panic!("unhandled commit edit {other:?}"),
    }
    assert_eq!(buffer, after, "{field:?}");
}

fn commit_session() -> Session {
    let mut session = Session::new(lexicon());
    session.set_composing(false, true);
    session
}

fn assert_same_document(keys: &str) {
    let mut marked = Session::new(lexicon());
    let mut bare = commit_session();
    let mut paper = String::new();
    for key in keys.chars() {
        let before = bare.document();
        marked.input_char(key);
        let update = bare.input_char(key);
        assert_eq!(update.preedit, "", "{keys} preedit after {key}");
        assert_eq!(bare.document(), marked.document(), "{keys} after {key}");
        apply_committed(&mut paper, &before, &bare.document(), &update.field);
    }
}

#[test]
fn commit_only_matches_composing_hangul() {
    for keys in ["itld ", "itldmfkv ", "jj ", "jj.", "kvaj5 ", "hello ", "AIhgs ", "k"] {
        assert_same_document(keys);
    }
}

#[test]
fn commit_only_backspace_matches_composing_session() {
    let mut marked = Session::new(lexicon());
    let mut bare = commit_session();
    let mut paper = String::new();
    for key in "itld".chars() {
        marked.input_char(key);
        let before = bare.document();
        let update = bare.input_char(key);
        apply_committed(&mut paper, &before, &bare.document(), &update.field);
    }
    assert_eq!(bare.document(), "머지");
    for _ in 0..4 {
        let before = bare.document();
        marked.backspace();
        let update = bare.backspace();
        assert_eq!(update.preedit, "");
        assert_eq!(bare.document(), marked.document(), "{}", bare.debug_line());
        apply_committed(&mut paper, &before, &bare.document(), &update.field);
    }
    assert_eq!(paper, "");
}

#[test]
fn folding_a_live_preedit_keeps_the_syllable() {
    let mut session = Session::new(lexicon());
    let mut bare = commit_session();
    for key in "itl".chars() {
        session.input_char(key);
        bare.input_char(key);
    }
    assert!(!session.preedit().is_empty());
    let shown = session.document();
    let folded = session.set_composing(false, true);
    assert_eq!(folded.field, FieldEdit::None);
    assert_eq!(folded.preedit, "");
    assert_eq!(session.preedit(), "");
    assert_eq!(session.document(), shown);
    assert_eq!(session.document(), bare.document());

    let mut paper = shown.clone();
    for key in "dmfkv ".chars() {
        let before = session.document();
        bare.input_char(key);
        let update = session.input_char(key);
        assert_eq!(update.preedit, "");
        assert_eq!(session.document(), bare.document(), "{key}");
        apply_committed(&mut paper, &before, &session.document(), &update.field);
    }
    assert_eq!(session.document(), "머지하고 ");
}

#[test]
fn rejected_composing_span_is_committed_instead() {
    let mut session = Session::new(lexicon());
    let marked = session.input_char('i');
    assert!(!marked.preedit.is_empty(), "first jamo is composed");
    assert!(composing_edit(&marked.field), "a composing host would mark {:?}", marked.field);
    // setComposingText failed: the editor does not yet show the preedit.
    let commit = session.set_composing(false, false);
    assert_eq!(commit.preedit, "");
    let mut paper = String::new();
    apply_committed(&mut paper, "", &session.document(), &commit.field);
    assert_eq!(paper, session.document());

    let mut bare = commit_session();
    bare.input_char('i');
    for key in "tld ".chars() {
        let before = session.document();
        bare.input_char(key);
        let update = session.input_char(key);
        apply_committed(&mut paper, &before, &session.document(), &update.field);
        assert_eq!(session.document(), bare.document());
    }
    assert_eq!(paper, "머지 ");
}
