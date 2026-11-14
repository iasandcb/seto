//! Mirrors Tests/Sebeol390CoreTests/LayoutTests.swift.

use seto_core::{JamoKind, KeyOutput, keymap, layout390};

fn expect_jamo(key: char, kind: JamoKind, compat: char) {
    match layout390::atom(key).korean {
        KeyOutput::Jamo(jamo) => {
            assert_eq!(jamo.kind, kind, "{key}");
            assert_eq!(jamo.compat(), compat, "{key}");
        }
        other => panic!("{key} produced {other:?}"),
    }
}

fn expect_char(key: char, expected: char) {
    match layout390::atom(key).korean {
        KeyOutput::Character(character) => assert_eq!(character, expected, "{key}"),
        other => panic!("{key} produced {other:?}"),
    }
}

#[test]
fn choseong_keys() {
    for (key, compat) in [
        ('k', 'ㄱ'),
        ('u', 'ㄷ'),
        ('j', 'ㅇ'),
        ('l', 'ㅈ'),
        ('y', 'ㄹ'),
        ('h', 'ㄴ'),
        ('i', 'ㅁ'),
        (';', 'ㅂ'),
        ('n', 'ㅅ'),
        ('o', 'ㅊ'),
        ('0', 'ㅋ'),
        ('\'', 'ㅌ'),
        ('p', 'ㅍ'),
        ('m', 'ㅎ'),
    ] {
        expect_jamo(key, JamoKind::Choseong, compat);
    }
}

#[test]
fn jungseong_keys() {
    for (key, compat) in [
        ('f', 'ㅏ'),
        ('r', 'ㅐ'),
        ('6', 'ㅑ'),
        ('R', 'ㅒ'),
        ('t', 'ㅓ'),
        ('e', 'ㅕ'),
        ('c', 'ㅔ'),
        ('7', 'ㅖ'),
        ('v', 'ㅗ'),
        ('/', 'ㅗ'),
        ('4', 'ㅛ'),
        ('b', 'ㅜ'),
        ('9', 'ㅜ'),
        ('5', 'ㅠ'),
        ('g', 'ㅡ'),
        ('8', 'ㅢ'),
        ('d', 'ㅣ'),
    ] {
        expect_jamo(key, JamoKind::Jungseong, compat);
    }
}

#[test]
fn jongseong_keys() {
    for (key, compat) in [
        ('x', 'ㄱ'),
        ('F', 'ㄲ'),
        ('s', 'ㄴ'),
        ('S', 'ㄶ'),
        ('A', 'ㄷ'),
        ('w', 'ㄹ'),
        ('D', 'ㄺ'),
        ('C', 'ㄻ'),
        ('V', 'ㅀ'),
        ('z', 'ㅁ'),
        ('3', 'ㅂ'),
        ('X', 'ㅄ'),
        ('q', 'ㅅ'),
        ('2', 'ㅆ'),
        ('a', 'ㅇ'),
        ('!', 'ㅈ'),
        ('Z', 'ㅊ'),
        ('E', 'ㅋ'),
        ('W', 'ㅌ'),
        ('Q', 'ㅍ'),
        ('1', 'ㅎ'),
    ] {
        expect_jamo(key, JamoKind::Jongseong, compat);
    }
}

#[test]
fn six_relocated_symbols() {
    expect_char('B', '!');
    expect_char('G', '/');
    expect_char('T', ';');
    expect_char('Y', '<');
    expect_char('P', '>');
    expect_char('H', '\'');
    expect_jamo('!', JamoKind::Jongseong, 'ㅈ');
    expect_jamo('/', JamoKind::Jungseong, 'ㅗ');
    expect_jamo(';', JamoKind::Choseong, 'ㅂ');
    expect_char('<', '2');
    expect_char('>', '3');
    expect_jamo('\'', JamoKind::Choseong, 'ㅌ');
}

#[test]
fn shifted_digits() {
    for (key, digit) in [
        ('U', '7'),
        ('I', '8'),
        ('O', '9'),
        ('J', '4'),
        ('K', '5'),
        ('L', '6'),
        ('M', '1'),
        ('<', '2'),
        ('>', '3'),
        ('N', '0'),
    ] {
        expect_char(key, digit);
    }
}

#[test]
fn unchanged_punctuation() {
    for character in "`-=[]\\,.".chars().chain("~@#$%^&*()_+{}|:\"?".chars()) {
        expect_char(character, character);
    }
    expect_char(' ', ' ');
}

#[test]
fn every_letter_is_mapped() {
    for letter in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".chars() {
        assert!(layout390::contains(letter), "missing {letter}");
    }
}

#[test]
fn unmapped_keys_pass_through() {
    assert!(!layout390::contains('€'));
    expect_char('€', '€');
    expect_char('\n', '\n');
}

#[test]
fn keymap_matches_qwerty_positions() {
    assert_eq!(keymap::qwerty_character(0x00, false), Some('a'));
    assert_eq!(keymap::qwerty_character(0x00, true), Some('A'));
    assert_eq!(keymap::qwerty_character(0x0C, false), Some('q'));
    assert_eq!(keymap::qwerty_character(0x12, true), Some('!'));
    assert_eq!(keymap::qwerty_character(0x2C, false), Some('/'));
    assert_eq!(keymap::qwerty_character(0x2B, true), Some('<'));
    assert_eq!(keymap::qwerty_character(0x31, false), Some(' '));
    assert_eq!(keymap::qwerty_character(0x17, false), Some('5'));
    assert_eq!(keymap::qwerty_character(0x17, true), Some('%'));
    assert_eq!(keymap::qwerty_character(0x24, false), None);
    assert!(keymap::is_navigation(0x7D));
    assert!(keymap::is_navigation(0x7B));
    assert!(keymap::is_navigation(0x7C));
    assert!(keymap::is_navigation(0x7E));
    assert!(keymap::is_navigation(keymap::TAB));
    assert!(keymap::is_navigation(keymap::ESCAPE));
    assert!(keymap::is_navigation(keymap::RETURN));
    assert!(!keymap::is_navigation(0x07));
}
