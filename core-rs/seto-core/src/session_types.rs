//! Value types from `Session.swift` shared with the golden corpus. `Session`
//! itself is ported in a later phase.

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Language {
    Korean,
    English,
}

impl Language {
    pub fn flipped(self) -> Language {
        match self {
            Language::Korean => Language::English,
            Language::English => Language::Korean,
        }
    }

    /// Swift `rawValue`.
    pub fn raw_value(self) -> &'static str {
        match self {
            Language::Korean => "korean",
            Language::English => "english",
        }
    }
}

/// Length of `text` in UTF-16 code units, the unit of every `FieldEdit` span.
pub fn utf16_len(text: &str) -> usize {
    text.encode_utf16().count()
}

/// What the field should do with this key. Confirmed English is ordinary
/// text. Hangul and undecided shifted punctuation stay in composition.
///
/// Every `utf16` span is counted in UTF-16 code units (NSString length),
/// exactly like the Swift enum. JSON form: `{"kind": "<case>", ...}`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum FieldEdit {
    /// Do not touch the field.
    None,
    /// Confirm the marked Hangul by inserting the same characters. Nothing is rewritten.
    Unmark { text: String },
    /// `insertText`. Replaces the marked range when one exists; otherwise appends.
    Insert { text: String },
    /// `setMarkedText`, replacing the current marked range.
    Mark { text: String },
    /// `setMarkedText`, replacing this many UTF-16 units before the caret.
    /// There is no marked range.
    ReplaceBeforeCaret { utf16: usize, text: String },
    /// Insert `insert` (replacing the marked range), then mark `mark`.
    InsertThenMark { insert: String, mark: String },
    /// `insertText` over this many UTF-16 units before the caret.
    InsertReplacing { utf16: usize, text: String },
    /// Replace this many UTF-16 units with `insert`, then mark `mark`.
    InsertReplacingThenMark { utf16: usize, insert: String, mark: String },
    /// Clear the marked range, then replace this many committed UTF-16 units
    /// with committed `text`.
    ClearMarkThenInsert { utf16: usize, text: String },
    /// Clear the marked range, then replace this many committed UTF-16 units
    /// with marked `text`.
    ClearMarkThenMark { utf16: usize, text: String },
    /// Replace the open token, counted back from the caret through the mark
    /// and the committed prefix, with committed `text` and then `then_mark`.
    Rewrite {
        utf16: usize,
        text: String,
        #[serde(rename = "thenMark")]
        then_mark: String,
    },
}

impl FieldEdit {
    /// Navigation can deliver the key unchanged: nothing is rewritten.
    pub fn preserves_characters(&self) -> bool {
        matches!(self, FieldEdit::None | FieldEdit::Unmark { .. })
    }

    /// Two client calls in one key can insert the same characters twice,
    /// because the second call still sees the selection from before the first.
    pub fn sends_more_than_one_edit(&self) -> bool {
        match self {
            FieldEdit::InsertThenMark { .. }
            | FieldEdit::InsertReplacingThenMark { .. }
            | FieldEdit::ClearMarkThenInsert { .. }
            | FieldEdit::ClearMarkThenMark { .. } => true,
            FieldEdit::Rewrite { then_mark, .. } => !then_mark.is_empty(),
            _ => false,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SessionUpdate {
    pub mode: Language,
    pub did_auto_convert: bool,
    /// Marked text after this update. Empty when nothing is in composition.
    pub preedit: String,
    pub field: FieldEdit,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utf16_lengths_count_code_units() {
        assert_eq!(utf16_len("abc"), 3);
        assert_eq!(utf16_len("한글"), 2);
        assert_eq!(utf16_len("👨‍👩‍👧‍👦"), 11);
        assert_eq!(utf16_len("𝄞"), 2);
    }

    #[test]
    fn field_edit_json_round_trip() {
        let cases = [
            (FieldEdit::None, r#"{"kind":"none"}"#),
            (FieldEdit::Mark { text: "ㅎ".into() }, r#"{"kind":"mark","text":"ㅎ"}"#),
            (
                FieldEdit::InsertReplacingThenMark { utf16: 2, insert: "a".into(), mark: "가".into() },
                r#"{"kind":"insertReplacingThenMark","utf16":2,"insert":"a","mark":"가"}"#,
            ),
            (
                FieldEdit::Rewrite { utf16: 3, text: "ab".into(), then_mark: "".into() },
                r#"{"kind":"rewrite","utf16":3,"text":"ab","thenMark":""}"#,
            ),
        ];
        for (field, json) in cases {
            assert_eq!(serde_json::to_string(&field).unwrap(), json);
            assert_eq!(serde_json::from_str::<FieldEdit>(json).unwrap(), field);
        }
    }

    #[test]
    fn edit_classification() {
        assert!(FieldEdit::None.preserves_characters());
        assert!(FieldEdit::Unmark { text: "가".into() }.preserves_characters());
        assert!(!FieldEdit::Insert { text: "a".into() }.preserves_characters());
        assert!(FieldEdit::InsertThenMark { insert: "a".into(), mark: "b".into() }.sends_more_than_one_edit());
        assert!(!FieldEdit::Rewrite { utf16: 1, text: "a".into(), then_mark: "".into() }.sends_more_than_one_edit());
        assert!(FieldEdit::Rewrite { utf16: 1, text: "a".into(), then_mark: "b".into() }.sends_more_than_one_edit());
        assert_eq!(Language::Korean.flipped(), Language::English);
    }
}
