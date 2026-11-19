//! Checks the Swift golden corpus (testdata/session-golden.json): it parses
//! into the shared Rust schema, its key atoms match the Rust layouts, and its
//! FieldEdits (UTF-16 spans) rebuild every recorded document.

mod common;

use std::collections::BTreeSet;

use seto_core::golden::{GoldenEvent, GoldenLexicon};
use seto_core::{FieldEdit, KeyboardLayout, Language};

/// The field model from SessionTests.swift (`Paper`), which mirrors
/// InputController: committed text plus the marked range at the caret.
#[derive(Default)]
struct Paper {
    committed: Vec<u16>,
    marked: Vec<u16>,
}

impl Paper {
    fn text(&self) -> String {
        String::from_utf16(&[self.committed.as_slice(), self.marked.as_slice()].concat()).expect("valid UTF-16")
    }

    fn marked(&self) -> String {
        String::from_utf16(&self.marked).expect("valid UTF-16")
    }

    fn drop_end(units: &mut Vec<u16>, count: usize) {
        let keep = units.len().saturating_sub(count);
        units.truncate(keep);
    }

    fn remove_before_caret(&mut self, utf16: usize) {
        let from_mark = utf16.min(self.marked.len());
        Self::drop_end(&mut self.marked, from_mark);
        Self::drop_end(&mut self.committed, utf16 - from_mark);
    }

    fn apply(&mut self, field: &FieldEdit) {
        let units = |text: &str| text.encode_utf16().collect::<Vec<_>>();
        match field {
            FieldEdit::None => {}
            FieldEdit::Unmark { text } | FieldEdit::Insert { text } => {
                self.committed.extend(units(text));
                self.marked.clear();
            }
            FieldEdit::Mark { text } => self.marked = units(text),
            FieldEdit::ReplaceBeforeCaret { utf16, text } => {
                self.remove_before_caret(*utf16);
                self.marked = units(text);
            }
            FieldEdit::InsertThenMark { insert, mark } => {
                self.committed.extend(units(insert));
                self.marked = units(mark);
            }
            FieldEdit::InsertReplacing { utf16, text } => {
                self.remove_before_caret(*utf16);
                self.committed.extend(units(text));
                self.marked.clear();
            }
            FieldEdit::InsertReplacingThenMark { utf16, insert, mark } => {
                Self::drop_end(&mut self.committed, *utf16);
                self.committed.extend(units(insert));
                self.marked = units(mark);
            }
            FieldEdit::ClearMarkThenInsert { utf16, text } => {
                self.remove_before_caret(utf16 + self.marked.len());
                self.committed.extend(units(text));
                self.marked.clear();
            }
            FieldEdit::ClearMarkThenMark { utf16, text } => {
                self.remove_before_caret(utf16 + self.marked.len());
                self.marked = units(text);
            }
            FieldEdit::Rewrite { utf16, text, then_mark } => {
                let take = (*utf16).min(self.marked.len());
                Self::drop_end(&mut self.marked, take);
                Self::drop_end(&mut self.committed, utf16 - take);
                self.committed.extend(units(text));
                self.marked = units(then_mark);
            }
        }
    }

    /// The app deletes one character itself when the session passes Backspace through.
    fn delete_one(&mut self) {
        if self.marked.is_empty() {
            Self::drop_end(&mut self.committed, 1);
        } else {
            Self::drop_end(&mut self.marked, 1);
        }
    }
}

#[test]
fn golden_corpus_parses_and_is_consistent() {
    let golden = common::golden();
    assert_eq!(golden.schema, 1);
    assert_eq!(golden.scenarios.len(), golden.scenario_count);
    assert_eq!(golden.scenarios.iter().map(|s| s.steps.len()).sum::<usize>(), golden.step_count);
    assert!(golden.scenario_count > 1000, "{}", golden.scenario_count);

    let mut names = BTreeSet::new();
    for scenario in &golden.scenarios {
        assert!(names.insert(scenario.name.as_str()), "duplicate {}", scenario.name);
        assert!(!scenario.steps.is_empty());
        if let GoldenLexicon::Words { english, korean, .. } = &scenario.config.lexicon {
            assert!(english.len() + korean.len() < 100, "{}", scenario.name);
        }
        for step in &scenario.steps {
            let property =
                matches!(step.event, GoldenEvent::SetAutoSwitch { .. } | GoldenEvent::SetCorrectsTypos { .. });
            assert_eq!(step.update.is_none(), property, "{}", scenario.name);
            if let Some(update) = &step.update {
                if !matches!(step.event, GoldenEvent::ForceMode { .. }) {
                    assert_eq!(update.mode, step.mode, "{}", scenario.name);
                }
                assert_eq!(update.preedit, step.preedit, "{}", scenario.name);
            }
            assert!(step.document.ends_with(&step.preedit), "{}", scenario.name);
        }
    }
}

