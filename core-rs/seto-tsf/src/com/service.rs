//! Text service: activate the key sink, hand hardware keys to the engine, and
//! push the resulting edit into the focused document.

use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::{Arc, OnceLock};

use windows::Win32::Foundation::{LPARAM, WPARAM};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetKeyState, VK_CONTROL, VK_LCONTROL, VK_LMENU, VK_LSHIFT, VK_LWIN, VK_RCONTROL, VK_RMENU, VK_RSHIFT, VK_RWIN,
    VK_SHIFT,
};
use windows::Win32::UI::TextServices::{
    GUID_COMPARTMENT_EMPTYCONTEXT, GUID_COMPARTMENT_KEYBOARD_DISABLED, ITfCompartmentMgr, ITfContext,
    ITfDisplayAttributeProvider, ITfDisplayAttributeProvider_Impl, ITfKeyEventSink, ITfKeyEventSink_Impl,
    ITfKeystrokeMgr, ITfSource, ITfTextInputProcessor_Impl, ITfTextInputProcessorEx, ITfTextInputProcessorEx_Impl,
    ITfThreadFocusSink, ITfThreadFocusSink_Impl, ITfThreadMgr, TF_TMAE_SECUREMODE,
};
use windows::core::{BOOL, GUID, IUnknownImpl, Interface, Ref, Result, implement};

use seto_core::{FieldEdit, Lexicon, utf16_len};

use crate::apply::{EditPlan, plan_edit};
use crate::engine::{Engine, KeyEffect};
use crate::keys::{WinKey, vk};

use super::display;
use super::edit;
use super::{install_panic_hook, log};

pub(crate) struct TipInner {
    pub(crate) engine: Engine,
    pub(crate) composition: Option<windows::Win32::UI::TextServices::ITfComposition>,
    pub(crate) composition_utf16: usize,
    pub(crate) ending: bool,
    pub(crate) client_id: u32,
    thread_mgr: Option<ITfThreadMgr>,
    focus: Option<(ITfSource, u32)>,
    context: Option<ITfContext>,
    secure: bool,
}

pub(crate) type SharedTip = Rc<RefCell<TipInner>>;

#[implement(ITfTextInputProcessorEx, ITfKeyEventSink, ITfDisplayAttributeProvider, ITfThreadFocusSink)]
pub(crate) struct TextService {
    tip: SharedTip,
}

impl TextService {
    pub(crate) fn new() -> Self {
        install_panic_hook();
        super::lock_module();
        Self {
            tip: Rc::new(RefCell::new(TipInner {
                engine: Engine::new(lexicon()),
                composition: None,
                composition_utf16: 0,
                ending: false,
                client_id: 0,
                thread_mgr: None,
                focus: None,
                context: None,
                secure: false,
            })),
        }
    }
}

impl Drop for TextService {
    fn drop(&mut self) {
        super::unlock_module();
    }
}

impl ITfTextInputProcessor_Impl for TextService_Impl {
    fn Activate(&self, ptim: Ref<ITfThreadMgr>, tid: u32) -> Result<()> {
        let thread_mgr = ptim.ok().ok().cloned();
        super::guard(&format!("Activate tid={tid}"), || match thread_mgr {
            Some(thread_mgr) => self.activate_with(thread_mgr, tid, 0),
            None => Ok(()),
        })
    }

    fn Deactivate(&self) -> Result<()> {
        super::guard("Deactivate", || {
            self.commit_focus();
            let mut tip = self.tip.borrow_mut();
            let client_id = tip.client_id;
            let thread_mgr = tip.thread_mgr.take();
            let focus = tip.focus.take();
            tip.context = None;
            tip.client_id = 0;
            tip.secure = false;
            drop(tip);
            if let Some(thread_mgr) = thread_mgr
                && let Ok(keys) = thread_mgr.cast::<ITfKeystrokeMgr>()
            {
                let _ = unsafe { keys.UnadviseKeyEventSink(client_id) };
            }
            if let Some((source, cookie)) = focus {
                let _ = unsafe { source.UnadviseSink(cookie) };
            }
            Ok(())
        })
    }
}

impl ITfTextInputProcessorEx_Impl for TextService_Impl {
    fn ActivateEx(&self, ptim: Ref<ITfThreadMgr>, tid: u32, dwflags: u32) -> Result<()> {
        let thread_mgr = ptim.ok().ok().cloned();
        super::guard(&format!("ActivateEx tid={tid} flags={dwflags:#x}"), || match thread_mgr {
            Some(thread_mgr) => self.activate_with(thread_mgr, tid, dwflags),
            None => Ok(()),
        })
    }
}

