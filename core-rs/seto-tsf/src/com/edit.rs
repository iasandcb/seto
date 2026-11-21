//! Apply an [`EditPlan`](crate::apply::EditPlan) inside a TSF edit session.
//!
//! The plan is captured when the key is handled, using the composition length
//! *before* that key. The session runs later, after earlier plans, and resolves
//! ranges against the document as it is then.

use std::mem::ManuallyDrop;
use std::rc::Rc;

use windows::Win32::Foundation::E_FAIL;
use windows::Win32::UI::TextServices::{
    ITfComposition, ITfCompositionSink, ITfCompositionSink_Impl, ITfContext, ITfContextComposition, ITfEditSession,
    ITfEditSession_Impl, ITfRange, TF_AE_END, TF_ANCHOR_END, TF_DEFAULT_SELECTION, TF_ES_READWRITE, TF_SELECTION,
    TF_SELECTIONSTYLE,
};
use windows::core::{Interface, Ref, Result, implement};

use crate::apply::EditPlan;

use super::display;
use super::service::SharedTip;

pub(crate) fn request(context: &ITfContext, slot: SharedTip, client_id: u32, plan: EditPlan) -> Result<()> {
    let session: ITfEditSession = ApplySession { context: context.clone(), slot, plan }.into();
    unsafe { context.RequestEditSession(client_id, &session, TF_ES_READWRITE)? }.ok()
}

#[implement(ITfEditSession)]
struct ApplySession {
    context: ITfContext,
    slot: SharedTip,
    plan: EditPlan,
}

impl ITfEditSession_Impl for ApplySession_Impl {
    fn DoEditSession(&self, ec: u32) -> Result<()> {
        let result =
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| apply(&self.slot, &self.context, ec, &self.plan)));
        match result {
            Ok(result) => result,
            Err(_) => {
                super::log("edit session panicked");
                Err(E_FAIL.into())
            }
        }
    }
}

fn apply(slot: &SharedTip, context: &ITfContext, ec: u32, plan: &EditPlan) -> Result<()> {
    if plan.delete_utf16 == 0 && plan.insert.is_empty() {
        if plan.compose_utf16 == 0 {
            end_composition(slot, ec)?;
        }
        return Ok(());
    }
    let utf16: Vec<u16> = plan.insert.encode_utf16().collect();
    let range = replace_before_caret(slot, context, ec, plan.delete_utf16, &utf16)?;
    select_end(context, ec, &range)?;
    if plan.compose_utf16 == 0 {
        end_composition(slot, ec)?;
        return Ok(());
    }
    let compose = plan.compose_utf16.min(utf16.len());
    let marked = tail(context, ec, &range, compose)?;
    ensure_composition(slot, context, ec, &marked)?;
    if let Some(composition) = slot.borrow().composition.clone()
        && let Ok(live) = unsafe { composition.GetRange() }
    {
        display::mark(context, ec, &live);
        select_end(context, ec, &live)?;
    }
    Ok(())
}

fn replace_before_caret(
    slot: &SharedTip,
    context: &ITfContext,
    ec: u32,
    delete: usize,
    text: &[u16],
) -> Result<ITfRange> {
    let composition = slot.borrow().composition.clone();
    let range = if let Some(composition) = composition {
        let range = unsafe { composition.GetRange()? };
        let live = range_len(&range, ec);
        adjust_start(&range, ec, delete, live)?;
        range
    } else {
        let range = caret_range(context, ec)?;
        adjust_start(&range, ec, delete, 0)?;
        range
    };
    unsafe { range.SetText(ec, 0, text)? };
    Ok(range)
}

fn adjust_start(range: &ITfRange, ec: u32, delete: usize, live: usize) -> Result<()> {
    let delta = if delete == live && live > 0 {
        return Ok(());
    } else if delete >= live {
        -((delete - live) as i32)
    } else {
        unsafe { range.Collapse(ec, TF_ANCHOR_END)? };
        -(delete as i32)
    };
    if delta != 0 {
        let mut shifted = 0i32;
        unsafe { range.ShiftStart(ec, delta, &mut shifted, core::ptr::null())? };
    }
    Ok(())
}

