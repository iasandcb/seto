#![cfg_attr(not(windows), allow(dead_code))]

//! In-memory dialog template for the three Korean layouts.
//!
//! The bytes are the classic `DLGTEMPLATE` / `DLGITEMTEMPLATE` layout so the
//! alignment can be checked without Windows. `com::configure` displays them.

use seto_core::KeyboardLayout;

use crate::layout_pref;

const DS_SETFONT: u32 = 0x0040;
const DS_MODALFRAME: u32 = 0x0080;
const DS_SETFOREGROUND: u32 = 0x0200;
const DS_CENTER: u32 = 0x0800;
const WS_TABSTOP: u32 = 0x0001_0000;
const WS_GROUP: u32 = 0x0002_0000;
const WS_SYSMENU: u32 = 0x0008_0000;
const WS_VISIBLE: u32 = 0x1000_0000;
const WS_CHILD: u32 = 0x4000_0000;
const WS_CAPTION: u32 = 0x00C0_0000;
const WS_POPUP: u32 = 0x8000_0000;
const BS_DEFPUSHBUTTON: u32 = 0x0000_0001;
const BS_AUTORADIOBUTTON: u32 = 0x0000_0009;
const BUTTON_CLASS: u16 = 0x0080;

pub const IDOK: u16 = 1;
pub const IDCANCEL: u16 = 2;

/// `DLGTEMPLATE` for “세토 자판”: one radio per [`KeyboardLayout::ALL`] and
/// 확인 / 취소. The buffer length is a multiple of 4 and every control starts
/// on a dword.
pub fn template() -> Vec<u8> {
    let mut writer = Writer::default();
    let style =
        DS_SETFONT | DS_MODALFRAME | DS_SETFOREGROUND | DS_CENTER | WS_POPUP | WS_CAPTION | WS_SYSMENU | WS_VISIBLE;
    writer.header(style, 180, 120, (KeyboardLayout::ALL.len() + 2) as u16, "세토 자판");
    for (index, layout) in KeyboardLayout::ALL.iter().enumerate() {
        let mut item = WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_AUTORADIOBUTTON;
        if index == 0 {
            item |= WS_GROUP;
        }
        writer.button(
            item,
            12,
            12 + (index as i16) * 18,
            156,
            16,
            layout_pref::dialog_id(*layout) as u16,
            layout.title(),
        );
    }
    writer.button(WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_GROUP | BS_DEFPUSHBUTTON, 58, 74, 52, 16, IDOK, "확인");
    writer.button(WS_CHILD | WS_VISIBLE | WS_TABSTOP, 116, 74, 52, 16, IDCANCEL, "취소");
    writer.bytes
}

#[derive(Default)]
struct Writer {
    bytes: Vec<u8>,
}

impl Writer {
    fn header(&mut self, style: u32, cx: i16, cy: i16, count: u16, title: &str) {
        self.u32(style);
        self.u32(0);
        self.u16(count);
        self.i16(0);
        self.i16(0);
        self.i16(cx);
        self.i16(cy);
        self.u16(0);
        self.u16(0);
        self.wsz(title);
        self.u16(9);
        self.wsz("Malgun Gothic");
        self.align();
    }

    fn button(&mut self, style: u32, x: i16, y: i16, cx: i16, cy: i16, id: u16, title: &str) {
        self.align();
        self.u32(style);
        self.u32(0);
        self.i16(x);
        self.i16(y);
        self.i16(cx);
        self.i16(cy);
        self.u16(id);
        self.u16(0xFFFF);
        self.u16(BUTTON_CLASS);
        self.wsz(title);
        self.u16(0);
        self.align();
    }

    fn align(&mut self) {
        while self.bytes.len() % 4 != 0 {
            self.bytes.push(0);
        }
    }

    fn u16(&mut self, value: u16) {
        self.bytes.extend_from_slice(&value.to_le_bytes());
    }

    fn u32(&mut self, value: u32) {
        self.bytes.extend_from_slice(&value.to_le_bytes());
    }

    fn i16(&mut self, value: i16) {
        self.bytes.extend_from_slice(&value.to_le_bytes());
    }

    fn wsz(&mut self, text: &str) {
        for unit in text.encode_utf16() {
            self.u16(unit);
        }
        self.u16(0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn template_controls_are_dword_aligned_buttons() {
        let bytes = template();
        assert_eq!(bytes.len() % 4, 0);
        let count = u16::from_le_bytes([bytes[8], bytes[9]]);
        assert_eq!(count, 5);

        let mut index = 18;
        assert_eq!(u16_at(&bytes, index), 0);
        index += 2;
        assert_eq!(u16_at(&bytes, index), 0);
        index += 2;
        index = skip_wsz(&bytes, index);
        index += 2;
        index = skip_wsz(&bytes, index);
        while index % 4 != 0 {
            index += 1;
        }

        let mut ids = Vec::new();
        let mut titles = Vec::new();
        for _ in 0..count {
            assert_eq!(index % 4, 0, "control at {index}");
            ids.push(u16_at(&bytes, index + 16));
            assert_eq!(u16_at(&bytes, index + 18), 0xFFFF);
            assert_eq!(u16_at(&bytes, index + 20), BUTTON_CLASS);
            index += 22;
            let title = utf16_at(&bytes, index);
            index += (title.encode_utf16().count() + 1) * 2;
            titles.push(title);
            let extra = u16_at(&bytes, index) as usize;
            index += 2 + extra;
            while index % 4 != 0 {
                index += 1;
            }
        }
        assert_eq!(index, bytes.len());
        assert_eq!(titles, vec![
            "세벌식 390".to_owned(),
            "두벌식".to_owned(),
            "세벌식 최종".to_owned(),
            "확인".to_owned(),
            "취소".to_owned()
        ]);
        assert_eq!(ids, vec![100, 101, 102, IDOK, IDCANCEL]);
    }

    fn u16_at(bytes: &[u8], index: usize) -> u16 {
        u16::from_le_bytes([bytes[index], bytes[index + 1]])
    }

    fn skip_wsz(bytes: &[u8], mut index: usize) -> usize {
        while u16_at(bytes, index) != 0 {
            index += 2;
        }
        index + 2
    }

    fn utf16_at(bytes: &[u8], mut index: usize) -> String {
        let mut units = Vec::new();
        loop {
            let unit = u16_at(bytes, index);
            index += 2;
            if unit == 0 {
                break;
            }
            units.push(unit);
        }
        String::from_utf16(&units).expect("title")
    }
}
