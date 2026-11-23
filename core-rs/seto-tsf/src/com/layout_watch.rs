//! Watch `HKCU\Software\Seto` so a layout chosen in Settings, which loads this
//! DLL in another process, reaches the text service that is already typing.
//!
//! The registry thread only posts to a message-only window created on the TIP
//! thread. Applying the layout touches the engine and the document, and both
//! stay on that thread.

use std::cell::RefCell;
use std::rc::{Rc, Weak};
use std::sync::atomic::{AtomicBool, Ordering};

use windows::Win32::Foundation::{CloseHandle, ERROR_SUCCESS, HANDLE, HWND, LPARAM, LRESULT, WAIT_OBJECT_0, WPARAM};
use windows::Win32::System::Registry::{
    HKEY, HKEY_CURRENT_USER, KEY_NOTIFY, KEY_QUERY_VALUE, REG_NOTIFY_CHANGE_LAST_SET, RegCloseKey,
    RegNotifyChangeKeyValue, RegOpenKeyExW,
};
use windows::Win32::System::Threading::{CreateEventW, INFINITE, SetEvent, WaitForMultipleObjects};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, GWLP_USERDATA, GetWindowLongPtrW, HWND_MESSAGE, PostMessageW,
    RegisterClassW, SetWindowLongPtrW, WINDOW_EX_STYLE, WINDOW_STYLE, WM_APP, WM_DESTROY, WNDCLASSW,
};
use windows::core::PCWSTR;

use super::log;
use super::service::{SharedTip, TipInner};

const CLASS_NAME: [u16; 11] = [
    b'S' as u16,
    b'e' as u16,
    b't' as u16,
    b'o' as u16,
    b'L' as u16,
    b'a' as u16,
    b'y' as u16,
    b'o' as u16,
    b'u' as u16,
    b't' as u16,
    0,
];

pub(crate) struct LayoutWatch {
    stop: HANDLE,
    hwnd: HWND,
    thread: Option<std::thread::JoinHandle<()>>,
}

pub(crate) fn ensure(slot: &SharedTip) {
    if slot.borrow().layout_watch.is_some() {
        return;
    }
    let Some(watch) = start(slot) else {
        return;
    };
    slot.borrow_mut().layout_watch = Some(watch);
}

pub(crate) fn stop(mut watch: LayoutWatch) {
    unsafe {
        let _ = SetEvent(watch.stop);
    }
    if let Some(thread) = watch.thread.take() {
        let _ = thread.join();
    }
    if !watch.hwnd.is_invalid() {
        unsafe {
            let _ = DestroyWindow(watch.hwnd);
        }
    }
    unsafe {
        let _ = CloseHandle(watch.stop);
    }
}

fn start(slot: &SharedTip) -> Option<LayoutWatch> {
    super::layout_store::ensure();
    let hwnd = watch_window(slot)?;
    let stop = match unsafe { CreateEventW(None, true, false, PCWSTR::null()) } {
        Ok(stop) => stop,
        Err(error) => {
            log(&format!("layout watch stop: {error}"));
            unsafe {
                let _ = DestroyWindow(hwnd);
            }
            return None;
        }
    };
    let changed = match unsafe { CreateEventW(None, false, false, PCWSTR::null()) } {
        Ok(changed) => changed,
        Err(error) => {
            log(&format!("layout watch event: {error}"));
            unsafe {
                let _ = DestroyWindow(hwnd);
                let _ = CloseHandle(stop);
            }
            return None;
        }
    };
    let Some(key) = open_seto_key() else {
        unsafe {
            let _ = DestroyWindow(hwnd);
            let _ = CloseHandle(stop);
            let _ = CloseHandle(changed);
        }
        return None;
    };
    let armed = unsafe { RegNotifyChangeKeyValue(key, false, REG_NOTIFY_CHANGE_LAST_SET, Some(changed), true) };
    if armed != ERROR_SUCCESS {
        log(&format!("layout watch failed: {armed:?}"));
        unsafe {
            let _ = RegCloseKey(key);
            let _ = DestroyWindow(hwnd);
            let _ = CloseHandle(stop);
            let _ = CloseHandle(changed);
        }
        return None;
    }
    let hwnd_bits = hwnd.0 as usize;
    let key_bits = key.0 as usize;
    let changed_bits = changed.0 as usize;
    let stop_bits = stop.0 as usize;
    let thread = std::thread::spawn(move || {
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            watch_loop(
                HWND(hwnd_bits as *mut _),
                HKEY(key_bits as *mut _),
                HANDLE(changed_bits as *mut _),
                HANDLE(stop_bits as *mut _),
            );
        }));
    });
    Some(LayoutWatch { stop, hwnd, thread: Some(thread) })
}

