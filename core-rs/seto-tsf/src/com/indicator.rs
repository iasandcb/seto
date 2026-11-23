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
use std::sync::atomic::{AtomicBool, Ordering};

use windows::Win32::Foundation::{
    COLORREF, CloseHandle, E_FAIL, E_NOINTERFACE, E_POINTER, ERROR_SUCCESS, HANDLE, HWND, LPARAM, LRESULT, POINT, RECT,
    SIZE, WAIT_OBJECT_0, WPARAM,
};
use windows::Win32::Graphics::Gdi::{
    ANTIALIASED_QUALITY, BI_RGB, BITMAPINFO, BITMAPINFOHEADER, CLIP_DEFAULT_PRECIS, CreateBitmap, CreateCompatibleDC,
    CreateDIBSection, CreateFontW, DIB_RGB_COLORS, DeleteDC, DeleteObject, GetDC, GetTextExtentPoint32W,
    HANGUL_CHARSET, HBITMAP, HDC, HGDIOBJ, OUT_DEFAULT_PRECIS, ReleaseDC, SelectObject, SetBkMode, SetTextColor,
    TRANSPARENT, TextOutW,
};
use windows::Win32::System::Registry::{
    HKEY, HKEY_CURRENT_USER, KEY_NOTIFY, KEY_QUERY_VALUE, REG_NOTIFY_CHANGE_LAST_SET, RRF_RT_REG_DWORD, RegCloseKey,
    RegGetValueW, RegNotifyChangeKeyValue, RegOpenKeyExW,
};
use windows::Win32::System::Threading::{CreateEventW, INFINITE, SetEvent, WaitForMultipleObjects};
use windows::Win32::System::Variant::{VARIANT, VT_EMPTY, VT_I4, VT_INT, VT_UI4, VariantClear};
use windows::Win32::UI::TextServices::{
    GUID_COMPARTMENT_KEYBOARD_INPUTMODE_CONVERSION, GUID_COMPARTMENT_KEYBOARD_OPENCLOSE, GUID_LBI_INPUTMODE,
    ITfCompartmentEventSink, ITfCompartmentEventSink_Impl, ITfCompartmentMgr, ITfContext, ITfLangBarItem,
    ITfLangBarItem_Impl, ITfLangBarItemButton, ITfLangBarItemButton_Impl, ITfLangBarItemMgr, ITfLangBarItemSink,
    ITfMenu, ITfSource, ITfSource_Impl, ITfThreadMgr, TF_CONVERSIONMODE_ALPHANUMERIC, TF_CONVERSIONMODE_NATIVE,
    TF_LANGBARITEMINFO, TF_LBI_CLK_RIGHT, TF_LBI_ICON, TF_LBI_STATUS, TF_LBI_STATUS_BTN_TOGGLED, TF_LBI_STATUS_HIDDEN,
    TF_LBI_STYLE_BTN_BUTTON, TF_LBI_STYLE_SHOWNINTRAY, TF_LBI_TEXT, TF_LBI_TOOLTIP, TF_LBMENUF_RADIOCHECKED,
    TfLBIClick,
};
use windows::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CreateIconFromResourceEx, CreateIconIndirect, CreatePopupMenu, CreateWindowExW, DefWindowProcW,
    DestroyMenu, DestroyWindow, GWLP_USERDATA, GetCursorPos, GetDesktopWindow, GetSystemMetrics, GetWindowLongPtrW,
    HICON, HWND_MESSAGE, ICONINFO, IMAGE_FLAGS, LookupIconIdFromDirectoryEx, MF_CHECKED, MF_STRING, PostMessageW,
    RegisterClassW, SM_CXSMICON, SetForegroundWindow, SetWindowLongPtrW, TPM_NONOTIFY, TPM_RETURNCMD, TPM_RIGHTBUTTON,
    TrackPopupMenu, WINDOW_EX_STYLE, WINDOW_STYLE, WM_APP, WM_DESTROY, WM_NULL, WNDCLASSW, WS_EX_TOOLWINDOW,
    WS_EX_TOPMOST, WS_POPUP,
};
use windows::core::{BOOL, BSTR, Error, GUID, IUnknown, Interface, PCWSTR, Ref, Result, implement};

use seto_core::{KeyboardLayout, Language};

