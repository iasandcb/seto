//! Windows 11 input indicator. Hangul shows `가` and English shows `A`.
//!
//! The taskbar reads `GUID_COMPARTMENT_KEYBOARD_INPUTMODE_CONVERSION`
//! (`TF_CONVERSIONMODE_NATIVE` for Hangul) and `GUID_COMPARTMENT_KEYBOARD_OPENCLOSE`.
//! The language-bar button `GUID_LBI_INPUTMODE` is the click target and the
//! fallback glyph. Both are updated together.
//!
//! Compartment writes notify sinks on this thread. `updating_mode` is set
//! before any of those calls and the `RefCell` is not held across them, so a
//! sink cannot re-enter `toggle` or panic on a nested borrow.

use std::cell::RefCell;
use std::rc::{Rc, Weak};

use windows::Win32::Foundation::{COLORREF, E_FAIL, E_NOINTERFACE, E_POINTER, POINT, RECT};
use windows::Win32::Graphics::Gdi::{
    CLEARTYPE_QUALITY, CLIP_DEFAULT_PRECIS, CreateBitmap, CreateCompatibleBitmap, CreateCompatibleDC, CreateFontW,
    DeleteDC, DeleteObject, GetDC, HANGUL_CHARSET, HBITMAP, HDC, HGDIOBJ, OUT_DEFAULT_PRECIS, PatBlt, ReleaseDC,
    SelectObject, SetBkMode, SetTextColor, TRANSPARENT, TextOutW, WHITENESS,
};
use windows::Win32::System::Variant::{VARIANT, VT_EMPTY, VT_I4, VT_INT, VT_UI4, VariantClear};
use windows::Win32::UI::TextServices::{
    GUID_COMPARTMENT_KEYBOARD_INPUTMODE_CONVERSION, GUID_COMPARTMENT_KEYBOARD_OPENCLOSE, GUID_LBI_INPUTMODE,
    ITfCompartmentEventSink, ITfCompartmentEventSink_Impl, ITfCompartmentMgr, ITfContext, ITfLangBarItem,
    ITfLangBarItem_Impl, ITfLangBarItemButton, ITfLangBarItemButton_Impl, ITfLangBarItemMgr, ITfLangBarItemSink,
    ITfSource, ITfSource_Impl, ITfThreadMgr, TF_CONVERSIONMODE_ALPHANUMERIC, TF_CONVERSIONMODE_NATIVE,
    TF_LANGBARITEMINFO, TF_LBI_CLK_RIGHT, TF_LBI_ICON, TF_LBI_STATUS, TF_LBI_STATUS_BTN_TOGGLED, TF_LBI_STATUS_HIDDEN,
    TF_LBI_STYLE_BTN_BUTTON, TF_LBI_STYLE_SHOWNINTRAY, TF_LBI_STYLE_TEXTCOLORICON, TF_LBI_TEXT, TF_LBI_TOOLTIP,
    TfLBIClick,
};
use windows::Win32::UI::WindowsAndMessaging::{HICON, ICONINFO};
use windows::core::{BOOL, BSTR, Error, GUID, IUnknown, Interface, PCWSTR, Ref, Result, implement};

use seto_core::Language;

use crate::engine::{KeyEffect, conversion_native, indicator_label};

use super::service::{self, SharedTip, TipInner};
use super::{CLSID_SETO, log};

const SINK_COOKIE: u32 = 0x390B;
const _: () = assert!(TF_CONVERSIONMODE_NATIVE == 1);
const _: () = assert!(TF_CONVERSIONMODE_ALPHANUMERIC == 0);

#[implement(ITfLangBarItemButton, ITfSource, ITfCompartmentEventSink)]
pub(crate) struct ModeButton {
    slot: Weak<RefCell<TipInner>>,
}

impl ModeButton {
    pub(crate) fn new(slot: Weak<RefCell<TipInner>>) -> Self {
        super::lock_module();
        Self { slot }
    }

    fn label(&self) -> &'static str {
        let Some(slot) = self.slot.upgrade() else {
            return "A";
        };
        let mode = slot.borrow().engine.mode();
        indicator_label(mode)
    }
}

impl Drop for ModeButton {
    fn drop(&mut self) {
        super::unlock_module();
    }
}

