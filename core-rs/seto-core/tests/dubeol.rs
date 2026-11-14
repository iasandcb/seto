//! Mirrors Tests/Sebeol390CoreTests/DubeolTests.swift. The Session-driven
//! tests in that file are covered by testdata/session-golden.json and are
//! ported with Session in phase 2.

mod common;

use common::compose_dubeol;
use seto_core::{Jamo, KeyOutput, KeyboardLayout, dubeol};

#[test]
fn dubeol_composition() {
    for (keys, expected) in [
        ("gksrmf", "한글"),
        ("dkssudgktpdy", "안녕하세요"),
        ("rkqt", "값"),
        ("rkqtdl", "값이"),
        ("rkrk", "가가"),
        ("rhk", "과"),
        ("Rk", "까"),
        ("rhkr", "곽"),
    ] {
        assert_eq!(compose_dubeol(keys), expected, "{keys}");
    }
}

#[test]
fn dubeol_composition_used_by_session_tests() {
    // Final text of dubeolSessionDeletion and the chat reactions / phrases
    // asserted through Session in DubeolTests.swift.
    for (keys, expected) in [
        ("gksrm", "한그"),
        ("gksr", "한ㄱ"),
        ("dd", "ㅇㅇ"),
        ("zz", "ㅋㅋ"),
        ("gg", "ㅎㅎ"),
        ("bb", "ㅠㅠ"),
        ("nn", "ㅜㅜ"),
        ("akdma", "마음"),
        ("emfdj", "들어"),
        ("akadp emfdjdy", "맘에 들어요"),
    ] {
        assert_eq!(compose_dubeol(keys), expected, "{keys}");
    }
}

#[test]
fn dubeol_atoms() {
    let atom = dubeol::atom('g');
    assert_eq!(atom.layout, KeyboardLayout::Dubeol);
    assert!(atom.is_dubeol());
    assert_eq!(atom.korean, KeyOutput::Jamo(Jamo::cho(0x1112)));
    assert_eq!(dubeol::atom('G').korean, KeyOutput::Jamo(Jamo::cho(0x1112)));
    assert_eq!(dubeol::atom('R').korean, KeyOutput::Jamo(Jamo::cho(0x1101)));
    assert_eq!(dubeol::atom('O').korean, KeyOutput::Jamo(Jamo::jung(0x1164)));
    assert_eq!(dubeol::atom('1').korean, KeyOutput::Character('1'));
    assert_eq!(dubeol::atom(' ').korean, KeyOutput::Character(' '));
    assert_eq!(dubeol::final_for_initial(Jamo::cho(0x1100)), Some(Jamo::jong(0x11A8)));
    assert_eq!(dubeol::final_for_initial(Jamo::cho(0x1104)), None);
    assert_eq!(dubeol::initial_for_final(Jamo::jong(0x11BA)), Some(Jamo::cho(0x1109)));
    assert_eq!(dubeol::initial_for_final(Jamo::jong(0x11AA)), None);
}