use crate::layout_pref;

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

    fn tooltip(&self) -> String {
        let Some(slot) = self.slot.upgrade() else {
            return "세토".to_owned();
        };
        let tip = slot.borrow();
        let language = if tip.engine.mode() == Language::Korean { "한글" } else { "영문" };
        format!("세토 {language} ({})", tip.engine.layout().title())
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
                dwStyle: TF_LBI_STYLE_BTN_BUTTON | TF_LBI_STYLE_SHOWNINTRAY,
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
        super::catch_com("indicator GetTooltipString", || Ok(BSTR::from(self.tooltip())))
    }
}

impl ITfLangBarItemButton_Impl for ModeButton_Impl {
    fn OnClick(&self, click: TfLBIClick, pt: &POINT, area: *const RECT) -> Result<()> {
        super::guard("indicator OnClick", || {
            // Windows 11 does not call InitMenu for GUID_LBI_INPUTMODE.
            // TF_LBI_CLK_RIGHT is the logical secondary button, so swapped
            // mouse buttons still arrive here when the shell forwards the click.
            if click == TF_LBI_CLK_RIGHT {
                let Some(slot) = self.slot.upgrade() else {
                    return Ok(());
                };
                show_layout_popup(&slot, click_point(*pt, area));
                return Ok(());
            }
            let Some(slot) = self.slot.upgrade() else {
                return Ok(());
            };
            toggle_from_indicator(&slot);
            Ok(())
        })
    }

    fn InitMenu(&self, menu: Ref<ITfMenu>) -> Result<()> {
        // Kept for a host that still asks. The taskbar indicator on Windows 11
        // does not; the secondary click builds the menu in OnClick.
        super::catch_com("indicator InitMenu", || {
            let Some(menu) = menu.ok().ok().cloned() else {
                return Ok(());
            };
            let Some(slot) = self.slot.upgrade() else {
                return Ok(());
            };
            let current = slot.borrow().engine.layout();
            fill_layout_menu(&menu, current)
        })
    }

    fn OnMenuSelect(&self, id: u32) -> Result<()> {
        super::guard("indicator OnMenuSelect", || {
            let Some(layout) = layout_pref::from_menu_id(id) else {
                return Ok(());
            };
            let Some(slot) = self.slot.upgrade() else {
                return Ok(());
            };
            super::layout_store::save(layout);
            select_layout(&slot, layout);
            Ok(())
        })
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
                finish_install(slot);
                return;
            }
        },
        Err(error) => {
            log(&format!("indicator GetCompartment: {error}"));
            store_button(slot, item, mgr, None);
            finish_install(slot);
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
    finish_install(slot);
}

fn finish_install(slot: &SharedTip) {
    publish(slot, true);
    let already = slot.borrow().theme_watch.is_some();
    if already {
        return;
    }
    let Some(watch) = start_theme_watch(slot) else {
        return;
    };
    slot.borrow_mut().theme_watch = Some(watch);
}

pub(crate) fn remove(slot: &SharedTip) {
    let watch = slot.borrow_mut().theme_watch.take();
    if let Some(watch) = watch {
        stop_theme_watch(watch);
    }
    let layout = slot.borrow_mut().layout_watch.take();
    if let Some(layout) = layout {
        super::layout_watch::stop(layout);
    }
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

/// Read `keyboardLayout` and apply it when Settings, or another process,
/// changed it. The same layout does not touch the document.
pub(crate) fn reload_layout(slot: &SharedTip) {
    let layout = super::layout_store::load();
    let current = slot.borrow().engine.layout();
    if current == layout {
        return;
    }
    log(&format!("layout reload {} -> {}", current.raw_value(), layout.raw_value()));
    select_layout(slot, layout);
}

fn show_layout_popup(slot: &SharedTip, pt: POINT) {
    let current = slot.borrow().engine.layout();
    let menu = match unsafe { CreatePopupMenu() } {
        Ok(menu) => menu,
        Err(error) => {
            log(&format!("layout menu: {error}"));
            return;
        }
    };
    for layout in KeyboardLayout::ALL {
        let mut label: Vec<u16> = layout.title().encode_utf16().collect();
        label.push(0);
        let flags = if layout == current { MF_STRING | MF_CHECKED } else { MF_STRING };
        let id = usize::try_from(layout_pref::dialog_id(layout)).unwrap_or(0);
        if let Err(error) = unsafe { AppendMenuW(menu, flags, id, PCWSTR(label.as_ptr())) } {
            log(&format!("layout menu item: {error}"));
        }
    }
    let (owner, owned) = popup_owner(pt);
    unsafe {
        let _ = SetForegroundWindow(owner);
    }
    let selected = unsafe {
        TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON, pt.x, pt.y, Some(0), owner, None)
    };
    unsafe {
        let _ = PostMessageW(Some(owner), WM_NULL, WPARAM(0), LPARAM(0));
        let _ = DestroyMenu(menu);
        if owned {
            let _ = DestroyWindow(owner);
        }
    }
    let Some(layout) = layout_pref::from_dialog_id(command_id(selected)) else {
        return;
    };
    super::layout_store::save(layout);
    select_layout(slot, layout);
}