fn tail(context: &ITfContext, ec: u32, range: &ITfRange, compose: usize) -> Result<ITfRange> {
    let marked = unsafe { range.Clone()? };
    let len = range_len(&marked, ec);
    if compose < len {
        unsafe { marked.Collapse(ec, TF_ANCHOR_END)? };
        let mut shifted = 0i32;
        unsafe { marked.ShiftStart(ec, -(compose as i32), &mut shifted, core::ptr::null())? };
    }
    let _ = context;
    Ok(marked)
}

fn ensure_composition(slot: &SharedTip, context: &ITfContext, ec: u32, range: &ITfRange) -> Result<()> {
    if slot.borrow().composition.is_some() {
        let current = slot.borrow().composition.clone();
        if let Some(composition) = current {
            let _ = unsafe { composition.ShiftStart(ec, range) };
            let _ = unsafe { composition.ShiftEnd(ec, range) };
            return Ok(());
        }
    }
    let sink: ITfCompositionSink = CompositionSink { slot: Rc::downgrade(slot) }.into();
    let composition_context: ITfContextComposition = context.cast()?;
    let composition = unsafe { composition_context.StartComposition(ec, range, &sink)? };
    slot.borrow_mut().composition = Some(composition);
    Ok(())
}

pub(crate) fn end_composition(slot: &SharedTip, ec: u32) -> Result<()> {
    let composition = {
        let mut state = slot.borrow_mut();
        state.ending = true;
        state.composition.take()
    };
    let result = if let Some(composition) = composition { unsafe { composition.EndComposition(ec) } } else { Ok(()) };
    slot.borrow_mut().ending = false;
    result
}

fn caret_range(context: &ITfContext, ec: u32) -> Result<ITfRange> {
    let mut selections = [TF_SELECTION::default()];
    let mut fetched = 0u32;
    unsafe { context.GetSelection(ec, TF_DEFAULT_SELECTION, &mut selections, &mut fetched)? };
    if fetched == 0 {
        core::mem::forget(selections);
        return Err(E_FAIL.into());
    }
    let owned = unsafe { ManuallyDrop::take(&mut selections[0].range) };
    core::mem::forget(selections);
    owned.ok_or_else(|| E_FAIL.into())
}

fn select_end(context: &ITfContext, ec: u32, range: &ITfRange) -> Result<()> {
    let end = unsafe { range.Clone()? };
    unsafe { end.Collapse(ec, TF_ANCHOR_END)? };
    let mut selection = TF_SELECTION {
        range: ManuallyDrop::new(Some(end)),
        style: TF_SELECTIONSTYLE { ase: TF_AE_END, fInterimChar: false.into() },
    };
    let result = unsafe { context.SetSelection(ec, core::slice::from_ref(&selection)) };
    drop(unsafe { ManuallyDrop::take(&mut selection.range) });
    core::mem::forget(selection);
    result
}

fn range_len(range: &ITfRange, ec: u32) -> usize {
    let mut buf = [0u16; 512];
    let mut fetched = 0u32;
    if unsafe { range.GetText(ec, 0, &mut buf, &mut fetched) }.is_err() {
        return 0;
    }
    fetched as usize
}

#[implement(ITfCompositionSink)]
struct CompositionSink {
    slot: std::rc::Weak<std::cell::RefCell<super::service::TipInner>>,
}

impl ITfCompositionSink_Impl for CompositionSink_Impl {
    fn OnCompositionTerminated(&self, _ecwrite: u32, _composition: Ref<ITfComposition>) -> Result<()> {
        let Some(slot) = self.slot.upgrade() else {
            return Ok(());
        };
        let mut state = slot.borrow_mut();
        state.composition = None;
        if state.ending {
            return Ok(());
        }
        state.composition_utf16 = 0;
        state.engine.note_external_composition_end();
        Ok(())
    }
}
