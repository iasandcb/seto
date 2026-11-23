//! `HKCU\Software\Seto\keyboardLayout`. Read when the TIP is created and
//! written when keyboard options or the indicator menu selects a layout.
//! A running TIP watches the key and applies the new layout itself.

use seto_core::KeyboardLayout;
use windows_registry::CURRENT_USER;

use crate::layout_pref::{self, KEY_PATH, VALUE_NAME};

use super::log;

/// Create the key so a watch can arm before the first saved layout.
pub(crate) fn ensure() {
    if let Err(error) = CURRENT_USER.create(KEY_PATH) {
        log(&format!("layout key: {error}"));
    }
}

pub(crate) fn load() -> KeyboardLayout {
    let raw = CURRENT_USER.open(KEY_PATH).ok().and_then(|key| key.get_string(VALUE_NAME).ok());
    layout_pref::parse(raw.as_deref())
}

pub(crate) fn save(layout: KeyboardLayout) {
    match CURRENT_USER.create(KEY_PATH) {
        Ok(key) => {
            if let Err(error) = key.set_string(VALUE_NAME, layout.raw_value()) {
                log(&format!("layout save: {error}"));
            }
        }
        Err(error) => log(&format!("layout key: {error}")),
    }
}