fn click_point(pt: POINT, area: *const RECT) -> POINT {
    if pt.x != 0 || pt.y != 0 {
        return pt;
    }
    if !area.is_null() {
        let area = unsafe { *area };
        if area.left != 0 || area.bottom != 0 {
            return POINT { x: area.left, y: area.bottom };
        }
    }
    let mut cursor = POINT::default();
    if unsafe { GetCursorPos(&mut cursor) }.is_ok() {
        return cursor;
    }
    pt
}

fn popup_owner(pt: POINT) -> (HWND, bool) {
    let created = unsafe {
        CreateWindowExW(
            WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
            windows::core::w!("STATIC"),
            PCWSTR::null(),
            WS_POPUP,
            pt.x,
            pt.y,
            0,
            0,
            None,
            None,
            None,
            None,
        )
    };
    match created {
        Ok(hwnd) => (hwnd, true),
        Err(error) => {
            log(&format!("layout menu window: {error}"));
            (unsafe { GetDesktopWindow() }, false)
        }
    }
}

/// `TPM_RETURNCMD` returns the item id, or 0 when the menu is dismissed.
fn command_id(selected: BOOL) -> u32 {
    u32::try_from(selected.0).unwrap_or(0)
}

fn fill_layout_menu(menu: &ITfMenu, current: KeyboardLayout) -> Result<()> {
    for layout in KeyboardLayout::ALL {
        let label: Vec<u16> = layout.title().encode_utf16().collect();
        let flags = if layout == current { TF_LBMENUF_RADIOCHECKED } else { 0 };
        unsafe {
            menu.AddMenuItem(
                layout_pref::menu_id(layout),
                flags,
                HBITMAP(std::ptr::null_mut()),
                HBITMAP(std::ptr::null_mut()),
                &label,
                std::ptr::null_mut(),
            )?;
        }
    }
    Ok(())
}

