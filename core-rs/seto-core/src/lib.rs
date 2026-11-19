//! Shared core of Seto, a Sebeolsik 390 input method with Korean/English
//! auto-switching.
//!
//! A port of `Sources/SetoCore` (the Swift oracle): Hangul jamo, the
//! composer, the 390 / 최종 / 두벌식 layouts and key maps, the lexicon, the
//! Shift+Space tracker, and (phase 2) [`Session`] with [`TypoCorrector`] and
//! the typo memory it logs to. [`golden`] describes the corpus recorded from
//! the Swift `Session`; `tests/golden_replay.rs` replays it against this one.

pub mod composer;
pub mod golden;
pub mod hangul;
pub mod keys;
pub mod layout;
pub mod lexicon;
pub mod session;
pub mod session_types;
pub mod typo_corrector;
pub mod typo_log;

pub use composer::{Composition, CompositionPiece, compose, jamo_sequence, preserves_boundary};
pub use hangul::{Jamo, JamoKind};
pub use keys::hardware_keymap::{self, HardwareKeyAction, Modifiers};
pub use keys::{KeyboardReplacement, ShiftSpaceToggleTracker, keymap};
pub use layout::{KeyAtom, KeyOutput, KeyboardLayout, dubeol, final_layout, layout390};
pub use lexicon::{Lexicon, LexiconWords, WordList};
pub use session::{InputGate, Session, SessionOptions};
pub use session_types::{FieldEdit, Language, SessionUpdate, utf16_len};
pub use typo_corrector::{TypoCorrector, korean_endings, korean_verb_endings};
pub use typo_log::{MemoryTypos, TypoLogPolicy, TypoMemory, TypoRow};
