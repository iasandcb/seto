//! Schema of `core-rs/testdata/session-golden.json`. Each scenario is one
//! session driven by a SetoCore test, recorded call by call. The file is a
//! checked-in expectation; replay it with `cargo test --test golden_replay`.

use serde::{Deserialize, Serialize};

use crate::layout::{KeyOutput, KeyboardLayout};
use crate::session_types::{Language, SessionUpdate};
pub use crate::typo_log::TypoRow;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GoldenFile {
    pub generator: String,
    pub schema: u32,
    /// Tests whose sessions were down-sampled to keep the corpus small.
    pub sampled: Vec<GoldenSampling>,
    pub scenario_count: usize,
    pub step_count: usize,
    pub scenarios: Vec<GoldenScenario>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GoldenSampling {
    pub test: String,
    pub recorded: usize,
    pub stride: u64,
    pub kept: usize,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GoldenScenario {
    /// `<TestFile>/<testFunction()>#<n>`.
    pub name: String,
    /// Other test sessions that recorded exactly the same config and steps.
    #[serde(default)]
    pub aliases: Vec<String>,
    /// Source location recorded with the scenario (`File.swift:line`).
    pub source: String,
    /// Human-readable key line: ⌫ backspace, ⇧ toggle, ⇥ commit, ↵ newline.
    pub keys: String,
    pub config: GoldenConfig,
    pub steps: Vec<GoldenStep>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GoldenConfig {
    pub layout: KeyboardLayout,
    pub auto_switch: bool,
    /// Initial mode.
    pub mode: Language,
    pub corrects_typos: bool,
    pub lexicon: GoldenLexicon,
    #[serde(default)]
    pub typos: Option<GoldenTypos>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum GoldenLexicon {
    /// `Lexicon.load(from: Resources/)`.
    Resources,
    /// `Lexicon.loadForKeyboard`: iOS/Keyboard/Resources/keyboard-*.txt plus
    /// Resources/korean-words.txt.
    Keyboard,
    /// `Lexicon(english:korean:abbreviations:techStems:validKorean:)`.
    #[serde(rename_all = "camelCase")]
    Words {
        english: Vec<String>,
        korean: Vec<String>,
        #[serde(default)]
        abbreviations: Vec<String>,
        #[serde(default)]
        tech_stems: Vec<String>,
        #[serde(default)]
        valid_korean: Vec<String>,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GoldenTypos {
    /// "memory": an in-memory `TypoMemory` seeded with `rows`.
    pub kind: String,
    pub rows: Vec<TypoRow>,
}

/// One call on the session.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum GoldenEvent {
    /// `Session.input(Character)`: `key` is read through the scenario layout.
    /// Space, newline and shifted pad digits (390 `M` = 1) are ordinary keys.
    Input {
        key: char,
    },
    /// `Session.input(KeyAtom)` with the atom `layout` builds for `key`.
    Atom {
        key: char,
        layout: KeyboardLayout,
        korean: KeyOutput,
    },
    Backspace,
    /// Shift+Space / Caps Lock.
    Toggle,
    /// Touch-keyboard long-press of ※.
    ConvertOpenWord,
    /// Navigation or focus change.
    CommitDisplayed {
        #[serde(rename = "value")]
        ending_run: bool,
    },
    ForceMode {
        mode: Language,
    },
    Discard,
    /// Property change; the step has no `update`.
    SetAutoSwitch {
        value: bool,
    },
    /// Property change; the step has no `update`.
    SetCorrectsTypos {
        value: bool,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GoldenStep {
    pub event: GoldenEvent,
    /// The returned `SessionUpdate`; absent for property changes.
    #[serde(default)]
    pub update: Option<SessionUpdate>,
    /// Session state after the call.
    pub document: String,
    pub mode: Language,
    pub preedit: String,
    /// `TypoMemory.record` calls made during this step.
    #[serde(default)]
    pub typo_records: Option<Vec<TypoRow>>,
}