impl TextService_Impl {
    fn activate_with(&self, thread_mgr: ITfThreadMgr, tid: u32, flags: u32) -> Result<()> {
        let sink: ITfKeyEventSink = self.to_interface();
        let keys: ITfKeystrokeMgr = thread_mgr.cast()?;
        unsafe { keys.AdviseKeyEventSink(tid, &sink, true)? };
        let focus_sink: ITfThreadFocusSink = self.to_interface();
        let source: ITfSource = thread_mgr.cast()?;
        let cookie = unsafe { source.AdviseSink(&ITfThreadFocusSink::IID, &focus_sink)? };
        {
            let mut tip = self.tip.borrow_mut();
            tip.client_id = tid;
            tip.secure = flags & TF_TMAE_SECUREMODE != 0;
            tip.thread_mgr = Some(thread_mgr);
            tip.focus = Some((source, cookie));
            tip.engine.sync_modifiers(key_down(VK_SHIFT.0), key_down(VK_RMENU.0));
        }
        log(&format!("activated tid={tid} secure={}", flags & TF_TMAE_SECUREMODE != 0));
        Ok(())
    }

    fn commit_focus(&self) {
        let (update, context, client_id) = {
            let mut tip = self.tip.borrow_mut();
            let update = tip.engine.commit_for_focus_loss();
            let context = tip.context.clone();
            let client_id = tip.client_id;
            (update, context, client_id)
        };
        if let Some(context) = context {
            schedule(
                &self.tip,
                &context,
                client_id,
                &KeyEffect::Pass { commit: Some(update), app_deletes: false },
                true,
            );
        }
    }
}

impl ITfThreadFocusSink_Impl for TextService_Impl {
    fn OnSetThreadFocus(&self) -> Result<()> {
        super::guard("OnSetThreadFocus", || Ok(()))
    }

    fn OnKillThreadFocus(&self) -> Result<()> {
        super::guard("OnKillThreadFocus", || {
            self.commit_focus();
            Ok(())
        })
    }
}

impl ITfKeyEventSink_Impl for TextService_Impl {
    fn OnSetFocus(&self, foreground: BOOL) -> Result<()> {
        let foreground = foreground.as_bool();
        super::guard(&format!("OnSetFocus foreground={foreground}"), || {
            if !foreground {
                self.commit_focus();
            }
            Ok(())
        })
    }

    fn OnTestKeyDown(&self, pic: Ref<ITfContext>, wparam: WPARAM, lparam: LPARAM) -> Result<BOOL> {
        let key = decode(wparam, lparam);
        let context = pic.ok().ok().cloned();
        super::guard(&format!("OnTestKeyDown vk={:#x} scan={:#x}", key.vk, key.scan), || {
            let Some(context) = context else {
                return Ok(false.into());
            };
            self.remember_context(&context);
            if self.blocked(&context) {
                self.commit_focus();
                return Ok(false.into());
            }
            let eat = {
                let tip = self.tip.borrow();
                tip.engine.will_eat_down(&key)
            };
            if !eat {
                let effect = self.tip.borrow_mut().engine.key_down(&key);
                let client_id = self.tip.borrow().client_id;
                log_passthrough(&key, &effect);
                // Commit finishes before we return not-eaten, so Enter's newline
                // is not swallowed by a composition that is still open.
                schedule(&self.tip, &context, client_id, &effect, true);
            }
            log(&format!("OnTestKeyDown vk={:#x} scan={:#x} eat={eat}", key.vk, key.scan));
            Ok(eat.into())
        })
    }

    fn OnKeyDown(&self, pic: Ref<ITfContext>, wparam: WPARAM, lparam: LPARAM) -> Result<BOOL> {
        let key = decode(wparam, lparam);
        let context = pic.ok().ok().cloned();
        super::guard(&format!("OnKeyDown vk={:#x} scan={:#x}", key.vk, key.scan), || {
            let Some(context) = context else {
                return Ok(false.into());
            };
            self.remember_context(&context);
            let effect = self.tip.borrow_mut().engine.key_down(&key);
            let client_id = self.tip.borrow().client_id;
            if key.vk == vk::BACK {
                log(&format!("backspace composing preedit={} eaten=true", self.tip.borrow().engine.preedit()));
            }
            // Backspace must update the composition before we return. Inserts
            // can stay asynchronous; the key is not delivered to the app.
            let sync = key.vk == vk::BACK;
            schedule(&self.tip, &context, client_id, &effect, sync);
            Ok(true.into())
        })
    }

