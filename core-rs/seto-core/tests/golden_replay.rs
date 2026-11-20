//! Replay every golden keystroke against the Rust `Session`, and compare
//! document, mode, preedit, and FieldEdit to the checked-in corpus.

mod common;

use std::fmt::Write as _;
use std::sync::{Arc, OnceLock};

use seto_core::golden::{GoldenEvent, GoldenLexicon, GoldenScenario, GoldenStep};
use seto_core::{Lexicon, LexiconWords, MemoryTypos, Session, SessionOptions, SessionUpdate};

fn desktop_lexicon() -> Arc<Lexicon> {
    static LEXICON: OnceLock<Arc<Lexicon>> = OnceLock::new();
    LEXICON.get_or_init(|| Arc::new(Lexicon::load(&common::resources()).expect("Resources lexicon"))).clone()
}

fn keyboard_lexicon() -> Arc<Lexicon> {
    static LEXICON: OnceLock<Arc<Lexicon>> = OnceLock::new();
    LEXICON
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

fn lexicon_for(scenario: &GoldenScenario) -> Arc<Lexicon> {
    match &scenario.config.lexicon {
        GoldenLexicon::Resources => desktop_lexicon(),
        GoldenLexicon::Keyboard => keyboard_lexicon(),
        GoldenLexicon::Words { english, korean, abbreviations, tech_stems, valid_korean } => {
            let english: Vec<&str> = english.iter().map(String::as_str).collect();
            let korean: Vec<&str> = korean.iter().map(String::as_str).collect();
            let abbreviations: Vec<&str> = abbreviations.iter().map(String::as_str).collect();
            let tech_stems: Vec<&str> = tech_stems.iter().map(String::as_str).collect();
            let valid_korean: Vec<&str> = valid_korean.iter().map(String::as_str).collect();
            Arc::new(Lexicon::from_words(LexiconWords {
                english: &english,
                korean: &korean,
                abbreviations: &abbreviations,
                tech_stems: &tech_stems,
                valid_korean: &valid_korean,
            }))
        }
    }
}

struct Replay<'a> {
    session: Session,
    typos: Option<Arc<MemoryTypos>>,
    typo_cursor: usize,
    scenario: &'a GoldenScenario,
}