fn select_layout(slot: &SharedTip, layout: KeyboardLayout) {
    let (update, context, client_id) = {
        let mut tip = slot.borrow_mut();
        let update = tip.engine.set_layout(layout);
        let context = tip.context.clone();
        let client_id = tip.client_id;
        (update, context, client_id)
    };
    log(&format!("layout -> {}", layout.raw_value()));
    if let Some(update) = update {
        apply_update(slot, &context, client_id, update);
    }
    let sink = slot.borrow().langbar_sink.clone();
    notify(sink);
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

const ICON_SIZES: [i32; 4] = [16, 20, 24, 32];
const CLASS_NAME: [u16; 13] = [
    b'S' as u16,
    b'e' as u16,
    b't' as u16,
    b'o' as u16,
    b'M' as u16,
    b'o' as u16,
    b'd' as u16,
    b'e' as u16,
    b'I' as u16,
    b'c' as u16,
    b'o' as u16,
    b'n' as u16,
    0,
];

pub(crate) struct ThemeWatch {
    stop: HANDLE,
    hwnd: HWND,
    thread: Option<std::thread::JoinHandle<()>>,
}

fn mode_icon(label: &str) -> Option<HICON> {
    let light = system_uses_light_theme();
    let desired = crate::snap_tray_icon_px(unsafe { GetSystemMetrics(SM_CXSMICON) });
    let mut images = Vec::new();
    for size in ICON_SIZES {
        if let Some(bytes) = render_icon_image(label, size, light) {
            images.push((size, bytes));
        }
    }
    if images.is_empty() {
        return None;
    }
    let directory = group_icon_directory(&images);
    let id = unsafe { LookupIconIdFromDirectoryEx(directory.as_ptr(), true, desired, desired, IMAGE_FLAGS(0)) };
    let index = images
        .iter()
        .position(|(size, _)| *size == id)
        .unwrap_or_else(|| images.iter().position(|(size, _)| *size == desired).unwrap_or(0));
    let side = images[index].0;
    let created =
        unsafe { CreateIconFromResourceEx(&images[index].1, true, 0x0003_0000, side, side, IMAGE_FLAGS(0)).ok() };
    created.or_else(|| icon_indirect(label, side, light))
}

fn icon_indirect(label: &str, size: i32, light: bool) -> Option<HICON> {
    let coverage = draw_coverage(label, size)?;
    unsafe {
        let dc = memory_dc()?;
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: 40,
                biWidth: size,
                biHeight: -size,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..BITMAPINFOHEADER::default()
            },
            ..BITMAPINFO::default()
        };
        let mut bits: *mut core::ffi::c_void = core::ptr::null_mut();
        let color = match CreateDIBSection(Some(dc), &info, DIB_RGB_COLORS, &mut bits, None, 0) {
            Ok(bitmap) => bitmap,
            Err(_) => {
                release_dc(dc);
                return None;
            }
        };
        if bits.is_null() {
            release_bitmap(color);
            release_dc(dc);
            return None;
        }
        let dest = bits as *mut u8;
        for index in 0..(size * size) as usize {
            let alpha = coverage[index];
            let channel = if light { 0u16 } else { 255 };
            let premultiplied = (channel * u16::from(alpha) / 255) as u8;
            let offset = index * 4;
            *dest.add(offset) = premultiplied;
            *dest.add(offset + 1) = premultiplied;
            *dest.add(offset + 2) = premultiplied;
            *dest.add(offset + 3) = alpha;
        }
        let mask_stride = ((size + 31) / 32) * 4;
        let mut mask_bits = vec![0u8; (mask_stride * size) as usize];
        for y in 0..size {
            for x in 0..size {
                if coverage[(y * size + x) as usize] == 0 {
                    let row = (y * mask_stride) as usize;
                    mask_bits[row + (x / 8) as usize] |= 1 << (7 - (x % 8));
                }
            }
        }
        let mask = CreateBitmap(size, size, 1, 1, Some(mask_bits.as_ptr().cast()));
        let icon = if mask.is_invalid() {
            None
        } else {
            CreateIconIndirect(&ICONINFO {
                fIcon: true.into(),
                xHotspot: 0,
                yHotspot: 0,
                hbmMask: mask,
                hbmColor: color,
            })
            .ok()
        };
        release_bitmap(mask);
        release_bitmap(color);
        release_dc(dc);
        icon
    }
}

fn system_uses_light_theme() -> bool {
    let mut subkey: Vec<u16> =
        "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize".encode_utf16().collect();
    subkey.push(0);
    let mut value: Vec<u16> = "SystemUsesLightTheme".encode_utf16().collect();
    value.push(0);
    let mut data = 1u32;
    let mut size = 4u32;
    let status = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            PCWSTR(subkey.as_ptr()),
            PCWSTR(value.as_ptr()),
            RRF_RT_REG_DWORD,
            None,
            Some((&mut data as *mut u32).cast()),
            Some(&mut size),
        )
    };
    if status != ERROR_SUCCESS {
        return true;
    }
    data != 0
}

fn render_icon_image(label: &str, size: i32, light: bool) -> Option<Vec<u8>> {
    let coverage = draw_coverage(label, size)?;
    let mask_stride = ((size + 31) / 32) * 4;
    let xor_bytes = (size * size * 4) as usize;
    let mask_bytes = (mask_stride * size) as usize;
    let mut image = Vec::with_capacity(40 + xor_bytes + mask_bytes);
    image.extend_from_slice(&40u32.to_le_bytes());
    image.extend_from_slice(&size.to_le_bytes());
    image.extend_from_slice(&(size * 2).to_le_bytes());
    image.extend_from_slice(&1u16.to_le_bytes());
    image.extend_from_slice(&32u16.to_le_bytes());
    image.extend_from_slice(&0u32.to_le_bytes());
    image.extend_from_slice(&((xor_bytes + mask_bytes) as u32).to_le_bytes());
    image.extend_from_slice(&[0u8; 16]);
    for y in (0..size).rev() {
        for x in 0..size {
            let alpha = coverage[(y * size + x) as usize];
            let channel = if light { 0u16 } else { 255 };
            let premultiplied = (channel * u16::from(alpha) / 255) as u8;
            image.extend_from_slice(&[premultiplied, premultiplied, premultiplied, alpha]);
        }
    }
    for y in (0..size).rev() {
        let mut row = vec![0u8; mask_stride as usize];
        for x in 0..size {
            if coverage[(y * size + x) as usize] == 0 {
                row[(x / 8) as usize] |= 1 << (7 - (x % 8));
            }
        }
        image.extend_from_slice(&row);
    }
    Some(image)
}