impl ITfLangBarItem_Impl for ModeButton_Impl {
    fn GetInfo(&self, pinfo: *mut TF_LANGBARITEMINFO) -> Result<()> {
        super::catch_com("indicator GetInfo", || {
            if pinfo.is_null() {
                return Err(E_POINTER.into());
            }
            let mut info = TF_LANGBARITEMINFO {
                clsidService: CLSID_SETO,
                guidItem: GUID_LBI_INPUTMODE,
                dwStyle: TF_LBI_STYLE_BTN_BUTTON | TF_LBI_STYLE_SHOWNINTRAY | TF_LBI_STYLE_TEXTCOLORICON,
                ulSort: 0,
                szDescription: [0; 32],
            };
            for (index, unit) in "세토".encode_utf16().enumerate().take(31) {
                info.szDescription[index] = unit;
            }
            unsafe { pinfo.write(info) };
            Ok(())
        })
    }

    fn GetStatus(&self) -> Result<u32> {
        super::catch_com("indicator GetStatus", || {
            let Some(slot) = self.slot.upgrade() else {
                return Ok(TF_LBI_STATUS_HIDDEN);
            };
            let tip = slot.borrow();
            if !tip.indicator_shown {
                return Ok(TF_LBI_STATUS_HIDDEN);
            }
            let toggled = conversion_native(tip.engine.mode());
            Ok(if toggled { TF_LBI_STATUS_BTN_TOGGLED } else { 0 })
        })
    }

    fn Show(&self, fshow: BOOL) -> Result<()> {
        super::catch_com("indicator Show", || {
            let Some(slot) = self.slot.upgrade() else {
                return Ok(());
            };
            slot.borrow_mut().indicator_shown = fshow.as_bool();
            Ok(())
        })
    }

    fn GetTooltipString(&self) -> Result<BSTR> {
        super::catch_com("indicator GetTooltipString", || {
            let text = if self.label() == "가" { "세토 한글" } else { "세토 영문" };
            Ok(BSTR::from(text))
        })
    }
}

impl ITfLangBarItemButton_Impl for ModeButton_Impl {
    fn OnClick(&self, click: TfLBIClick, _pt: &POINT, _area: *const RECT) -> Result<()> {
        super::guard("indicator OnClick", || {
            if click == TF_LBI_CLK_RIGHT {
                return Ok(());
            }
            let Some(slot) = self.slot.upgrade() else {
                return Ok(());
            };
            toggle_from_indicator(&slot);
            Ok(())
        })
    }

    fn InitMenu(&self, _menu: Ref<windows::Win32::UI::TextServices::ITfMenu>) -> Result<()> {
        Ok(())
    }

    fn OnMenuSelect(&self, _id: u32) -> Result<()> {
        Ok(())
    }

    fn GetIcon(&self) -> Result<HICON> {
        super::catch_com("indicator GetIcon", || Ok(mode_icon(self.label()).unwrap_or(HICON(std::ptr::null_mut()))))
    }

    fn GetText(&self) -> Result<BSTR> {
        super::catch_com("indicator GetText", || Ok(BSTR::from(self.label())))
    }
}

impl ITfSource_Impl for ModeButton_Impl {
    fn AdviseSink(&self, riid: *const GUID, punk: Ref<IUnknown>) -> Result<u32> {
        super::guard("indicator AdviseSink", || {
            if riid.is_null() || unsafe { *riid } != ITfLangBarItemSink::IID {
                return Err(Error::from(E_NOINTERFACE));
            }
            let Some(unknown) = punk.ok().ok().cloned() else {
                return Err(E_POINTER.into());
            };
            let sink: ITfLangBarItemSink = unknown.cast()?;
            let Some(slot) = self.slot.upgrade() else {
                return Err(E_FAIL.into());
            };
            slot.borrow_mut().langbar_sink = Some(sink);
            Ok(SINK_COOKIE)
        })
    }

    fn UnadviseSink(&self, cookie: u32) -> Result<()> {
        super::catch_com("indicator UnadviseSink", || {
            if cookie != SINK_COOKIE {
                return Err(E_FAIL.into());
            }
            let Some(slot) = self.slot.upgrade() else {
                return Ok(());
            };
            slot.borrow_mut().langbar_sink = None;
            Ok(())
        })
    }
}