impl<'a> Replay<'a> {
    fn new(scenario: &'a GoldenScenario) -> Replay<'a> {
        let typos = scenario.config.typos.as_ref().map(|seed| Arc::new(MemoryTypos::seeded(seed.rows.clone())));
        let typo_cursor = typos.as_ref().map(|memory| memory.len()).unwrap_or(0);
        let session = Session::with_options(
            lexicon_for(scenario),
            SessionOptions {
                auto_switch: scenario.config.auto_switch,
                mode: scenario.config.mode,
                typos: typos.clone().map(|memory| memory as Arc<dyn seto_core::TypoMemory>),
                layout: scenario.config.layout,
            },
        );
        let mut replay = Replay { session, typos, typo_cursor, scenario };
        replay.session.corrects_typos = scenario.config.corrects_typos;
        replay
    }

    fn apply(&mut self, step: &GoldenStep) -> Option<SessionUpdate> {
        match &step.event {
            GoldenEvent::Input { key } => Some(self.session.input_char(*key)),
            GoldenEvent::Atom { key, layout, korean } => {
                let atom = layout.atom(*key);
                assert_eq!(
                    &atom.korean, korean,
                    "{}: recorded atom korean {:?} != Rust layout {:?} for {:?}",
                    self.scenario.name, korean, atom.korean, key
                );
                Some(self.session.input(atom))
            }
            GoldenEvent::Backspace => Some(self.session.backspace()),
            GoldenEvent::Toggle => Some(self.session.toggle()),
            GoldenEvent::ConvertOpenWord => Some(self.session.convert_open_word()),
            GoldenEvent::CommitDisplayed { ending_run } => Some(self.session.commit_displayed(*ending_run)),
            GoldenEvent::ForceMode { mode } => Some(self.session.force_mode(*mode)),
            GoldenEvent::Discard => Some(self.session.discard()),
            GoldenEvent::SetAutoSwitch { value } => {
                self.session.auto_switch = *value;
                None
            }
            GoldenEvent::SetCorrectsTypos { value } => {
                self.session.corrects_typos = *value;
                None
            }
        }
    }
}

struct Mismatch {
    name: String,
    step: usize,
    event: String,
    expected_document: String,
    actual_document: String,
    expected_mode: String,
    actual_mode: String,
    expected_preedit: String,
    actual_preedit: String,
    expected_field: String,
    actual_field: String,
}

fn describe_event(event: &GoldenEvent) -> String {
    match event {
        GoldenEvent::Input { key } => format!("input({key:?})"),
        GoldenEvent::Atom { key, layout, .. } => format!("atom({key:?}, {layout:?})"),
        GoldenEvent::Backspace => "backspace".into(),
        GoldenEvent::Toggle => "toggle".into(),
        GoldenEvent::ConvertOpenWord => "convertOpenWord".into(),
        GoldenEvent::CommitDisplayed { ending_run } => format!("commitDisplayed({ending_run})"),
        GoldenEvent::ForceMode { mode } => format!("forceMode({mode:?})"),
        GoldenEvent::Discard => "discard".into(),
        GoldenEvent::SetAutoSwitch { value } => format!("setAutoSwitch({value})"),
        GoldenEvent::SetCorrectsTypos { value } => format!("setCorrectsTypos({value})"),
    }
}

fn replay_all() -> (usize, usize, usize, usize, Vec<Mismatch>) {
    let corpus = common::golden();
    let mut scenario_ok = 0usize;
    let mut step_ok = 0usize;
    let mut mismatches = Vec::new();
    const KEEP: usize = 40;

    for scenario in &corpus.scenarios {
        let mut replay = Replay::new(scenario);
        let mut failed = false;
        for (index, step) in scenario.steps.iter().enumerate() {
            let update = replay.apply(step);
            let document = replay.session.document();
            let mode = replay.session.mode();
            let preedit = replay.session.preedit().to_owned();
            let field_ok = match (&step.update, &update) {
                (None, None) => true,
                (Some(expected), Some(actual)) => expected.field == actual.field,
                _ => false,
            };
            let typo_ok = if let Some(expected_rows) = &step.typo_records {
                let rows = replay.typos.as_ref().map(|memory| memory.rows()).unwrap_or_default();
                let added = if rows.len() >= replay.typo_cursor { &rows[replay.typo_cursor..] } else { &[] };
                let ok = added == expected_rows.as_slice();
                replay.typo_cursor = rows.len();
                ok
            } else {
                true
            };
            let update_ok = match (&step.update, &update) {
                (None, None) => true,
                (Some(expected), Some(actual)) => {
                    expected.mode == actual.mode
                        && expected.did_auto_convert == actual.did_auto_convert
                        && expected.preedit == actual.preedit
                        && expected.field == actual.field
                }
                _ => false,
            };
            if document == step.document
                && mode == step.mode
                && preedit == step.preedit
                && field_ok
                && typo_ok
                && update_ok
            {
                step_ok += 1;
            } else {
                if mismatches.len() < KEEP {
                    mismatches.push(Mismatch {
                        name: scenario.name.clone(),
                        step: index,
                        event: describe_event(&step.event),
                        expected_document: step.document.clone(),
                        actual_document: document,
                        expected_mode: format!("{:?}", step.mode),
                        actual_mode: format!("{:?}", mode),
                        expected_preedit: step.preedit.clone(),
                        actual_preedit: preedit,
                        expected_field: format!("{:?}", step.update.as_ref().map(|u| &u.field)),
                        actual_field: format!("{:?}", update.as_ref().map(|u| &u.field)),
                    });
                }
                failed = true;
                // Continue the scenario so later keys are visible, but the
                // scenario is already a miss.
            }
        }
        if !failed {
            scenario_ok += 1;
        }
    }
    (scenario_ok, corpus.scenarios.len(), step_ok, corpus.step_count, mismatches)
}

#[test]
fn rust_session_replays_every_golden_keystroke() {
    let (scenario_ok, scenario_total, step_ok, step_total, mismatches) = replay_all();
    let mut report = String::new();
    let _ =
        writeln!(report, "golden replay: {scenario_ok}/{scenario_total} scenarios, {step_ok}/{step_total} keystrokes");
    for item in &mismatches {
        let _ = writeln!(
            report,
            "\n- {} step {} {}\n  document expected {:?}\n           actual   {:?}\n  mode     expected {} actual {}\n  preedit  expected {:?} actual {:?}\n  field    expected {}\n           actual   {}",
            item.name,
            item.step,
            item.event,
            item.expected_document,
            item.actual_document,
            item.expected_mode,
            item.actual_mode,
            item.expected_preedit,
            item.actual_preedit,
            item.expected_field,
            item.actual_field,
        );
    }
    eprint!("{report}");
    assert!(scenario_ok == scenario_total && step_ok == step_total, "{report}");
}