fn draw_coverage(label: &str, size: i32) -> Option<Vec<u8>> {
    unsafe {
        let dc = memory_dc()?;
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: 40,
                biWidth: size,
                biHeight: -size,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..BITMAPINFOHEADER::default()
            },
            ..BITMAPINFO::default()
        };
        let mut bits: *mut core::ffi::c_void = core::ptr::null_mut();
        let bitmap = match CreateDIBSection(Some(dc), &info, DIB_RGB_COLORS, &mut bits, None, 0) {
            Ok(bitmap) => bitmap,
            Err(_) => {
                release_dc(dc);
                return None;
            }
        };
        if bits.is_null() {
            release_bitmap(bitmap);
            release_dc(dc);
            return None;
        }
        core::ptr::write_bytes(bits, 0, (size * size * 4) as usize);
        let previous = SelectObject(dc, HGDIOBJ::from(bitmap));
        draw_white_glyph(dc, label, size);
        let _ = SelectObject(dc, previous);
        let src = bits as *const u8;
        let mut coverage = vec![0u8; (size * size) as usize];
        for index in 0..(size * size) as usize {
            let offset = index * 4;
            let blue = *src.add(offset);
            let green = *src.add(offset + 1);
            let red = *src.add(offset + 2);
            coverage[index] = blue.max(green).max(red);
        }
        release_bitmap(bitmap);
        release_dc(dc);
        Some(coverage)
    }
}

fn memory_dc() -> Option<HDC> {
    unsafe {
        let screen = GetDC(None);
        let dc = if screen.is_invalid() { CreateCompatibleDC(None) } else { CreateCompatibleDC(Some(screen)) };
        if !screen.is_invalid() {
            let _ = ReleaseDC(None, screen);
        }
        if dc.is_invalid() { None } else { Some(dc) }
    }
}

fn draw_white_glyph(dc: HDC, label: &str, size: i32) {
    let units: Vec<u16> = label.encode_utf16().collect();
    let mut face: Vec<u16> = "Malgun Gothic".encode_utf16().collect();
    face.push(0);
    let mut height = (size * 3 / 4).max(8);
    unsafe {
        let _ = SetBkMode(dc, TRANSPARENT);
        let _ = SetTextColor(dc, COLORREF(0x00FF_FFFF));
    }
    while height >= 6 {
        let font = unsafe {
            CreateFontW(
                -height,
                0,
                0,
                0,
                700,
                0,
                0,
                0,
                HANGUL_CHARSET,
                OUT_DEFAULT_PRECIS,
                CLIP_DEFAULT_PRECIS,
                ANTIALIASED_QUALITY,
                0,
                PCWSTR(face.as_ptr()),
            )
        };
        if font.is_invalid() {
            return;
        }
        let previous = unsafe { SelectObject(dc, HGDIOBJ::from(font)) };
        let mut extent = SIZE::default();
        let measured = unsafe { GetTextExtentPoint32W(dc, &units, &mut extent).as_bool() };
        if measured && extent.cx <= size - 1 && extent.cy <= size - 1 {
            let x = (size - extent.cx) / 2;
            let y = (size - extent.cy) / 2;
            unsafe {
                let _ = TextOutW(dc, x, y, &units);
                let _ = SelectObject(dc, previous);
                let _ = DeleteObject(HGDIOBJ::from(font));
            }
            return;
        }
        unsafe {
            let _ = SelectObject(dc, previous);
            let _ = DeleteObject(HGDIOBJ::from(font));
        }
        height -= 1;
    }
}

