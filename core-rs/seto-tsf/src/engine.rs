//! Session driver. Turns a [`WinKey`](crate::keys::WinKey) into a core
//! [`SessionUpdate`](seto_core::SessionUpdate) using the same calls as the
//! macOS input controller and the Android hardware keyboard: `input` of the
//! QWERTY character, `backspace`, `toggle`, and `commit_displayed` on a
//! boundary the app must still receive.

use std::sync::Arc;

use seto_core::{FieldEdit, Language, Lexicon, Session, SessionOptions, SessionUpdate};

use crate::keys::{self, DecisionState, DownClass, UpClass, WinKey, eaten_down, eaten_up};

/// Result of one key transition.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum KeyEffect {
    /// The application receives the key. Apply `commit` first when it is set.
    /// `app_deletes` means the app's own Backspace deletes one scalar and the
    /// session has already dropped that scalar from its committed mirror.
    Pass { commit: Option<SessionUpdate>, app_deletes: bool },
    /// The text service ate the key. `delete_utf16` is an extra deletion the
    /// core left to the client (a committed letter inside the open word).
    Eat { update: Option<SessionUpdate>, delete_utf16: usize },
}

pub struct Engine {
    lexicon: Arc<Lexicon>,
    session: Session,
    decision: DecisionState,
}

impl Engine {
    pub fn new(lexicon: Arc<Lexicon>) -> Self {
        let session = Session::new(Arc::clone(&lexicon));
        Self { lexicon, session, decision: DecisionState::default() }
    }

    pub fn document(&self) -> String {
        self.session.document()
    }

    pub fn preedit(&self) -> &str {
        self.session.preedit()
    }

    pub fn mode(&self) -> Language {
        self.session.mode()
    }

    pub fn has_open_word(&self) -> bool {
        self.session.has_open_word()
    }

    /// Called when the text service activates, so a Shift or Right Alt that
    /// is already down is not treated as a fresh tap.
    pub fn sync_modifiers(&mut self, shift_down: bool, right_alt_down: bool) {
        self.decision.shift_tracker.shift_changed(shift_down);
        if right_alt_down && !self.decision.right_alt_down {
            self.decision.right_alt_down = true;
            self.decision.right_alt_used = true;
        }
    }

    pub fn will_eat_down(&self, key: &WinKey) -> bool {
        let mut state = self.decision;
        state.open_word = self.session.has_open_word();
        state.composing = !self.session.preedit().is_empty();
        eaten_down(keys::step_down(&mut state, key))
    }

    pub fn will_eat_up(&self, key: &WinKey) -> bool {
        let mut state = self.decision;
        eaten_up(keys::step_up(&mut state, key))
    }

    pub fn key_down(&mut self, key: &WinKey) -> KeyEffect {
        self.decision.open_word = self.session.has_open_word();
        self.decision.composing = !self.session.preedit().is_empty();
        let class = keys::step_down(&mut self.decision, key);
        let effect = match class {
            DownClass::Pass { commit, ending_run, .. } => {
                let commit = commit.then(|| self.session.commit_displayed(ending_run));
                KeyEffect::Pass { commit, app_deletes: false }
            }
            DownClass::AppBackspace => {
                let _ = self.session.backspace();
                KeyEffect::Pass { commit: None, app_deletes: true }
            }
            DownClass::Shift { .. } | DownClass::Swallow { .. } => KeyEffect::Eat { update: None, delete_utf16: 0 },
            DownClass::Toggle => {
                let update = self.session.toggle();
                KeyEffect::Eat { update: Some(update), delete_utf16: 0 }
            }
            DownClass::Backspace => {
                let update = self.session.backspace();
                let delete_utf16 = if matches!(update.field, FieldEdit::None) { 1 } else { 0 };
                KeyEffect::Eat { update: Some(update), delete_utf16 }
            }
            DownClass::Input(ch) => {
                let update = self.session.input_char(ch);
                KeyEffect::Eat { update: Some(update), delete_utf16: 0 }
            }
        };
        // Shift is not eaten, but `step_down` still recorded it. Reporting
        // Eat for Shift would swallow the modifier. Hand it back to the app.
        let effect = match class {
            DownClass::Shift { .. } => KeyEffect::Pass { commit: None, app_deletes: false },
            _ => effect,
        };
        self.decision.open_word = self.session.has_open_word();
        self.decision.composing = !self.session.preedit().is_empty();
        effect
    }