fn watch_loop(hwnd: HWND, key: HKEY, changed: HANDLE, stop: HANDLE) {
    loop {
        let status = unsafe { WaitForMultipleObjects(&[changed, stop], false, INFINITE) };
        if status != WAIT_OBJECT_0 {
            break;
        }
        unsafe {
            let _ = PostMessageW(Some(hwnd), WM_APP, WPARAM(0), LPARAM(0));
        }
        let armed = unsafe { RegNotifyChangeKeyValue(key, false, REG_NOTIFY_CHANGE_LAST_SET, Some(changed), true) };
        if armed != ERROR_SUCCESS {
            log(&format!("layout watch rearm failed: {armed:?}"));
            break;
        }
    }
    unsafe {
        let _ = RegCloseKey(key);
        let _ = CloseHandle(changed);
    }
}

fn watch_window(slot: &SharedTip) -> Option<HWND> {
    ensure_class();
    let hwnd = unsafe {
        CreateWindowExW(
            WINDOW_EX_STYLE(0),
            PCWSTR(CLASS_NAME.as_ptr()),
            PCWSTR::null(),
            WINDOW_STYLE(0),
            0,
            0,
            0,
            0,
            Some(HWND_MESSAGE),
            None,
            Some(super::module_instance()),
            None,
        )
        .ok()?
    };
    let boxed = Box::into_raw(Box::new(Rc::downgrade(slot)));
    unsafe {
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, boxed as isize);
    }
    Some(hwnd)
}

fn ensure_class() {
    static READY: AtomicBool = AtomicBool::new(false);
    if READY.swap(true, Ordering::AcqRel) {
        return;
    }
    let class = WNDCLASSW {
        lpfnWndProc: Some(watch_wndproc),
        hInstance: super::module_instance(),
        lpszClassName: PCWSTR(CLASS_NAME.as_ptr()),
        ..WNDCLASSW::default()
    };
    if unsafe { RegisterClassW(&class) } == 0 {
        READY.store(false, Ordering::Release);
        log("layout watch window class was not registered");
    }
}

unsafe extern "system" fn watch_wndproc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        if msg == WM_APP {
            apply_posted(hwnd);
        } else if msg == WM_DESTROY {
            let raw = unsafe { GetWindowLongPtrW(hwnd, GWLP_USERDATA) };
            if raw != 0 {
                unsafe {
                    SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
                    drop(Box::from_raw(raw as *mut Weak<RefCell<TipInner>>));
                }
            }
        }
    }));
    unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
}

fn apply_posted(hwnd: HWND) {
    let raw = unsafe { GetWindowLongPtrW(hwnd, GWLP_USERDATA) };
    if raw == 0 {
        return;
    }
    let weak = unsafe { &*(raw as *const Weak<RefCell<TipInner>>) };
    let Some(slot) = weak.upgrade() else {
        return;
    };
    super::indicator::reload_layout(&slot);
}

fn open_seto_key() -> Option<HKEY> {
    let mut subkey: Vec<u16> = crate::layout_pref::KEY_PATH.encode_utf16().collect();
    subkey.push(0);
    let mut key = HKEY::default();
    let status = unsafe {
        RegOpenKeyExW(HKEY_CURRENT_USER, PCWSTR(subkey.as_ptr()), None, KEY_QUERY_VALUE | KEY_NOTIFY, &mut key)
    };
    if status != ERROR_SUCCESS {
        log(&format!("layout watch key: {status:?}"));
        return None;
    }
    Some(key)
}