fn group_icon_directory(images: &[(i32, Vec<u8>)]) -> Vec<u8> {
    let mut directory = Vec::with_capacity(6 + images.len() * 14);
    directory.extend_from_slice(&0u16.to_le_bytes());
    directory.extend_from_slice(&1u16.to_le_bytes());
    directory.extend_from_slice(&(images.len() as u16).to_le_bytes());
    for (size, bytes) in images {
        let dim = if *size >= 256 { 0 } else { *size as u8 };
        directory.push(dim);
        directory.push(dim);
        directory.push(0);
        directory.push(0);
        directory.extend_from_slice(&1u16.to_le_bytes());
        directory.extend_from_slice(&32u16.to_le_bytes());
        directory.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
        directory.extend_from_slice(&(*size as u16).to_le_bytes());
    }
    directory
}

fn start_theme_watch(slot: &SharedTip) -> Option<ThemeWatch> {
    let hwnd = theme_window(slot)?;
    let stop = unsafe { CreateEventW(None, true, false, PCWSTR::null()).ok()? };
    let changed = match unsafe { CreateEventW(None, false, false, PCWSTR::null()) } {
        Ok(changed) => changed,
        Err(error) => {
            log(&format!("indicator theme event: {error}"));
            unsafe {
                let _ = DestroyWindow(hwnd);
                let _ = CloseHandle(stop);
            }
            return None;
        }
    };
    let key = match open_personalize_key() {
        Some(key) => key,
        None => {
            unsafe {
                let _ = DestroyWindow(hwnd);
                let _ = CloseHandle(stop);
                let _ = CloseHandle(changed);
            }
            return None;
        }
    };
    let armed = unsafe { RegNotifyChangeKeyValue(key, false, REG_NOTIFY_CHANGE_LAST_SET, Some(changed), true) };
    if armed != ERROR_SUCCESS {
        log(&format!("indicator theme watch failed: {armed:?}"));
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
            theme_loop(
                HWND(hwnd_bits as *mut _),
                HKEY(key_bits as *mut _),
                HANDLE(changed_bits as *mut _),
                HANDLE(stop_bits as *mut _),
            );
        }));
    });
    Some(ThemeWatch { stop, hwnd, thread: Some(thread) })
}

fn stop_theme_watch(mut watch: ThemeWatch) {
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

fn theme_loop(hwnd: HWND, key: HKEY, changed: HANDLE, stop: HANDLE) {
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
            break;
        }
    }
    unsafe {
        let _ = RegCloseKey(key);
        let _ = CloseHandle(changed);
    }
}

fn theme_window(slot: &SharedTip) -> Option<HWND> {
    ensure_theme_class();
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

fn ensure_theme_class() {
    static READY: AtomicBool = AtomicBool::new(false);
    if READY.swap(true, Ordering::AcqRel) {
        return;
    }
    let class = WNDCLASSW {
        lpfnWndProc: Some(theme_wndproc),
        hInstance: super::module_instance(),
        lpszClassName: PCWSTR(CLASS_NAME.as_ptr()),
        ..WNDCLASSW::default()
    };
    let atom = unsafe { RegisterClassW(&class) };
    if atom == 0 {
        READY.store(false, Ordering::Release);
        log("indicator theme window class was not registered");
    }
}

unsafe extern "system" fn theme_wndproc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        if msg == WM_APP {
            refresh_theme_icon(hwnd);
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

fn refresh_theme_icon(hwnd: HWND) {
    let raw = unsafe { GetWindowLongPtrW(hwnd, GWLP_USERDATA) };
    if raw == 0 {
        return;
    }
    let weak = unsafe { &*(raw as *const Weak<RefCell<TipInner>>) };
    let Some(slot) = weak.upgrade() else {
        return;
    };
    let sink = slot.borrow().langbar_sink.clone();
    log(&format!("indicator theme light={}", system_uses_light_theme()));
    notify(sink);
}

fn open_personalize_key() -> Option<HKEY> {
    let mut subkey: Vec<u16> =
        "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize".encode_utf16().collect();
    subkey.push(0);
    let mut key = HKEY::default();
    let status = unsafe {
        RegOpenKeyExW(HKEY_CURRENT_USER, PCWSTR(subkey.as_ptr()), None, KEY_QUERY_VALUE | KEY_NOTIFY, &mut key)
    };
    if status != ERROR_SUCCESS {
        log(&format!("indicator theme key: {status:?}"));
        return None;
    }
    Some(key)
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