    fn OnTestKeyUp(&self, pic: Ref<ITfContext>, wparam: WPARAM, lparam: LPARAM) -> Result<BOOL> {
        let key = decode(wparam, lparam);
        let context = pic.ok().ok().cloned();
        super::guard(&format!("OnTestKeyUp vk={:#x}", key.vk), || {
            let Some(context) = context else {
                return Ok(false.into());
            };
            let eat = self.tip.borrow().engine.will_eat_up(&key);
            if !eat {
                let effect = self.tip.borrow_mut().engine.key_up(&key);
                let client_id = self.tip.borrow().client_id;
                schedule(&self.tip, &context, client_id, &effect, false);
            }
            Ok(eat.into())
        })
    }

    fn OnKeyUp(&self, pic: Ref<ITfContext>, wparam: WPARAM, lparam: LPARAM) -> Result<BOOL> {
        let key = decode(wparam, lparam);
        let context = pic.ok().ok().cloned();
        super::guard(&format!("OnKeyUp vk={:#x}", key.vk), || {
            let Some(context) = context else {
                return Ok(false.into());
            };
            let effect = self.tip.borrow_mut().engine.key_up(&key);
            let client_id = self.tip.borrow().client_id;
            schedule(&self.tip, &context, client_id, &effect, false);
            Ok(true.into())
        })
    }

    fn OnPreservedKey(&self, _pic: Ref<ITfContext>, _rguid: *const GUID) -> Result<BOOL> {
        super::guard("OnPreservedKey", || Ok(false.into()))
    }
}

impl ITfDisplayAttributeProvider_Impl for TextService_Impl {
    fn EnumDisplayAttributeInfo(&self) -> Result<windows::Win32::UI::TextServices::IEnumTfDisplayAttributeInfo> {
        super::guard("EnumDisplayAttributeInfo", || Ok(display::enumerator()))
    }

    fn GetDisplayAttributeInfo(
        &self,
        guid: *const GUID,
    ) -> Result<windows::Win32::UI::TextServices::ITfDisplayAttributeInfo> {
        super::guard("GetDisplayAttributeInfo", || display::info_for(guid))
    }
}

impl TextService_Impl {
    fn remember_context(&self, context: &ITfContext) {
        self.tip.borrow_mut().context = Some(context.clone());
    }

    fn blocked(&self, context: &ITfContext) -> bool {
        let secure = self.tip.borrow().secure;
        secure || keyboard_disabled(context)
    }
}

fn log_passthrough(key: &WinKey, effect: &KeyEffect) {
    let commit = matches!(effect, KeyEffect::Pass { commit: Some(_), .. });
    let kind = match key.vk {
        vk::RETURN => "enter",
        vk::BACK => "backspace",
        vk::TAB => "tab",
        vk::ESCAPE => "esc",
        vk::DELETE => "delete",
        vk::LEFT | vk::RIGHT | vk::UP | vk::DOWN => "arrow",
        _ if key.control || key.left_alt || key.win => "shortcut",
        _ => "passthrough",
    };
    log(&format!(
        "{kind} pass-through vk={:#x} scan={:#x} commit={commit} ctrl={} alt={} win={}",
        key.vk, key.scan, key.control, key.left_alt, key.win
    ));
}

fn schedule(slot: &SharedTip, context: &ITfContext, client_id: u32, effect: &KeyEffect, sync: bool) {
    let plan = {
        let mut tip = slot.borrow_mut();
        let before = tip.composition_utf16;
        let (plan, next) = plan_for(before, effect);
        tip.composition_utf16 = next;
        plan
    };
    let Some(plan) = plan else {
        log("schedule: no document change");
        return;
    };
    log(&format!(
        "schedule sync={sync} delete={} insert={} compose={}",
        plan.delete_utf16, plan.insert, plan.compose_utf16
    ));
    if client_id == 0 {
        log("schedule skipped: client id is 0");
        return;
    }
    if let Err(error) = edit::request(context, Rc::clone(slot), client_id, plan, sync) {
        log(&format!("edit session rejected: {error}"));
    }
}

