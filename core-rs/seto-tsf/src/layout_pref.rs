#![cfg_attr(not(windows), allow(dead_code))]

//! Persisted Korean layout for the Windows TIP.
//!
//! The strings are [`KeyboardLayout::raw_value`](seto_core::KeyboardLayout::raw_value),
//! the same tokens macOS stores under UserDefaults `keyboardLayout`.
//! A missing or unknown value stays 세벌식 390.

use seto_core::KeyboardLayout;

/// `HKCU\Software\Seto`.
pub const KEY_PATH: &str = r"Software\Seto";
/// `REG_SZ`. `sebeol390`, `dubeol`, or `sebeolFinal`.
pub const VALUE_NAME: &str = "keyboardLayout";

pub fn parse(raw: Option<&str>) -> KeyboardLayout {
    raw.map(str::trim).filter(|value| !value.is_empty()).and_then(KeyboardLayout::from_raw_value).unwrap_or_default()
}

/// Menu ids follow [`KeyboardLayout::ALL`](seto_core::KeyboardLayout::ALL).
pub fn menu_id(layout: KeyboardLayout) -> u32 {
    KeyboardLayout::ALL.iter().position(|item| *item == layout).unwrap_or(0) as u32
}

pub fn from_menu_id(id: u32) -> Option<KeyboardLayout> {
    KeyboardLayout::ALL.get(id as usize).copied()
}

/// Control ids for the keyboard-options dialog and the indicator popup.
/// `0` stays free so a dismissed popup is not 세벌식 390.
pub const DIALOG_ID_BASE: u32 = 100;

pub fn dialog_id(layout: KeyboardLayout) -> u32 {
    menu_id(layout) + DIALOG_ID_BASE
}

pub fn from_dialog_id(id: u32) -> Option<KeyboardLayout> {
    id.checked_sub(DIALOG_ID_BASE).and_then(from_menu_id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_or_unknown_values_stay_390() {
        assert_eq!(parse(None), KeyboardLayout::Sebeol390);
        assert_eq!(parse(Some("")), KeyboardLayout::Sebeol390);
        assert_eq!(parse(Some("  ")), KeyboardLayout::Sebeol390);
        assert_eq!(parse(Some("Dubeol")), KeyboardLayout::Sebeol390);
        assert_eq!(parse(Some("sebeol")), KeyboardLayout::Sebeol390);
    }

    #[test]
    fn raw_values_round_trip_through_the_menu_ids() {
        for layout in KeyboardLayout::ALL {
            assert_eq!(parse(Some(layout.raw_value())), layout);
            assert_eq!(parse(Some(&format!("  {}  ", layout.raw_value()))), layout);
            assert_eq!(from_menu_id(menu_id(layout)), Some(layout));
        }
        assert_eq!(menu_id(KeyboardLayout::Sebeol390), 0);
        assert_eq!(menu_id(KeyboardLayout::Dubeol), 1);
        assert_eq!(menu_id(KeyboardLayout::SebeolFinal), 2);
        assert_eq!(from_menu_id(3), None);
        assert_eq!(from_menu_id(u32::MAX), None);
    }

    #[test]
    fn dialog_ids_are_the_menu_ids_shifted_off_zero() {
        for layout in KeyboardLayout::ALL {
            assert_eq!(from_dialog_id(dialog_id(layout)), Some(layout));
        }
        assert_eq!(dialog_id(KeyboardLayout::Sebeol390), 100);
        assert_eq!(dialog_id(KeyboardLayout::Dubeol), 101);
        assert_eq!(dialog_id(KeyboardLayout::SebeolFinal), 102);
        assert_eq!(from_dialog_id(0), None);
        assert_eq!(from_dialog_id(99), None);
        assert_eq!(from_dialog_id(103), None);
    }
}