#[test]
fn golden_corpus_covers_the_key_cases() {
    let golden = common::golden();
    let ends_with = |keys: &str, mode: Language, document: &str| {
        golden.scenarios.iter().any(|scenario| {
            scenario.keys == keys
                && scenario.config.mode == mode
                && scenario.config.layout == KeyboardLayout::Sebeol390
                && scenario.steps.last().is_some_and(|step| step.document == document)
        })
    };
    assert!(ends_with("uvr ", Language::English, "돼 "));
    assert!(ends_with("kvaj5", Language::English, "공유"));
    assert!(ends_with("nbv", Language::Korean, "수ㅗ"));
    // TransitionCorpusTests: each item, then a word boundary.
    assert!(ends_with("hello ", Language::Korean, "hello "));
    assert!(ends_with("mgz ", Language::English, "흠 "));
    assert!(ends_with("deploymr2hgsuc ", Language::Korean, "deploy했는데 "));
    assert!(ends_with("deploymr2hgsuc ", Language::English, "deploy했는데 "));
    assert!(ends_with("AIyv ", Language::English, "AI로 "));
    assert!(ends_with("ktxhgs ", Language::Korean, "ktx는 "));
    assert!(ends_with("agents.md ", Language::Korean, "agents.md "));
    assert!(ends_with("one of the ", Language::English, "one of the "));

    let layouts: BTreeSet<_> = golden.scenarios.iter().map(|s| s.config.layout.raw_value()).collect();
    assert_eq!(layouts.len(), 3);
    assert!(golden.scenarios.iter().any(|s| !s.config.auto_switch));
    assert!(golden.scenarios.iter().any(|s| s.config.typos.is_some()));
    assert!(golden.scenarios.iter().any(|s| s.config.lexicon == GoldenLexicon::Keyboard));
    for event in ["backspace", "toggle", "commitDisplayed", "forceMode", "discard", "setCorrectsTypos", "atom"] {
        let present = golden.scenarios.iter().flat_map(|s| &s.steps).any(|step| {
            let json = serde_json::to_value(&step.event).unwrap();
            json["type"] == event
        });
        assert!(present, "{event}");
    }
}

#[test]
fn golden_atoms_match_rust_layouts() {
    let golden = common::golden();
    let mut checked = 0;
    for scenario in &golden.scenarios {
        for step in &scenario.steps {
            if let GoldenEvent::Atom { key, layout, korean } = &step.event {
                assert_eq!(layout.atom(*key).korean, *korean, "{} {key:?}", scenario.name);
                checked += 1;
            }
        }
    }
    assert!(checked > 100, "{checked}");
}

#[test]
fn golden_field_edits_rebuild_the_document() {
    let golden = common::golden();
    let mut failures = Vec::new();
    for scenario in &golden.scenarios {
        let mut paper = Paper::default();
        for (index, step) in scenario.steps.iter().enumerate() {
            let Some(update) = &step.update else { continue };
            if matches!(step.event, GoldenEvent::Backspace) && update.field == FieldEdit::None {
                paper.delete_one();
            } else {
                paper.apply(&update.field);
            }
            if paper.text() != step.document || paper.marked() != step.preedit {
                failures.push(format!(
                    "{} step {index}: paper {:?} marked {:?} / document {:?} preedit {:?}",
                    scenario.name,
                    paper.text(),
                    paper.marked(),
                    step.document,
                    step.preedit
                ));
                break;
            }
        }
    }
    assert!(failures.is_empty(), "{} failures:\n{}", failures.len(), failures[..failures.len().min(10)].join("\n"));
}
