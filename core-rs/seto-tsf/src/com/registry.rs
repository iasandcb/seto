//! Self-registration: COM InprocServer32 plus a ko-KR TSF profile named 세토.
//! `regsvr32` loads this from an elevated process so `HKEY_CLASSES_ROOT` is
//! the machine hive. The DLL file itself lives under `%LOCALAPPDATA%\Seto`.

use windows::Win32::System::Com::{
    CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED, CoCreateInstance, CoInitializeEx, CoUninitialize,
};
use windows::Win32::UI::Input::KeyboardAndMouse::HKL;
use windows::Win32::UI::TextServices::{
    CLSID_TF_CategoryMgr, CLSID_TF_InputProcessorProfiles, GUID_TFCAT_DISPLAYATTRIBUTEPROVIDER,
    GUID_TFCAT_TIP_KEYBOARD, GUID_TFCAT_TIPCAP_COMLESS, GUID_TFCAT_TIPCAP_IMMERSIVESUPPORT,
    GUID_TFCAT_TIPCAP_INPUTMODECOMPARTMENT, GUID_TFCAT_TIPCAP_SECUREMODE, GUID_TFCAT_TIPCAP_SYSTRAYSUPPORT,
    GUID_TFCAT_TIPCAP_UIELEMENTENABLED, ITfCategoryMgr, ITfInputProcessorProfileMgr, ITfInputProcessorProfiles,
    TF_E_ALREADY_EXISTS, TF_IPPMF_ENABLEPROFILE,
};
use windows::core::{GUID, Interface, Result};
use windows_registry::CLASSES_ROOT;

use super::{CLSID_SETO, CLSID_SETO_STR, GUID_PROFILE, LANGID_KO_KR, SERVICE_NAME};

/// Keyboard TIP plus the capability bits Windows 11's input switcher filters on,
/// and the display-attribute provider that draws the composition underline.
const CATEGORIES: &[GUID] = &[
    GUID_TFCAT_TIP_KEYBOARD,
    GUID_TFCAT_TIPCAP_IMMERSIVESUPPORT,
    GUID_TFCAT_TIPCAP_SYSTRAYSUPPORT,
    GUID_TFCAT_TIPCAP_UIELEMENTENABLED,
    GUID_TFCAT_TIPCAP_INPUTMODECOMPARTMENT,
    GUID_TFCAT_TIPCAP_SECUREMODE,
    GUID_TFCAT_TIPCAP_COMLESS,
    GUID_TFCAT_DISPLAYATTRIBUTEPROVIDER,
];

pub(crate) fn register() -> Result<()> {
    let module = super::module_path().ok_or_else(|| windows::core::Error::from(windows::Win32::Foundation::E_FAIL))?;
    let key = CLASSES_ROOT.create(format!("CLSID\\{CLSID_SETO_STR}")).map_err(reg_error)?;
    key.set_string("", SERVICE_NAME).map_err(reg_error)?;
    let inproc = key.create("InprocServer32").map_err(reg_error)?;
    inproc.set_string("", module.display().to_string()).map_err(reg_error)?;
    inproc.set_string("ThreadingModel", "Apartment").map_err(reg_error)?;
    register_profile()
}

pub(crate) fn unregister() -> Result<()> {
    let _ = unregister_profile();
    let _ = CLASSES_ROOT.remove_tree(format!("CLSID\\{CLSID_SETO_STR}"));
    Ok(())
}

fn register_profile() -> Result<()> {
    com_scope(|| {
        let profiles: ITfInputProcessorProfiles =
            unsafe { CoCreateInstance(&CLSID_TF_InputProcessorProfiles, None, CLSCTX_INPROC_SERVER)? };
        unsafe { profiles.Register(&CLSID_SETO)? };
        let manager: ITfInputProcessorProfileMgr = profiles.cast()?;
        let description: Vec<u16> = SERVICE_NAME.encode_utf16().collect();
        // Korean keyboard layout. The TIP substitutes it so the switcher lists 세토 under 한국어.
        let hkl = HKL(0x0412_0412usize as *mut core::ffi::c_void);
        let registered = unsafe {
            manager.RegisterProfile(
                &CLSID_SETO,
                LANGID_KO_KR,
                &GUID_PROFILE,
                &description,
                &[],
                0,
                hkl,
                0,
                true,
                TF_IPPMF_ENABLEPROFILE,
            )
        };
        if let Err(error) = registered {
            if error.code() != TF_E_ALREADY_EXISTS {
                return Err(error);
            }
        }
        unsafe { profiles.EnableLanguageProfile(&CLSID_SETO, LANGID_KO_KR, &GUID_PROFILE, true)? };
        let _ = unsafe { profiles.EnableLanguageProfileByDefault(&CLSID_SETO, LANGID_KO_KR, &GUID_PROFILE, true) };
        let category: ITfCategoryMgr = unsafe { CoCreateInstance(&CLSID_TF_CategoryMgr, None, CLSCTX_INPROC_SERVER)? };
        for catid in CATEGORIES {
            unsafe { category.RegisterCategory(&CLSID_SETO, catid, &CLSID_SETO)? };
        }
        Ok(())
    })
}

fn unregister_profile() -> Result<()> {
    com_scope(|| {
        if let Ok(category) =
            unsafe { CoCreateInstance::<_, ITfCategoryMgr>(&CLSID_TF_CategoryMgr, None, CLSCTX_INPROC_SERVER) }
        {
            for catid in CATEGORIES {
                let _ = unsafe { category.UnregisterCategory(&CLSID_SETO, catid, &CLSID_SETO) };
            }
        }
        if let Ok(profiles) = unsafe {
            CoCreateInstance::<_, ITfInputProcessorProfiles>(
                &CLSID_TF_InputProcessorProfiles,
                None,
                CLSCTX_INPROC_SERVER,
            )
        } {
            let _ = unsafe { profiles.RemoveLanguageProfile(&CLSID_SETO, LANGID_KO_KR, &GUID_PROFILE) };
            if let Ok(manager) = profiles.cast::<ITfInputProcessorProfileMgr>() {
                let _ = unsafe { manager.UnregisterProfile(&CLSID_SETO, LANGID_KO_KR, &GUID_PROFILE, 0) };
            }
            let _ = unsafe { profiles.Unregister(&CLSID_SETO) };
        }
        Ok(())
    })
}

fn com_scope<T>(body: impl FnOnce() -> Result<T>) -> Result<T> {
    let initialized = unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED) }.is_ok();
    let result = body();
    if initialized {
        unsafe { CoUninitialize() };
    }
    result
}

fn reg_error(error: impl core::fmt::Display) -> windows::core::Error {
    windows::core::Error::new(windows::Win32::Foundation::E_FAIL, error.to_string())
}
