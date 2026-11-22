//! Turn a [`FieldEdit`](seto_core::FieldEdit) into one caret-relative replacement.
//!
//! macOS applies the same edit with `insertText` / `setMarkedText`. Android
//! applies it with composing spans. Both count spans in UTF-16 code units and
//! keep the caret at the end of the open word, so one plan is enough for a
//! shadow buffer and for the TSF range update.

use seto_core::{FieldEdit, utf16_len};

/// Replacement immediately before the caret.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditPlan {
    /// UTF-16 units before the caret to replace. Includes the live composition
    /// when the span reaches into it.
    pub delete_utf16: usize,
    pub insert: String,
    /// UTF-16 units at the end of `insert` that stay underlined. Zero commits
    /// the whole replacement.
    pub compose_utf16: usize,
}

/// `None` when the field does not change the document (including a pure mode flip).
pub fn plan_edit(composition_utf16: usize, field: &FieldEdit) -> Option<EditPlan> {
    let marked = composition_utf16;
    match field {
        FieldEdit::None => None,
        // The characters are already on screen. Ending the composition is the
        // whole edit; an empty insert must not wipe the range.
        FieldEdit::Unmark { .. } => Some(EditPlan { delete_utf16: 0, insert: String::new(), compose_utf16: 0 }),
        FieldEdit::Insert { text } => Some(EditPlan { delete_utf16: marked, insert: text.clone(), compose_utf16: 0 }),
        FieldEdit::Mark { text } => {
            Some(EditPlan { delete_utf16: marked, insert: text.clone(), compose_utf16: utf16_len(text) })
        }
        FieldEdit::ReplaceBeforeCaret { utf16, text } => {
            Some(EditPlan { delete_utf16: *utf16, insert: text.clone(), compose_utf16: utf16_len(text) })
        }
        FieldEdit::InsertThenMark { insert, mark } => {
            Some(EditPlan { delete_utf16: marked, insert: format!("{insert}{mark}"), compose_utf16: utf16_len(mark) })
        }
        FieldEdit::InsertReplacing { utf16, text } => {
            Some(EditPlan { delete_utf16: *utf16, insert: text.clone(), compose_utf16: 0 })
        }
        FieldEdit::InsertReplacingThenMark { utf16, insert, mark } => {
            Some(EditPlan { delete_utf16: *utf16, insert: format!("{insert}{mark}"), compose_utf16: utf16_len(mark) })
        }
        FieldEdit::ClearMarkThenInsert { utf16, text } => {
            Some(EditPlan { delete_utf16: utf16 + marked, insert: text.clone(), compose_utf16: 0 })
        }
        FieldEdit::ClearMarkThenMark { utf16, text } => {
            Some(EditPlan { delete_utf16: utf16 + marked, insert: text.clone(), compose_utf16: utf16_len(text) })
        }
        FieldEdit::Rewrite { utf16, text, then_mark } => Some(EditPlan {
            delete_utf16: *utf16,
            insert: format!("{text}{then_mark}"),
            compose_utf16: utf16_len(then_mark),
        }),
    }
}

/// Shadow of the focused field. The caret is a UTF-16 index and the
/// composition is the `composition` units immediately before it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Document {
    units: Vec<u16>,
    caret: usize,
    composition: usize,
}

impl Document {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn text(&self) -> String {
        String::from_utf16_lossy(&self.units)
    }

    pub fn composition(&self) -> String {
        let start = self.caret.saturating_sub(self.composition);
        String::from_utf16_lossy(&self.units[start..self.caret])
    }

    pub fn composition_utf16(&self) -> usize {
        self.composition
    }

    pub fn apply_plan(&mut self, plan: &EditPlan) {
        let delete = plan.delete_utf16.min(self.caret);
        let start = self.caret - delete;
        let inserted: Vec<u16> = plan.insert.encode_utf16().collect();
        self.units.splice(start..self.caret, inserted.iter().copied());
        self.caret = start + inserted.len();
        self.composition = plan.compose_utf16.min(inserted.len());
    }

    /// One Unicode scalar before the caret, matching a BMP Backspace and the
    /// session's grapheme drop for the text this crate tests.
    pub fn delete_scalar_before_caret(&mut self) {
        if self.caret == 0 {
            return;
        }
        let mut start = self.caret - 1;
        if start > 0 && is_low_surrogate(self.units[start]) && is_high_surrogate(self.units[start - 1]) {
            start -= 1;
        }
        self.units.drain(start..self.caret);
        self.caret = start;
        if self.composition > self.caret.saturating_sub(0) {
            self.composition = self.composition.min(self.caret);
        }
        let available = self.caret;
        if self.composition > available {
            self.composition = available;
        }
    }
}

fn is_high_surrogate(unit: u16) -> bool {
    (0xD800..=0xDBFF).contains(&unit)
}

fn is_low_surrogate(unit: u16) -> bool {
    (0xDC00..=0xDFFF).contains(&unit)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plans_follow_the_macos_ranges() {
        let cases = [
            (1, FieldEdit::None, None),
            (
                1,
                FieldEdit::Unmark { text: "가".into() },
                Some(EditPlan { delete_utf16: 0, insert: String::new(), compose_utf16: 0 }),
            ),
            (
                1,
                FieldEdit::Mark { text: "각".into() },
                Some(EditPlan { delete_utf16: 1, insert: "각".into(), compose_utf16: 1 }),
            ),
            (
                0,
                FieldEdit::Insert { text: "b".into() },
                Some(EditPlan { delete_utf16: 0, insert: "b".into(), compose_utf16: 0 }),
            ),
            (
                0,
                FieldEdit::InsertThenMark { insert: "b".into(), mark: "가".into() },
                Some(EditPlan { delete_utf16: 0, insert: "b가".into(), compose_utf16: 1 }),
            ),
            (
                1,
                FieldEdit::ReplaceBeforeCaret { utf16: 2, text: "나".into() },
                Some(EditPlan { delete_utf16: 2, insert: "나".into(), compose_utf16: 1 }),
            ),
            (
                1,
                FieldEdit::Rewrite { utf16: 3, text: "cd".into(), then_mark: "나".into() },
                Some(EditPlan { delete_utf16: 3, insert: "cd나".into(), compose_utf16: 1 }),
            ),
        ];
        for (marked, field, plan) in cases {
            assert_eq!(plan_edit(marked, &field), plan);
        }
    }

    #[test]
    fn document_replaces_before_the_caret() {
        let mut doc = Document::new();
        doc.apply_plan(&EditPlan { delete_utf16: 0, insert: "ab가".into(), compose_utf16: 1 });
        assert_eq!(doc.text(), "ab가");
        assert_eq!(doc.composition(), "가");
        doc.apply_plan(&EditPlan { delete_utf16: 2, insert: "나".into(), compose_utf16: 1 });
        assert_eq!(doc.text(), "a나");
        assert_eq!(doc.composition(), "나");
        doc.apply_plan(&EditPlan { delete_utf16: 0, insert: String::new(), compose_utf16: 0 });
        assert_eq!(doc.text(), "a나");
        assert_eq!(doc.composition(), "");
    }
}
