//! Shared core of Seto, a Sebeolsik 390 input method with Korean/English
//! auto-switching.
//!
//! Phase 1 ports the pure pieces of `Sources/SetoCore` (the Swift oracle):
//! Hangul jamo, the composer, the 390 / 최종 / 두벌식 layouts and key maps,
//! the lexicon, and the Shift+Space tracker. `Session` and `TypoCorrector`
//! come later; [`golden`] describes the corpus recorded from the Swift
//! `Session` that a Rust port must reproduce.

pub mod composer;
pub mod golden;
pub mod hangul;
pub mod keys;
pub mod layout;
pub mod lexicon;
pub mod session_types;

pub use composer::{Composition, CompositionPiece, compose, jamo_sequence, preserves_boundary};
pub use hangul::{Jamo, JamoKind};
pub use keys::hardware_keymap::{self, HardwareKeyAction, Modifiers};
pub use keys::{KeyboardReplacement, ShiftSpaceToggleTracker, keymap};
pub use layout::{KeyAtom, KeyOutput, KeyboardLayout, dubeol, final_layout, layout390};
pub use lexicon::{Lexicon, LexiconWords, WordList};
pub use session_types::{FieldEdit, Language, SessionUpdate, utf16_len};
