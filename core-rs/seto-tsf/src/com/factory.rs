use core::ffi::c_void;

use windows::Win32::Foundation::{CLASS_E_NOAGGREGATION, E_INVALIDARG};
use windows::Win32::System::Com::{IClassFactory, IClassFactory_Impl};
use windows::Win32::UI::TextServices::{ITfFnConfigure, ITfFunction};
use windows::core::{BOOL, GUID, IUnknown, Interface, Ref, Result, implement};

use super::configure::Configure;
use super::service::TextService;

#[implement(IClassFactory)]
pub(crate) struct ClassFactory;

impl ClassFactory {
    pub(crate) fn new() -> Self {
        super::lock_module();
        Self
    }
}

impl Drop for ClassFactory {
    fn drop(&mut self) {
        super::unlock_module();
    }
}

impl IClassFactory_Impl for ClassFactory_Impl {
    fn CreateInstance(&self, punkouter: Ref<IUnknown>, riid: *const GUID, ppvobject: *mut *mut c_void) -> Result<()> {
        if !punkouter.is_null() {
            return Err(CLASS_E_NOAGGREGATION.into());
        }
        if riid.is_null() || ppvobject.is_null() {
            return Err(E_INVALIDARG.into());
        }
        // Settings calls CoCreateInstance(CLSID, IID_ITfFnConfigure). A full
        // text service is not required to show the layout dialog.
        let iid = unsafe { *riid };
        if iid == ITfFnConfigure::IID || iid == ITfFunction::IID {
            let unknown: IUnknown = Configure::new().into();
            return unsafe { unknown.query(riid, ppvobject).ok() };
        }
        let unknown: IUnknown = TextService::new().into();
        unsafe { unknown.query(riid, ppvobject).ok() }
    }

    fn LockServer(&self, flock: BOOL) -> Result<()> {
        if flock.as_bool() {
            super::lock_module();
        } else {
            super::unlock_module();
        }
        Ok(())
    }
}
