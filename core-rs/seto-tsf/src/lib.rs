//! Windows text service for Seto.
//!
//! The key-to-session driver ([`keys`], [`engine`], [`apply`]) is plain Rust
//! and is what `cargo test` exercises on every OS. The TSF COM server in
//! [`com`] is compiled only for Windows.

mod apply;
mod engine;
mod keys;
mod lexicon_path;
mod tray;

#[cfg(windows)]
mod com;

pub use apply::{Document, EditPlan, plan_edit};
pub use engine::{Engine, KeyEffect};
pub use keys::{DecisionState, DownClass, UpClass, WinKey};
pub use lexicon_path::lexicon_directories;
pub use tray::snap_tray_icon_px;