fn plan_for(before: usize, effect: &KeyEffect) -> (Option<EditPlan>, usize) {
    match effect {
        KeyEffect::Pass { commit: Some(update), .. } | KeyEffect::Eat { update: Some(update), .. } => {
            let delete = match effect {
                KeyEffect::Eat { delete_utf16, update: Some(update) }
                    if *delete_utf16 > 0 && matches!(update.field, FieldEdit::None) =>
                {
                    Some(EditPlan { delete_utf16: *delete_utf16, insert: String::new(), compose_utf16: 0 })
                }
                _ => plan_edit(before, &update.field),
            };
            (delete, utf16_len(&update.preedit))
        }
        KeyEffect::Eat { delete_utf16, .. } if *delete_utf16 > 0 => {
            (Some(EditPlan { delete_utf16: *delete_utf16, insert: String::new(), compose_utf16: 0 }), 0)
        }
        _ => (None, before),
    }
}

fn keyboard_disabled(context: &ITfContext) -> bool {
    let Ok(manager) = context.cast::<ITfCompartmentMgr>() else {
        return false;
    };
    compartment_set(&manager, &GUID_COMPARTMENT_KEYBOARD_DISABLED)
        || compartment_set(&manager, &GUID_COMPARTMENT_EMPTYCONTEXT)
}

fn compartment_set(manager: &ITfCompartmentMgr, guid: &GUID) -> bool {
    let Ok(compartment) = (unsafe { manager.GetCompartment(guid) }) else {
        return false;
    };
    let Ok(value) = (unsafe { compartment.GetValue() }) else {
        return false;
    };
    i32::try_from(&value).ok().is_some_and(|value| value != 0)
}

fn decode(wparam: WPARAM, lparam: LPARAM) -> WinKey {
    let vk_code = wparam.0 as u16;
    let bits = lparam.0 as u32;
    let extended = bits & (1 << 24) != 0;
    let mut key = WinKey {
        vk: vk_code,
        scan: ((bits >> 16) & 0xff) as u16,
        extended,
        shift: key_down(VK_SHIFT.0) || key_down(VK_LSHIFT.0) || key_down(VK_RSHIFT.0),
        control: key_down(VK_CONTROL.0) || key_down(VK_LCONTROL.0) || key_down(VK_RCONTROL.0),
        left_alt: key_down(VK_LMENU.0),
        right_alt: key_down(VK_RMENU.0) || (vk_code == vk::MENU && extended),
        win: key_down(VK_LWIN.0) || key_down(VK_RWIN.0),
        repeat: bits & (1 << 30) != 0,
    };
    if key.vk == vk::RMENU || (key.vk == vk::MENU && key.extended) {
        key.left_alt = false;
        key.right_alt = true;
    }
    key
}

fn key_down(vk: u16) -> bool {
    unsafe { GetKeyState(i32::from(vk)) < 0 }
}

fn lexicon() -> Arc<Lexicon> {
    static LEXICON: OnceLock<Arc<Lexicon>> = OnceLock::new();
    LEXICON
        .get_or_init(|| match std::panic::catch_unwind(std::panic::AssertUnwindSafe(load_lexicon)) {
            Ok(lexicon) => Arc::new(lexicon),
            Err(payload) => {
                log("lexicon load panicked; composing without dictionaries");
                let _ = payload;
                Arc::new(Lexicon::new(&[], &[]))
            }
        })
        .clone()
}

fn load_lexicon() -> Lexicon {
    let mut candidates = Vec::new();
    if let Some(module) = super::module_path().and_then(|path| path.parent().map(PathBuf::from)) {
        candidates.push(module.join("Resources"));
        candidates.push(module);
    }
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        let base = PathBuf::from(local).join("Seto");
        candidates.push(base.join("Resources"));
        candidates.push(base);
    }
    for directory in candidates {
        if directory.join("english-words.txt").is_file() && directory.join("korean-words.txt").is_file() {
            match Lexicon::load(&directory) {
                Ok(lexicon) => {
                    log(&format!("lexicon {}", directory.display()));
                    return lexicon;
                }
                Err(error) => log(&format!("lexicon {} failed: {error}", directory.display())),
            }
        }
    }
    log("lexicon missing; composing without auto-switch dictionaries");
    Lexicon::new(&[], &[])
}
