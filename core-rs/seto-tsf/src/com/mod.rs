//! TSF COM server. Built only for Windows; the key driver it calls is in the
//! parent module and is tested on every OS.
//!
//! Edits go through an asynchronous read/write edit session. A synchronous
//! session faults `textinputframework.dll` in Windows 11 Notepad and other
//! immersive hosts, so the document update is queued and the key decision
//! itself stays on the engine before we return from the sink.

#![allow(non_snake_case)]

mod display;
mod edit;
mod factory;
mod registry;
mod service;

use core::ffi::c_void;
use core::sync::atomic::{AtomicIsize, AtomicPtr, Ordering};

use windows::Win32::Foundation::{CLASS_E_CLASSNOTAVAILABLE, E_FAIL, HINSTANCE, HMODULE, S_FALSE, S_OK};
use windows::Win32::System::Com::IClassFactory;
use windows::Win32::System::LibraryLoader::GetModuleFileNameW;
use windows::Win32::System::SystemServices::DLL_PROCESS_ATTACH;
use windows::core::{BOOL, GUID, HRESULT, Interface};

/// Text service CLSID. InprocServer32, the profile, and `DllGetClassObject` share it.
pub(crate) const CLSID_SETO: GUID = GUID::from_u128(0x8f3c1e90_390b_4a6e_b7d2_5e70a11e0001);
pub(crate) const CLSID_SETO_STR: &str = "{8F3C1E90-390B-4A6E-B7D2-5E70A11E0001}";
/// Language profile under ko-KR.
pub(crate) const GUID_PROFILE: GUID = GUID::from_u128(0x8f3c1e90_390b_4a6e_b7d2_5e70a11e0002);
/// Underline attribute for the open syllable.
pub(crate) const GUID_DISPLAY_ATTRIBUTE: GUID = GUID::from_u128(0x8f3c1e90_390b_4a6e_b7d2_5e70a11e0003);
/// `MAKELANGID(LANG_KOREAN, SUBLANG_KOREAN)`.
pub(crate) const LANGID_KO_KR: u16 = 0x0412;
pub(crate) const SERVICE_NAME: &str = "세토";

static DLL_REFERENCES: AtomicIsize = AtomicIsize::new(0);
static DLL_MODULE: AtomicPtr<c_void> = AtomicPtr::new(core::ptr::null_mut());

pub(crate) fn lock_module() {
    DLL_REFERENCES.fetch_add(1, Ordering::SeqCst);
}

pub(crate) fn unlock_module() {
    DLL_REFERENCES.fetch_sub(1, Ordering::SeqCst);
}

pub(crate) fn module_path() -> Option<std::path::PathBuf> {
    let module = HMODULE(DLL_MODULE.load(Ordering::SeqCst));
    let mut buf = [0u16; 1024];
    let len = unsafe { GetModuleFileNameW(Some(module), &mut buf) } as usize;
    if len == 0 || len >= buf.len() {
        return None;
    }
    Some(std::path::PathBuf::from(String::from_utf16_lossy(&buf[..len])))
}

pub(crate) fn log(message: &str) {
    let Some(dir) = std::env::var_os("LOCALAPPDATA") else {
        return;
    };
    let path = std::path::PathBuf::from(dir).join("Seto").join("seto-tsf.log");
    let _ = std::fs::create_dir_all(path.parent().unwrap_or(std::path::Path::new(".")));
    let line = format!("{message}\r\n");
    let _ = std::fs::OpenOptions::new().create(true).append(true).open(path).and_then(|mut file| {
        use std::io::Write;
        file.write_all(line.as_bytes())
    });
}

#[unsafe(no_mangle)]
extern "system" fn DllGetClassObject(rclsid: *const GUID, riid: *const GUID, ppv: *mut *mut c_void) -> HRESULT {
    if rclsid.is_null() || riid.is_null() || ppv.is_null() {
        return E_FAIL;
    }
    unsafe { *ppv = core::ptr::null_mut() };
    if unsafe { *rclsid } != CLSID_SETO {
        return CLASS_E_CLASSNOTAVAILABLE;
    }
    let factory: IClassFactory = factory::ClassFactory::new().into();
    unsafe { factory.query(riid, ppv) }
}

#[unsafe(no_mangle)]
extern "system" fn DllCanUnloadNow() -> HRESULT {
    if DLL_REFERENCES.load(Ordering::SeqCst) == 0 { S_OK } else { S_FALSE }
}

#[unsafe(no_mangle)]
extern "system" fn DllRegisterServer() -> HRESULT {
    match registry::register() {
        Ok(()) => S_OK,
        Err(error) => {
            log(&format!("DllRegisterServer failed: {error}"));
            error.code()
        }
    }
}

#[unsafe(no_mangle)]
extern "system" fn DllUnregisterServer() -> HRESULT {
    match registry::unregister() {
        Ok(()) => S_OK,
        Err(error) => {
            log(&format!("DllUnregisterServer failed: {error}"));
            error.code()
        }
    }
}

#[unsafe(no_mangle)]
extern "system" fn DllMain(hinst: HINSTANCE, reason: u32, _reserved: *mut c_void) -> BOOL {
    if reason == DLL_PROCESS_ATTACH {
        DLL_MODULE.store(hinst.0, Ordering::SeqCst);
    }
    true.into()
}
