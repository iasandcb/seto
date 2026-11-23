//! `HKCU\Software\Seto\keyboardLayout`. Read when the TIP is created and
//! written when the language-bar menu selects a layout.

use seto_core::KeyboardLayout;
use windows_registry::CURRENT_USER;

use crate::layout_pref::{self, KEY_PATH, VALUE_NAME};

use super::log;

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
