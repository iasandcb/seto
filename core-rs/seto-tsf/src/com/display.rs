//! Composition underline. The text service enumerates one input attribute and
//! the edit session writes its GUID atom onto `GUID_PROP_ATTRIBUTE`.

use core::cell::Cell;
use core::sync::atomic::{AtomicU32, Ordering};

use windows::Win32::Foundation::{E_INVALIDARG, E_POINTER, S_FALSE};
use windows::Win32::System::Com::{CLSCTX_INPROC_SERVER, CoCreateInstance};
use windows::Win32::System::Variant::VARIANT;
use windows::Win32::UI::TextServices::{
    CLSID_TF_CategoryMgr, GUID_PROP_ATTRIBUTE, IEnumTfDisplayAttributeInfo, IEnumTfDisplayAttributeInfo_Impl,
    ITfCategoryMgr, ITfContext, ITfDisplayAttributeInfo, ITfDisplayAttributeInfo_Impl, ITfRange, TF_ATTR_INPUT,
    TF_CT_NONE, TF_DA_COLOR, TF_DISPLAYATTRIBUTE, TF_LS_SOLID,
};
use windows::core::{BSTR, Error, GUID, Result, implement};

use super::GUID_DISPLAY_ATTRIBUTE;

static ATOM: AtomicU32 = AtomicU32::new(0);

fn input_attribute() -> TF_DISPLAYATTRIBUTE {
    let follow = TF_DA_COLOR { r#type: TF_CT_NONE, ..TF_DA_COLOR::default() };
    TF_DISPLAYATTRIBUTE {
        crText: follow,
        crBk: follow,
        lsStyle: TF_LS_SOLID,
        fBoldLine: false.into(),
        crLine: follow,
        bAttr: TF_ATTR_INPUT,
    }
}

pub(crate) fn mark(context: &ITfContext, ec: u32, range: &ITfRange) {
    if let Err(error) = mark_inner(context, ec, range) {
        super::log(&format!("display attribute failed: {error}"));
    }
}

fn mark_inner(context: &ITfContext, ec: u32, range: &ITfRange) -> Result<()> {
    let atom = guid_atom()?;
    let variant = VARIANT::from(atom as i32);
    let property = unsafe { context.GetProperty(&GUID_PROP_ATTRIBUTE)? };
    unsafe { property.SetValue(ec, range, &variant) }
}

fn guid_atom() -> Result<u32> {
    let cached = ATOM.load(Ordering::Relaxed);
    if cached != 0 {
        return Ok(cached);
    }
    let manager: ITfCategoryMgr = unsafe { CoCreateInstance(&CLSID_TF_CategoryMgr, None, CLSCTX_INPROC_SERVER)? };
    let atom = unsafe { manager.RegisterGUID(&GUID_DISPLAY_ATTRIBUTE)? };
    ATOM.store(atom, Ordering::Relaxed);
    Ok(atom)
}

pub(crate) fn enumerator() -> IEnumTfDisplayAttributeInfo {
    AttributeEnum { done: Cell::new(false) }.into()
}

pub(crate) fn info_for(guid: *const GUID) -> Result<ITfDisplayAttributeInfo> {
    if guid.is_null() || unsafe { *guid } != GUID_DISPLAY_ATTRIBUTE {
        return Err(E_INVALIDARG.into());
    }
    Ok(AttributeInfo.into())
}

#[implement(ITfDisplayAttributeInfo)]
struct AttributeInfo;

impl ITfDisplayAttributeInfo_Impl for AttributeInfo_Impl {
    fn GetGUID(&self) -> Result<GUID> {
        Ok(GUID_DISPLAY_ATTRIBUTE)
    }

    fn GetDescription(&self) -> Result<BSTR> {
        Ok(BSTR::from("세토 조합"))
    }

    fn GetAttributeInfo(&self, pda: *mut TF_DISPLAYATTRIBUTE) -> Result<()> {
        if pda.is_null() {
            return Err(E_POINTER.into());
        }
        unsafe { pda.write(input_attribute()) };
        Ok(())
    }

    fn SetAttributeInfo(&self, _pda: *const TF_DISPLAYATTRIBUTE) -> Result<()> {
        Ok(())
    }

    fn Reset(&self) -> Result<()> {
        Ok(())
    }
}

#[implement(IEnumTfDisplayAttributeInfo)]
struct AttributeEnum {
    done: Cell<bool>,
}

impl IEnumTfDisplayAttributeInfo_Impl for AttributeEnum_Impl {
    fn Clone(&self) -> Result<IEnumTfDisplayAttributeInfo> {
        Ok(AttributeEnum { done: Cell::new(self.done.get()) }.into())
    }

    fn Next(&self, ulcount: u32, rginfo: *mut Option<ITfDisplayAttributeInfo>, pcfetched: *mut u32) -> Result<()> {
        if ulcount > 0 && rginfo.is_null() {
            return Err(E_POINTER.into());
        }
        let mut fetched = 0u32;
        if ulcount >= 1 && !self.done.get() {
            unsafe { rginfo.write(Some(AttributeInfo.into())) };
            self.done.set(true);
            fetched = 1;
        }
        if !pcfetched.is_null() {
            unsafe { *pcfetched = fetched };
        }
        if fetched == ulcount { Ok(()) } else { Err(Error::from(S_FALSE)) }
    }

    fn Reset(&self) -> Result<()> {
        self.done.set(false);
        Ok(())
    }

    fn Skip(&self, ulcount: u32) -> Result<()> {
        if ulcount >= 1 {
            self.done.set(true);
        }
        Ok(())
    }
}