impl ITfCompartmentEventSink_Impl for ModeButton_Impl {
    fn OnChange(&self, rguid: *const GUID) -> Result<()> {
        super::guard("indicator OnChange", || {
            if rguid.is_null() || unsafe { *rguid } != GUID_COMPARTMENT_KEYBOARD_INPUTMODE_CONVERSION {
                return Ok(());
            }
            let Some(slot) = self.slot.upgrade() else {
                return Ok(());
            };
            // Copy the flag out before any other borrow. A compartment write
            // we just made re-enters here; adopting it again would toggle twice.
            let updating = slot.borrow().updating_mode;
            if updating {
                return Ok(());
            }
            let thread_mgr = slot.borrow().thread_mgr.clone();
            let Some(thread_mgr) = thread_mgr else {
                return Ok(());
            };
            let Some(bits) = read_dword(&thread_mgr, &GUID_COMPARTMENT_KEYBOARD_INPUTMODE_CONVERSION) else {
                return Ok(());
            };
            let want = if bits & TF_CONVERSIONMODE_NATIVE != 0 { Language::Korean } else { Language::English };
            let mode = slot.borrow().engine.mode();
            if mode == want {
                let sink = slot.borrow().langbar_sink.clone();
                notify(sink);
                return Ok(());
            }
            log(&format!("indicator compartment -> {}", indicator_label(want)));
            adopt(&slot, want);
            Ok(())
        })
    }
}

pub(crate) fn install(slot: &SharedTip) {
    let thread_mgr = slot.borrow().thread_mgr.clone();
    let Some(thread_mgr) = thread_mgr else {
        log("indicator skipped: no thread manager");
        return;
    };
    let unknown: IUnknown = ModeButton::new(Rc::downgrade(slot)).into();
    let item = match unknown.cast::<ITfLangBarItem>() {
        Ok(item) => item,
        Err(error) => {
            log(&format!("indicator button: {error}"));
            return;
        }
    };
    let event = match unknown.cast::<ITfCompartmentEventSink>() {
        Ok(event) => event,
        Err(error) => {
            log(&format!("indicator compartment sink: {error}"));
            return;
        }
    };
    let mgr = match thread_mgr.cast::<ITfLangBarItemMgr>() {
        Ok(mgr) => mgr,
        Err(error) => {
            log(&format!("indicator langbar: {error}"));
            return;
        }
    };
    if let Err(error) = unsafe { mgr.AddItem(&item) } {
        log(&format!("indicator AddItem: {error}"));
    }
    let source = match thread_compartment(&thread_mgr, &GUID_COMPARTMENT_KEYBOARD_INPUTMODE_CONVERSION) {
        Ok(compartment) => match compartment.cast::<ITfSource>() {
            Ok(source) => source,
            Err(error) => {
                log(&format!("indicator compartment source: {error}"));
                store_button(slot, item, mgr, None);
                publish(slot, true);
                return;
            }
        },
        Err(error) => {
            log(&format!("indicator GetCompartment: {error}"));
            store_button(slot, item, mgr, None);
            publish(slot, true);
            return;
        }
    };
    let event_sink = match unsafe { source.AdviseSink(&ITfCompartmentEventSink::IID, &event) } {
        Ok(cookie) => Some((source, cookie)),
        Err(error) => {
            log(&format!("indicator AdviseSink: {error}"));
            None
        }
    };
    store_button(slot, item, mgr, event_sink);
    publish(slot, true);
}

pub(crate) fn remove(slot: &SharedTip) {
    let (mgr, item, event, thread_mgr, client_id) = {
        let mut tip = slot.borrow_mut();
        tip.updating_mode = true;
        (
            tip.langbar_mgr.take(),
            tip.langbar_item.take(),
            tip.compartment_event.take(),
            tip.thread_mgr.clone(),
            tip.client_id,
        )
    };
    if let Some((source, cookie)) = event
        && let Err(error) = unsafe { source.UnadviseSink(cookie) }
    {
        log(&format!("indicator UnadviseSink: {error}"));
    }
    if let Some(thread_mgr) = thread_mgr.as_ref()
        && client_id != 0
        && let Err(error) = write_dword(thread_mgr, client_id, &GUID_COMPARTMENT_KEYBOARD_OPENCLOSE, 0)
    {
        log(&format!("indicator openclose clear: {error}"));
    }
    if let (Some(mgr), Some(item)) = (mgr, item)
        && let Err(error) = unsafe { mgr.RemoveItem(&item) }
    {
        log(&format!("indicator RemoveItem: {error}"));
    }
    {
        let mut tip = slot.borrow_mut();
        tip.langbar_sink = None;
        tip.published = None;
        tip.updating_mode = false;
    }
    log("indicator removed");
}

