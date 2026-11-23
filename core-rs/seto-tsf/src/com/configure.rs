//! Keyboard options. Settings obtains this with `CoCreateInstance` of the TIP
//! CLSID and `IID_ITfFnConfigure`, then calls `Show`.
//!
//! The dialog only writes `HKCU\Software\Seto\keyboardLayout`. The text service
//! that is already in the foreground app watches that key and switches layouts
//! on its own thread, so the user does not sign out.

use windows::Win32::Foundation::{HWND, LPARAM, WPARAM};
use windows::Win32::UI::Controls::{BST_CHECKED, CheckRadioButton, IsDlgButtonChecked};
use windows::Win32::UI::TextServices::{ITfFnConfigure, ITfFnConfigure_Impl, ITfFunction_Impl};
use windows::Win32::UI::WindowsAndMessaging::{
    DialogBoxIndirectParamW, EndDialog, WM_CLOSE, WM_COMMAND, WM_INITDIALOG,
};
use windows::core::{BSTR, GUID, implement};

use seto_core::KeyboardLayout;

use crate::layout_dialog::{self, IDCANCEL, IDOK};
use crate::layout_pref;

use super::{layout_store, log};

#[implement(ITfFnConfigure)]
pub(crate) struct Configure;

impl Configure {
    pub(crate) fn new() -> Self {
        super::lock_module();
        Self
    }
}

impl Drop for Configure {
    fn drop(&mut self) {
        super::unlock_module();
    }
}

impl ITfFnConfigure_Impl for Configure_Impl {
    fn Show(&self, hwndparent: HWND, _langid: u16, _rguidprofile: *const GUID) -> windows::core::Result<()> {
        super::guard("configure Show", || choose_and_save(hwndparent))
    }
}

impl ITfFunction_Impl for Configure_Impl {
    fn GetDisplayName(&self) -> windows::core::Result<BSTR> {
        super::catch_com("configure GetDisplayName", || Ok(BSTR::from("세토 자판")))
    }
}

pub(crate) fn choose_and_save(parent: HWND) -> windows::core::Result<()> {
    let current = layout_store::load();
    let Some(layout) = choose(parent, current)? else {
        log("configure cancelled");
        return Ok(());
    };
    layout_store::save(layout);
    log(&format!("configure saved {}", layout.raw_value()));
    Ok(())
}

fn choose(parent: HWND, current: KeyboardLayout) -> windows::core::Result<Option<KeyboardLayout>> {
    let bytes = layout_dialog::template();
    let mut words = vec![0u32; bytes.len().div_ceil(4)];
    let parent = if parent.is_invalid() { None } else { Some(parent) };
    let code = unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), words.as_mut_ptr().cast::<u8>(), bytes.len());
        DialogBoxIndirectParamW(
            Some(super::module_instance()),
            words.as_ptr().cast(),
            parent,
            Some(dialog_proc),
            LPARAM(layout_pref::dialog_id(current) as isize),
        )
    };
    if code < 0 {
        log(&format!("configure dialog failed: {}", unsafe { windows::Win32::Foundation::GetLastError().0 }));
        return Err(windows::Win32::Foundation::E_FAIL.into());
    }
    if code == 0 {
        return Ok(None);
    }
    Ok(layout_pref::from_dialog_id(u32::try_from(code).unwrap_or(0)))
}

unsafe extern "system" fn dialog_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> isize {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| dialog_message(hwnd, msg, wparam, lparam)));
    match result {
        Ok(value) => value,
        Err(_) => {
            log("panic in configure dialog");
            unsafe {
                let _ = EndDialog(hwnd, 0);
            }
            1
        }
    }
}

fn dialog_message(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> isize {
    if msg == WM_INITDIALOG {
        let base = layout_pref::DIALOG_ID_BASE as i32;
        let last = base + KeyboardLayout::ALL.len() as i32 - 1;
        unsafe {
            let _ = CheckRadioButton(hwnd, base, last, lparam.0 as i32);
        }
        return 1;
    }
    if msg == WM_CLOSE {
        unsafe {
            let _ = EndDialog(hwnd, 0);
        }
        return 1;
    }
    if msg == WM_COMMAND {
        let id = (wparam.0 & 0xFFFF) as i32;
        if id == i32::from(IDOK) {
            let chosen = checked_layout(hwnd).unwrap_or(0);
            unsafe {
                let _ = EndDialog(hwnd, chosen as isize);
            }
            return 1;
        }
        if id == i32::from(IDCANCEL) {
            unsafe {
                let _ = EndDialog(hwnd, 0);
            }
            return 1;
        }
    }
    0
}

fn checked_layout(hwnd: HWND) -> Option<u32> {
    let base = layout_pref::DIALOG_ID_BASE;
    (0..KeyboardLayout::ALL.len() as u32).find_map(|offset| {
        let id = base + offset;
        let state = unsafe { IsDlgButtonChecked(hwnd, id as i32) };
        (state == BST_CHECKED.0).then_some(id)
    })
}
