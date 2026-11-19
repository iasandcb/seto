//! Android-facing adapter only. All composition and language decisions stay in seto-core.
use seto_core::{Lexicon, Session, SessionOptions, TypoMemory};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::sync::{Arc, Mutex};

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum EngineError {
    #[error("{detail}")]
    Failure { detail: String },
}
type Result<T> = std::result::Result<T, EngineError>;
fn failure(message: impl Into<String>) -> EngineError {
    EngineError::Failure { detail: message.into() }
}
fn boundary<T>(f: impl FnOnce() -> Result<T>) -> Result<T> {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or_else(|_| Err(failure("Rust engine panicked; discard this session")))
}

// Never replace mapped files while the process is alive. Android uses versioned directories.
static LEXICON: Mutex<Option<(LexiconPaths, Arc<Lexicon>)>> = Mutex::new(None);
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct LexiconPaths {
    pub english: String,
    pub korean_words: String,
    pub korean_valid: String,
}

/// Loads once per process. Repeating the same paths is harmless; changing them is an error.
#[uniffi::export]
pub fn load_lexicon(paths: LexiconPaths) -> Result<()> {
    boundary(|| {
        let mut loaded = LEXICON.lock().map_err(|_| failure("Lexicon lock poisoned"))?;
        if let Some((existing, _)) = &*loaded {
            return if existing == &paths { Ok(()) } else { Err(failure("Lexicon already loaded from other paths")) };
        }
        let lexicon = Lexicon::load_for_keyboard_files(
            Path::new(&paths.english),
            Path::new(&paths.korean_valid),
            Path::new(&paths.korean_words),
        )
        .map_err(|e| failure(e.to_string()))?;
        *loaded = Some((paths, Arc::new(lexicon)));
        Ok(())
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum Language {
    Korean,
    English,
}
impl From<seto_core::Language> for Language {
    fn from(value: seto_core::Language) -> Self {
        match value {
            seto_core::Language::Korean => Self::Korean,
            seto_core::Language::English => Self::English,
        }
    }
}
impl From<Language> for seto_core::Language {
    fn from(value: Language) -> Self {
        match value {
            Language::Korean => Self::Korean,
            Language::English => Self::English,
        }
    }
}

/// Every span is a count of UTF-16 code units, never bytes or Unicode scalars.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum FieldEdit {
    None,
    Unmark { text: String },
    Insert { text: String },
    Mark { text: String },
    ReplaceBeforeCaret { utf16: u64, text: String },
    InsertThenMark { insert: String, mark: String },
    InsertReplacing { utf16: u64, text: String },
    InsertReplacingThenMark { utf16: u64, insert: String, mark: String },
    ClearMarkThenInsert { utf16: u64, text: String },
    ClearMarkThenMark { utf16: u64, text: String },
    Rewrite { utf16: u64, text: String, then_mark: String },
}
impl From<seto_core::FieldEdit> for FieldEdit {
    fn from(value: seto_core::FieldEdit) -> Self {
        use seto_core::FieldEdit as C;
        match value {
            C::None => Self::None,
            C::Unmark { text } => Self::Unmark { text },
            C::Insert { text } => Self::Insert { text },
            C::Mark { text } => Self::Mark { text },
            C::ReplaceBeforeCaret { utf16, text } => Self::ReplaceBeforeCaret { utf16: utf16 as u64, text },
            C::InsertThenMark { insert, mark } => Self::InsertThenMark { insert, mark },
            C::InsertReplacing { utf16, text } => Self::InsertReplacing { utf16: utf16 as u64, text },
            C::InsertReplacingThenMark { utf16, insert, mark } => {
                Self::InsertReplacingThenMark { utf16: utf16 as u64, insert, mark }
            }
            C::ClearMarkThenInsert { utf16, text } => Self::ClearMarkThenInsert { utf16: utf16 as u64, text },
            C::ClearMarkThenMark { utf16, text } => Self::ClearMarkThenMark { utf16: utf16 as u64, text },
            C::Rewrite { utf16, text, then_mark } => Self::Rewrite { utf16: utf16 as u64, text, then_mark },
        }
    }
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct SessionUpdate {
    pub mode: Language,
    pub did_auto_convert: bool,
    pub preedit: String,
    pub field: FieldEdit,
}
impl From<seto_core::SessionUpdate> for SessionUpdate {
    fn from(value: seto_core::SessionUpdate) -> Self {
        Self {
            mode: value.mode.into(),
            did_auto_convert: value.did_auto_convert,
            preedit: value.preedit,
            field: value.field.into(),
        }
    }
}

#[uniffi::export(callback_interface)]
pub trait TypoLogger: Send + Sync {
    fn record(&self, wrong: String, wrong_keys: String, final_text: String, final_keys: String);
}
// Record into core memory while holding the session lock; invoke foreign code only after
// releasing it, so callbacks can safely inspect/re-enter the session.
#[derive(Default)]
struct CallbackMemory {
    memory: seto_core::MemoryTypos,
    pending: Mutex<Vec<seto_core::TypoRow>>,
}
impl TypoMemory for CallbackMemory {
    fn record(&self, wrong: &str, wrong_keys: &str, final_text: &str, final_keys: &str) {
        self.memory.record(wrong, wrong_keys, final_text, final_keys);
        self.pending.lock().unwrap().push(seto_core::TypoRow {
            wrong: wrong.into(),
            wrong_keys: wrong_keys.into(),
            final_text: final_text.into(),
            final_keys: final_keys.into(),
        });
    }
    fn unique_final(&self, wrong: &str) -> Option<String> {
        self.memory.unique_final(wrong)
    }
}
#[derive(uniffi::Object)]
pub struct FieldSession {
    session: Mutex<Option<Session>>,
    memory: Arc<CallbackMemory>,
    logger: Option<Box<dyn TypoLogger>>,
}
impl FieldSession {
    fn access<T>(&self, f: impl FnOnce(&mut Session) -> T) -> Result<T> {
        boundary(|| {
            let result = {
                let mut guard =
                    self.session.lock().map_err(|_| failure("Session poisoned; create a new field session"))?;
                let session = guard.as_mut().ok_or_else(|| failure("Session closed"))?;
                f(session)
            };
            let rows =
                std::mem::take(&mut *self.memory.pending.lock().map_err(|_| failure("Callback queue poisoned"))?);
            if let Some(logger) = &self.logger {
                for row in rows {
                    logger.record(row.wrong, row.wrong_keys, row.final_text, row.final_keys);
                }
            }
            Ok(result)
        })
    }
}
#[derive(uniffi::Record)]
pub struct SessionState {
    pub mode: Language,
    pub preedit: String,
    pub document: String,
    pub auto_switch: bool,
    pub corrects_typos: bool,
}
#[uniffi::export]
impl FieldSession {
    #[uniffi::constructor]
    pub fn new(logger: Option<Box<dyn TypoLogger>>) -> Result<Arc<Self>> {
        boundary(|| {
            let lexicon = LEXICON
                .lock()
                .map_err(|_| failure("Lexicon lock poisoned"))?
                .as_ref()
                .ok_or_else(|| failure("Load lexicon before creating a session"))?
                .1
                .clone();
            let memory = Arc::new(CallbackMemory::default());
            let session =
                Session::with_options(lexicon, SessionOptions { typos: Some(memory.clone()), ..Default::default() });
            Ok(Arc::new(Self { session: Mutex::new(Some(session)), memory, logger }))
        })
    }
    /// Explicitly release field state; Kotlin also releases the handle with destroy()/use.
    pub fn shutdown(&self) -> Result<()> {
        boundary(|| {
            self.session.lock().map_err(|_| failure("Session lock poisoned"))?.take();
            Ok(())
        })
    }
    pub fn input(&self, character: String) -> Result<SessionUpdate> {
        boundary(|| {
            let mut chars = character.chars();
            let ch = chars.next().ok_or_else(|| failure("Expected one Unicode scalar"))?;
            if chars.next().is_some() {
                return Err(failure("Expected one Unicode scalar"));
            }
            self.access(|s| s.input_char(ch).into())
        })
    }
    pub fn backspace(&self) -> Result<SessionUpdate> {
        self.access(|s| s.backspace().into())
    }
    pub fn toggle(&self) -> Result<SessionUpdate> {
        self.access(|s| s.toggle().into())
    }
    pub fn convert_open_word(&self) -> Result<SessionUpdate> {
        self.access(|s| s.convert_open_word().into())
    }
    pub fn commit_displayed(&self, ending_run: bool) -> Result<SessionUpdate> {
        self.access(|s| s.commit_displayed(ending_run).into())
    }
    pub fn discard(&self) -> Result<SessionUpdate> {
        self.access(|s| s.discard().into())
    }
    pub fn force_mode(&self, mode: Language) -> Result<SessionUpdate> {
        self.access(|s| s.force_mode(mode.into()).into())
    }
    pub fn set_options(&self, auto_switch: bool, corrects_typos: bool) -> Result<()> {
        self.access(|s| {
            s.auto_switch = auto_switch;
            s.corrects_typos = corrects_typos;
        })
    }
    pub fn state(&self) -> Result<SessionState> {
        self.access(|s| SessionState {
            mode: s.mode().into(),
            preedit: s.preedit().into(),
            document: s.document(),
            auto_switch: s.auto_switch,
            corrects_typos: s.corrects_typos,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn session() -> FieldSession {
        FieldSession {
            session: Mutex::new(Some(Session::new(Arc::new(Lexicon::new(&["hello"], &["안녕"]))))),
            memory: Arc::new(CallbackMemory::default()),
            logger: None,
        }
    }
    struct Logger(Arc<Mutex<Vec<(String, String, String, String)>>>);
    impl TypoLogger for Logger {
        fn record(&self, wrong: String, wrong_keys: String, final_text: String, final_keys: String) {
            self.0.lock().unwrap().push((wrong, wrong_keys, final_text, final_keys));
        }
    }
    #[test]
    fn process_lexicon_lifecycle_and_callback() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let paths = LexiconPaths {
            english: root.join("iOS/Keyboard/Resources/keyboard-english.txt").to_string_lossy().into(),
            korean_words: root.join("Resources/korean-words.txt").to_string_lossy().into(),
            korean_valid: root.join("iOS/Keyboard/Resources/keyboard-korean-valid.txt").to_string_lossy().into(),
        };
        load_lexicon(paths.clone()).unwrap();
        load_lexicon(paths.clone()).unwrap();
        assert!(load_lexicon(LexiconPaths { english: "different".into(), ..paths }).is_err());
        let rows = Arc::new(Mutex::new(Vec::new()));
        let session = FieldSession::new(Some(Box::new(Logger(rows.clone())))).unwrap();
        session.force_mode(Language::English).unwrap();
        session.set_options(false, false).unwrap();
        for ch in "hellp".chars() {
            session.input(ch.to_string()).unwrap();
        }
        session.backspace().unwrap();
        session.input("o".into()).unwrap();
        session.input(" ".into()).unwrap();
        assert_eq!(*rows.lock().unwrap(), vec![("hellp".into(), "hellp".into(), "hello".into(), "hello".into())]);
        assert_eq!(session.state().unwrap().document, "hello ");
        session.shutdown().unwrap();
        assert!(session.state().is_err());
    }
    #[test]
    fn invalid_input_and_closed_handle_are_errors() {
        let s = session();
        assert!(s.input("".into()).is_err());
        assert!(s.input("ab".into()).is_err());
        s.input("𝄞".into()).unwrap();
        s.shutdown().unwrap();
        assert!(s.backspace().is_err());
    }
    #[test]
    fn panics_become_errors_and_poisoned_state_is_not_reused() {
        let s = session();
        assert!(s.access::<()>(|_| panic!("injected panic")).is_err());
        assert!(s.state().is_err());
    }
    #[test]
    fn utf16_spans_are_preserved() {
        for n in [0, 2, 11, usize::MAX] {
            assert_eq!(
                FieldEdit::from(seto_core::FieldEdit::Rewrite {
                    utf16: n, text: "𝄞".into(), then_mark: "한".into()
                }),
                FieldEdit::Rewrite { utf16: n as u64, text: "𝄞".into(), then_mark: "한".into() }
            );
        }
    }
}