/// Push the session mode to the taskbar. `force` writes even when the mode
/// is unchanged, which is what a focus change needs. A key calls this with
/// `force == false`, so an auto-switch that flips the mode is published and
/// a key that does not is left alone.
pub(crate) fn publish(slot: &SharedTip, force: bool) {
    let (mode, client_id, thread_mgr, context, sink, updating, published) = {
        let tip = slot.borrow();
        (
            tip.engine.mode(),
            tip.client_id,
            tip.thread_mgr.clone(),
            tip.context.clone(),
            tip.langbar_sink.clone(),
            tip.updating_mode,
            tip.published,
        )
    };
    if updating || client_id == 0 {
        return;
    }
    if !force && published == Some(mode) {
        return;
    }
    let Some(thread_mgr) = thread_mgr else {
        return;
    };
    {
        let mut tip = slot.borrow_mut();
        tip.updating_mode = true;
    }
    let wrote = write_mode(&thread_mgr, context.as_ref(), client_id, mode);
    notify(sink);
    {
        let mut tip = slot.borrow_mut();
        if wrote {
            tip.published = Some(mode);
        }
        tip.updating_mode = false;
    }
    log(&format!("indicator {} native={} wrote={wrote}", indicator_label(mode), conversion_native(mode)));
}

fn toggle_from_indicator(slot: &SharedTip) {
    let updating = slot.borrow().updating_mode;
    if updating {
        return;
    }
    let (update, context, client_id, mode) = {
        let mut tip = slot.borrow_mut();
        let update = tip.engine.toggle_mode();
        let context = tip.context.clone();
        let client_id = tip.client_id;
        let mode = tip.engine.mode();
        (update, context, client_id, mode)
    };
    log(&format!("indicator click -> {}", indicator_label(mode)));
    apply_update(slot, &context, client_id, update);
    publish(slot, true);
}

fn adopt(slot: &SharedTip, want: Language) {
    let (updates, context, client_id) = {
        let mut tip = slot.borrow_mut();
        let mut updates = Vec::with_capacity(2);
        updates.push(tip.engine.toggle_mode());
        if tip.engine.mode() != want {
            updates.push(tip.engine.force_mode(want));
        }
        let context = tip.context.clone();
        let client_id = tip.client_id;
        (updates, context, client_id)
    };
    for update in updates {
        apply_update(slot, &context, client_id, update);
    }
    publish(slot, true);
}

fn apply_update(slot: &SharedTip, context: &Option<ITfContext>, client_id: u32, update: seto_core::SessionUpdate) {
    let Some(context) = context else {
        return;
    };
    service::schedule(slot, context, client_id, &KeyEffect::Eat { update: Some(update), delete_utf16: 0 }, true);
}

fn store_button(slot: &SharedTip, item: ITfLangBarItem, mgr: ITfLangBarItemMgr, event: Option<(ITfSource, u32)>) {
    let mut tip = slot.borrow_mut();
    tip.langbar_item = Some(item);
    tip.langbar_mgr = Some(mgr);
    tip.compartment_event = event;
}

fn notify(sink: Option<ITfLangBarItemSink>) {
    let Some(sink) = sink else {
        return;
    };
    let flags = TF_LBI_ICON | TF_LBI_TEXT | TF_LBI_TOOLTIP | TF_LBI_STATUS;
    if let Err(error) = unsafe { sink.OnUpdate(flags) } {
        log(&format!("indicator OnUpdate: {error}"));
    }
}

fn write_mode(thread_mgr: &ITfThreadMgr, context: Option<&ITfContext>, client_id: u32, mode: Language) -> bool {
    let value = if conversion_native(mode) { TF_CONVERSIONMODE_NATIVE } else { TF_CONVERSIONMODE_ALPHANUMERIC };
    let conversion = write_dword(thread_mgr, client_id, &GUID_COMPARTMENT_KEYBOARD_INPUTMODE_CONVERSION, value);
    let open = write_dword(thread_mgr, client_id, &GUID_COMPARTMENT_KEYBOARD_OPENCLOSE, 1);
    if let Err(error) = &conversion {
        log(&format!("indicator conversion: {error}"));
    }
    if let Err(error) = &open {
        log(&format!("indicator openclose: {error}"));
    }
    if let Some(context) = context
        && let Ok(mgr) = context.cast::<ITfCompartmentMgr>()
    {
        let _ = set_dword(&mgr, client_id, &GUID_COMPARTMENT_KEYBOARD_INPUTMODE_CONVERSION, value);
        let _ = set_dword(&mgr, client_id, &GUID_COMPARTMENT_KEYBOARD_OPENCLOSE, 1);
    }
    conversion.is_ok() && open.is_ok()
}

