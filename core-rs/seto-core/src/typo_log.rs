//! Port of the parts of `Sources/SetoCore/TypoLog.swift` that `Session` and
//! `TypoCorrector` use: the `TypoMemory` protocol and `TypoLogPolicy`.
//!
//! The file-backed `TypoLog` (`typos.jsonl` under Application Support) stays
//! in Swift. [`MemoryTypos`] is the in-memory store with the same
//! `uniqueFinal` rule, which is what the Swift tests and the golden corpus use.

use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;

/// Local record of a word the user backspaced and retyped. Nothing here is
/// sent off the machine. Password fields never reach `record`: secure input
/// discards the session instead of editing it.
pub trait TypoMemory: Send + Sync {
    fn record(&self, wrong: &str, wrong_keys: &str, final_text: &str, final_keys: &str);
    /// The one replacement stored for `wrong`, when every record agrees.
    fn unique_final(&self, wrong: &str) -> Option<String>;
}

/// One `TypoMemory.record` call. Also the row type of the golden corpus.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TypoRow {
    pub wrong: String,
    pub wrong_keys: String,
    #[serde(rename = "final")]
    pub final_text: String,
    pub final_keys: String,
}

pub struct TypoLogPolicy;

impl TypoLogPolicy {
    /// Both sides need a couple of letters or jamo. Digits and one-syllable
    /// slips are not kept.
    pub fn should_store(wrong: &str, final_text: &str, wrong_keys: &str, final_keys: &str) -> bool {
        if wrong == final_text {
            return false;
        }
        if character_count(wrong) > 80 || character_count(final_text) > 80 {
            return false;
        }
        if character_count(wrong_keys) > 80 || character_count(final_keys) > 80 {
            return false;
        }
        if wrong.chars().any(is_newline) || final_text.chars().any(is_newline) {
            return false;
        }
        significant_count(wrong) >= 2 && significant_count(final_text) >= 2
    }
}

/// Swift `String.count`: extended grapheme clusters.
fn character_count(text: &str) -> usize {
    if text.is_ascii() && !text.contains('\r') { text.len() } else { text.graphemes(true).count() }
}

/// Swift `Character.isNewline`.
fn is_newline(character: char) -> bool {
    matches!(character, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

fn significant_count(text: &str) -> usize {
    text.chars()
        .filter(|character| {
            let value = *character as u32;
            let hangul = (0xAC00..=0xD7A3).contains(&value) || (0x3131..=0x318E).contains(&value);
            hangul || character.is_alphabetic()
        })
        .count()
}

/// In-memory `TypoMemory`: every record is kept, in order.
#[derive(Debug, Default)]
pub struct MemoryTypos {
    rows: Mutex<Vec<TypoRow>>,
}

impl MemoryTypos {
    pub fn new() -> MemoryTypos {
        MemoryTypos::default()
    }

    /// A store that already holds `rows`, without applying [`TypoLogPolicy`].
    pub fn seeded<I>(rows: I) -> MemoryTypos
    where
        I: IntoIterator<Item = TypoRow>,
    {
        MemoryTypos { rows: Mutex::new(rows.into_iter().collect()) }
    }

    pub fn rows(&self) -> Vec<TypoRow> {
        self.lock().clone()
    }

    pub fn len(&self) -> usize {
        self.lock().len()
    }

    pub fn is_empty(&self) -> bool {
        self.lock().is_empty()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<TypoRow>> {
        self.rows.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

impl TypoMemory for MemoryTypos {
    fn record(&self, wrong: &str, wrong_keys: &str, final_text: &str, final_keys: &str) {
        self.lock().push(TypoRow {
            wrong: wrong.to_owned(),
            wrong_keys: wrong_keys.to_owned(),
            final_text: final_text.to_owned(),
            final_keys: final_keys.to_owned(),
        });
    }

    fn unique_final(&self, wrong: &str) -> Option<String> {
        let rows = self.lock();
        let mut matches = rows.iter().filter(|row| row.wrong == wrong).map(|row| row.final_text.as_str());
        let first = matches.next()?;
        matches.all(|other| other == first).then(|| first.to_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn policy_needs_two_letters_or_jamo_on_both_sides() {
        assert!(TypoLogPolicy::should_store("한굴", "한글", "mfskbw", "mfskgw"));
        assert!(TypoLogPolicy::should_store("수ㅗ", "수고", "nbv", "nbkv"));
        assert!(TypoLogPolicy::should_store("teh", "the", "teh", "the"));
        // Unchanged, one syllable, or digits only.
        assert!(!TypoLogPolicy::should_store("한글", "한글", "mfskgw", "mfskgw"));
        assert!(!TypoLogPolicy::should_store("가", "나", "kf", "hf"));
        assert!(!TypoLogPolicy::should_store("가나", "나", "kfhf", "hf"));
        assert!(!TypoLogPolicy::should_store("12", "13", "M<", "M>"));
        assert!(!TypoLogPolicy::should_store("a1", "ab", "a1", "ab"));
    }

    #[test]
    fn policy_refuses_long_or_multiline_text() {
        let long = "가".repeat(81);
        let edge = "가".repeat(80);
        assert!(!TypoLogPolicy::should_store(&long, "한글", "kf", "mfskgw"));
        assert!(!TypoLogPolicy::should_store("한글", &long, "mfskgw", "kf"));
        assert!(TypoLogPolicy::should_store(&edge, "한글", "kf", "mfskgw"));
        assert!(!TypoLogPolicy::should_store("한굴", "한글", &"k".repeat(81), "mfskgw"));
        assert!(!TypoLogPolicy::should_store("한굴", "한글", "mfskbw", &"k".repeat(81)));
        assert!(!TypoLogPolicy::should_store("한\n굴", "한글", "mfskbw", "mfskgw"));
        assert!(!TypoLogPolicy::should_store("한굴", "한\u{2028}글", "mfskbw", "mfskgw"));
    }

    #[test]
    fn memory_returns_a_replacement_only_when_every_record_agrees() {
        // typoLogStoresJsonlAndKeepsTheTail / MemoryTypos: uniqueFinal.
        let memory = MemoryTypos::new();
        assert!(memory.is_empty());
        assert_eq!(memory.unique_final("갂"), None);
        memory.record("갂", "kfF", "가", "kf");
        assert_eq!(memory.unique_final("갂").as_deref(), Some("가"));
        memory.record("갂", "kfF", "가", "kf");
        assert_eq!(memory.unique_final("갂").as_deref(), Some("가"));
        memory.record("갂", "kfF", "나", "hf");
        assert_eq!(memory.unique_final("갂"), None);
        assert_eq!(memory.unique_final("굴"), None);
        assert_eq!(memory.len(), 3);
        assert_eq!(memory.rows()[2].final_text, "나");

        let seeded = MemoryTypos::seeded([TypoRow {
            wrong: "굴".into(),
            wrong_keys: "kbw".into(),
            final_text: "가".into(),
            final_keys: "kf".into(),
        }]);
        assert_eq!(seeded.unique_final("굴").as_deref(), Some("가"));
    }

    #[test]
    fn typo_row_uses_the_golden_json_names() {
        let json = r#"{"wrong":"한굴","wrongKeys":"mfskbw","final":"한글","finalKeys":"mfskgw"}"#;
        let row: TypoRow = serde_json::from_str(json).unwrap();
        assert_eq!(row.final_text, "한글");
        assert_eq!(serde_json::to_string(&row).unwrap(), json);
    }
}