    pub fn key_up(&mut self, key: &WinKey) -> KeyEffect {
        let class = keys::step_up(&mut self.decision, key);
        let effect = match class {
            UpClass::Pass => KeyEffect::Pass { commit: None, app_deletes: false },
            UpClass::Eat { toggle: false } => KeyEffect::Eat { update: None, delete_utf16: 0 },
            UpClass::Eat { toggle: true } => {
                let update = self.session.toggle();
                KeyEffect::Eat { update: Some(update), delete_utf16: 0 }
            }
        };
        self.decision.open_word = self.session.has_open_word();
        self.decision.composing = !self.session.preedit().is_empty();
        effect
    }

    /// Focus loss, deactivation, or a disabled (password) context. The open
    /// word is committed in place and the next field starts clean.
    pub fn commit_for_focus_loss(&mut self) -> SessionUpdate {
        let update = self.session.commit_displayed(true);
        self.decision.open_word = self.session.has_open_word();
        self.decision.composing = !self.session.preedit().is_empty();
        self.decision.right_alt_down = false;
        self.decision.right_alt_used = false;
        update
    }

    /// The application ended the composition on its own (click, Escape in
    /// some hosts). The characters are already final; drop the open word
    /// without writing them again.
    pub fn note_external_composition_end(&mut self) {
        let mode = self.session.mode();
        let auto_switch = self.session.auto_switch;
        let corrects_typos = self.session.corrects_typos;
        let mut session =
            Session::with_options(Arc::clone(&self.lexicon), SessionOptions { mode, ..SessionOptions::default() });
        session.auto_switch = auto_switch;
        session.corrects_typos = corrects_typos;
        self.session = session;
        self.decision.open_word = false;
        self.decision.composing = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::apply::{Document, plan_edit};
    use crate::keys::vk;

    fn engine() -> Engine {
        Engine::new(Arc::new(Lexicon::new(&["hello", "world", "the", "of", "to", "in"], &["한글", "사랑", "감사"])))
    }

    fn apply_effect(doc: &mut Document, effect: &KeyEffect) {
        match effect {
            KeyEffect::Pass { commit, app_deletes } => {
                if let Some(update) = commit
                    && let Some(plan) = plan_edit(doc.composition_utf16(), &update.field)
                {
                    doc.apply_plan(&plan);
                }
                if *app_deletes {
                    doc.delete_scalar_before_caret();
                }
            }
            KeyEffect::Eat { update, delete_utf16 } => {
                let field_is_none = update.as_ref().is_none_or(|update| matches!(update.field, FieldEdit::None));
                if *delete_utf16 > 0 && field_is_none {
                    doc.apply_plan(&crate::apply::EditPlan {
                        delete_utf16: *delete_utf16,
                        insert: String::new(),
                        compose_utf16: 0,
                    });
                } else if let Some(update) = update
                    && let Some(plan) = plan_edit(doc.composition_utf16(), &update.field)
                {
                    doc.apply_plan(&plan);
                }
            }
        }
    }

    fn press(engine: &mut Engine, doc: &mut Document, key: WinKey) {
        let effect = engine.key_down(&key);
        apply_effect(doc, &effect);
        assert_eq!(doc.text(), engine.document(), "document after {key:?}");
        assert_eq!(doc.composition(), engine.preedit(), "preedit after {key:?}");
    }

    fn press_char(engine: &mut Engine, doc: &mut Document, ch: char, shift: bool) {
        press(engine, doc, WinKey::qwerty(ch, shift));
    }

    fn release(engine: &mut Engine, doc: &mut Document, key: WinKey) {
        let effect = engine.key_up(&key);
        apply_effect(doc, &effect);
        assert_eq!(doc.text(), engine.document());
        assert_eq!(doc.composition(), engine.preedit());
    }

    #[test]
    fn hangul_is_underlined_until_a_boundary() {
        let mut engine = engine();
        let mut doc = Document::new();
        press_char(&mut engine, &mut doc, 'k', false);
        assert_eq!(doc.composition(), "ㄱ");
        assert!(engine.will_eat_down(&WinKey::bare(vk::BACK)));
        press_char(&mut engine, &mut doc, 'f', false);
        assert_eq!(doc.text(), "가");
        assert_eq!(doc.composition(), "가");
        assert!(engine.will_eat_down(&WinKey::bare(vk::BACK)));
        assert!(!engine.will_eat_down(&WinKey::bare(vk::RETURN)));
        press(&mut engine, &mut doc, WinKey::bare(vk::BACK));
        assert_eq!(doc.composition(), "ㄱ");
        press_char(&mut engine, &mut doc, 'f', false);
        press_char(&mut engine, &mut doc, ' ', false);
        assert_eq!(doc.text(), "가 ");
        assert_eq!(doc.composition(), "");
    }

    #[test]
    fn mr2jt_composes_haess_eo_and_enter_commits() {
        let mut engine = engine();
        let mut doc = Document::new();
        for ch in ['m', 'r', '2', 'j', 't'] {
            press_char(&mut engine, &mut doc, ch, false);
        }
        assert_eq!(doc.text(), "했어");
        assert_eq!(doc.composition(), "했어");
        let enter = engine.key_down(&WinKey::bare(vk::RETURN));
        assert!(matches!(enter, KeyEffect::Pass { commit: Some(_), app_deletes: false }));
        apply_effect(&mut doc, &enter);
        assert_eq!(doc.text(), "했어");
        assert_eq!(doc.composition(), "");
        assert!(!engine.will_eat_down(&WinKey::bare(vk::RETURN)));
    }

    #[test]
    fn backspace_walks_through_the_core_then_the_app() {
        let mut engine = engine();
        let mut doc = Document::new();
        press_char(&mut engine, &mut doc, 'k', false);
        press_char(&mut engine, &mut doc, 'f', false);
        press(&mut engine, &mut doc, WinKey::bare(vk::BACK));
        assert_eq!(doc.composition(), "ㄱ");
        press(&mut engine, &mut doc, WinKey::bare(vk::BACK));
        assert_eq!(doc.text(), "");
        press_char(&mut engine, &mut doc, 'k', false);
        press_char(&mut engine, &mut doc, 'f', false);
        press_char(&mut engine, &mut doc, ' ', false);
        assert_eq!(doc.text(), "가 ");
        press(&mut engine, &mut doc, WinKey::bare(vk::BACK));
        assert_eq!(doc.text(), "가");
        assert!(!engine.will_eat_down(&WinKey::bare(vk::BACK)));
    }

    #[test]
    fn toggles_on_hangul_right_alt_and_shift_space() {
        let mut engine = engine();
        let mut doc = Document::new();
        assert_eq!(engine.mode(), Language::Korean);
        press(&mut engine, &mut doc, WinKey::bare(vk::HANGUL));
        assert_eq!(engine.mode(), Language::English);
        press_char(&mut engine, &mut doc, 'k', false);
        assert_eq!(doc.text(), "k");
        assert_ne!(doc.text(), "ㄱ");

        let right_alt = WinKey { vk: vk::RMENU, right_alt: true, ..WinKey::bare(vk::RMENU) };
        press(&mut engine, &mut doc, right_alt);
        assert_eq!(engine.mode(), Language::English);
        release(&mut engine, &mut doc, right_alt);
        assert_eq!(engine.mode(), Language::Korean);

        press(&mut engine, &mut doc, WinKey::bare(vk::LSHIFT));
        press(&mut engine, &mut doc, WinKey::qwerty(' ', true));
        assert_eq!(engine.mode(), Language::English);
        let mut release_shift = WinKey::bare(vk::LSHIFT);
        release_shift.shift = false;
        release(&mut engine, &mut doc, release_shift);

        press(&mut engine, &mut doc, WinKey::bare(vk::LSHIFT));
        press(&mut engine, &mut doc, WinKey::qwerty('/', true));
        press(&mut engine, &mut doc, WinKey::qwerty(' ', true));
        assert_eq!(engine.mode(), Language::English);
        assert!(doc.text().ends_with("? "));
    }

    #[test]
    fn ctrl_does_not_eat_the_key_and_commits_composition() {
        let mut engine = engine();
        let mut doc = Document::new();
        press_char(&mut engine, &mut doc, 'k', false);
        press_char(&mut engine, &mut doc, 'f', false);
        let mut ctrl_c = WinKey::qwerty('c', false);
        ctrl_c.control = true;
        assert!(!engine.will_eat_down(&ctrl_c));
        press(&mut engine, &mut doc, ctrl_c);
        assert_eq!(doc.text(), "가");
        assert_eq!(doc.composition(), "");
        assert!(!engine.has_open_word());
    }

    #[test]
    fn punctuation_commits_inside_the_core() {
        let mut engine = engine();
        let mut doc = Document::new();
        press_char(&mut engine, &mut doc, 'k', false);
        press_char(&mut engine, &mut doc, 'f', false);
        press_char(&mut engine, &mut doc, '.', false);
        assert_eq!(doc.text(), "가.");
        assert_eq!(doc.composition(), "");
    }

    #[test]
    fn focus_loss_commits_the_open_syllable() {
        let mut engine = engine();
        let mut doc = Document::new();
        press_char(&mut engine, &mut doc, 'k', false);
        press_char(&mut engine, &mut doc, 'f', false);
        let update = engine.commit_for_focus_loss();
        if let Some(plan) = plan_edit(doc.composition_utf16(), &update.field) {
            doc.apply_plan(&plan);
        }
        assert_eq!(doc.text(), "가");
        assert_eq!(doc.composition(), "");
        assert_eq!(engine.preedit(), "");
        assert_eq!(engine.mode(), Language::Korean);
    }
}