fn write_dword(thread_mgr: &ITfThreadMgr, client_id: u32, guid: &GUID, value: u32) -> Result<()> {
    let mgr = thread_mgr.cast::<ITfCompartmentMgr>()?;
    set_dword(&mgr, client_id, guid, value)
}

fn set_dword(mgr: &ITfCompartmentMgr, client_id: u32, guid: &GUID, value: u32) -> Result<()> {
    let compartment = unsafe { mgr.GetCompartment(guid)? };
    let variant = VARIANT::from(value as i32);
    unsafe { compartment.SetValue(client_id, &variant) }
}

fn thread_compartment(
    thread_mgr: &ITfThreadMgr,
    guid: &GUID,
) -> Result<windows::Win32::UI::TextServices::ITfCompartment> {
    let mgr = thread_mgr.cast::<ITfCompartmentMgr>()?;
    unsafe { mgr.GetCompartment(guid) }
}

fn read_dword(thread_mgr: &ITfThreadMgr, guid: &GUID) -> Option<u32> {
    let compartment = thread_compartment(thread_mgr, guid).ok()?;
    let mut value = unsafe { compartment.GetValue().ok()? };
    let bits = variant_dword(&value);
    unsafe {
        VariantClear(&mut value).ok();
    }
    bits
}

fn variant_dword(value: &VARIANT) -> Option<u32> {
    unsafe {
        let header = &*value.Anonymous.Anonymous;
        match header.vt {
            VT_I4 | VT_INT => Some(header.Anonymous.lVal as u32),
            VT_UI4 => Some(header.Anonymous.ulVal),
            VT_EMPTY => Some(0),
            _ => None,
        }
    }
}

fn mode_icon(label: &str) -> Option<HICON> {
    unsafe {
        let screen = GetDC(None);
        if screen.is_invalid() {
            return None;
        }
        let dc = CreateCompatibleDC(Some(screen));
        let color = CreateCompatibleBitmap(screen, 16, 16);
        let _ = ReleaseDC(None, screen);
        if dc.is_invalid() || color.is_invalid() {
            release_dc(dc);
            release_bitmap(color);
            return None;
        }
        let zeros = [0u8; 64];
        let mask = CreateBitmap(16, 16, 1, 1, Some(zeros.as_ptr().cast()));
        if mask.is_invalid() {
            release_bitmap(color);
            release_dc(dc);
            return None;
        }
        let previous = SelectObject(dc, HGDIOBJ::from(color));
        let _ = PatBlt(dc, 0, 0, 16, 16, WHITENESS);
        draw_label(dc, label);
        let _ = SelectObject(dc, previous);
        let icon = windows::Win32::UI::WindowsAndMessaging::CreateIconIndirect(&ICONINFO {
            fIcon: true.into(),
            xHotspot: 0,
            yHotspot: 0,
            hbmMask: mask,
            hbmColor: color,
        })
        .ok();
        release_bitmap(color);
        release_bitmap(mask);
        release_dc(dc);
        icon
    }
}

unsafe fn draw_label(dc: HDC, label: &str) {
    let mut face: Vec<u16> = "Malgun Gothic".encode_utf16().collect();
    face.push(0);
    let font = unsafe {
        CreateFontW(
            -12,
            0,
            0,
            0,
            400,
            0,
            0,
            0,
            HANGUL_CHARSET,
            OUT_DEFAULT_PRECIS,
            CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY,
            0,
            PCWSTR(face.as_ptr()),
        )
    };
    if font.is_invalid() {
        return;
    }
    let previous = unsafe { SelectObject(dc, HGDIOBJ::from(font)) };
    unsafe {
        let _ = SetBkMode(dc, TRANSPARENT);
        let _ = SetTextColor(dc, COLORREF(0));
        let units: Vec<u16> = label.encode_utf16().collect();
        let _ = TextOutW(dc, 1, 1, &units);
        let _ = SelectObject(dc, previous);
        let _ = DeleteObject(HGDIOBJ::from(font));
    }
}

fn release_bitmap(bitmap: HBITMAP) {
    if !bitmap.is_invalid() {
        unsafe {
            let _ = DeleteObject(HGDIOBJ::from(bitmap));
        }
    }
}

fn release_dc(dc: HDC) {
    if !dc.is_invalid() {
        unsafe {
            let _ = DeleteDC(dc);
        }
    }
}
