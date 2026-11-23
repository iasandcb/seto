mod common;

use seto_core::{CompositionPiece, KeyboardLayout, Lexicon, Session, SessionOptions, compose, layout390};
use std::sync::Arc;

fn sticks_as_korean(text: &str) -> bool {
    let atoms: Vec<_> = text.chars().map(layout390::atom).collect();
    let mut pieces = compose(&atoms).pieces;
    if pieces.last() == Some(&CompositionPiece::BareChoseong) {
        pieces.pop();
    }
    pieces.contains(&CompositionPiece::Syllable)
        && pieces.iter().all(|piece| matches!(piece, CompositionPiece::Syllable | CompositionPiece::Digit))
}

fn clean_syllables(text: &str) -> usize {
    let atoms: Vec<_> = text.chars().map(layout390::atom).collect();
    let pieces = compose(&atoms).pieces;
    if pieces.is_empty() || pieces.iter().any(|piece| *piece != CompositionPiece::Syllable) { 0 } else { pieces.len() }
}

fn hides_hangul(lexicon: &Lexicon, word: &str) -> bool {
    let chars: Vec<char> = word.chars().collect();
    if chars.len() < 6 {
        return false;
    }
    for start in 3..(chars.len() - 2) {
        let stem: String = chars[..start].iter().collect();
        if !lexicon.is_english_word(&stem) {
            continue;
        }
        let tail: String = chars[start..start + 3].iter().collect();
        if clean_syllables(&tail) == 1 {
            return true;
        }
    }
    false
}

/// Swift `commonEnglishWordsDoNotFlipMidWord`. A buffer that is still a
/// syllable, or a syllable plus the next choseong, stays Hangul. `lean` inside
/// `leaning` and `heal` inside `health` are the shape that was flipping early.
#[test]
fn common_english_words_do_not_flip_mid_word() {
    let lexicon = Arc::new(Lexicon::load(&common::resources()).unwrap());
    let mut words = Vec::new();
    let mut seen = std::collections::BTreeSet::new();
    let mut add = |word: &str| {
        let key = word.to_lowercase();
        if key.chars().count() < 3 || !key.chars().all(char::is_alphabetic) || !seen.insert(key.clone()) {
            return;
        }
        words.push(key);
    };
    for path in ["english-extra.txt", "english-words.txt"] {
        let text = std::fs::read_to_string(common::resources().join(path)).unwrap();
        for line in text.lines() {
            let word = line.trim();
            if word.is_empty() || word.starts_with('#') {
                continue;
            }
            let count = word.chars().count();
            if path.ends_with("extra.txt")
                || (3..=6).contains(&count)
                || ((7..=14).contains(&count) && hides_hangul(&lexicon, word))
            {
                add(word);
            }
        }
    }
    let mut failures = Vec::new();
    for word in &words {
        let mut session = Session::with_options(
            Arc::clone(&lexicon),
            SessionOptions { layout: KeyboardLayout::Sebeol390, ..SessionOptions::default() },
        );
        let mut typed = String::new();
        let mut latin = false;
        let mut failed = false;
        for character in word.chars() {
            typed.push(character);
            session.input_char(character);
            if sticks_as_korean(&typed) {
                let atoms: Vec<_> = typed.chars().map(layout390::atom).collect();
                let korean = compose(&atoms).text;
                if session.document() != korean {
                    failures.push(format!("{word} [{typed}] 한글 {} / {korean}", session.document()));
                    failed = true;
                    break;
                }
                latin = false;
                continue;
            }
            let plausible = lexicon.is_english_word(&typed) || lexicon.is_english_prefix(&typed);
            if session.document() == typed {
                latin = true;
            } else if latin && plausible {
                failures.push(format!("{word} [{typed}] → {}", session.document()));
                failed = true;
                break;
            }
        }
        if !failed && session.document() != *word {
            let atoms: Vec<_> = word.chars().map(layout390::atom).collect();
            let korean = compose(&atoms).text;
            if session.document() != korean {
                failures.push(format!("끝 {word} → {}", session.document()));
            }
        }
    }
    let report = failures.iter().take(40).cloned().collect::<Vec<_>>().join("\n");
    assert!(failures.is_empty(), "{} failures\n{report}", failures.len());
}
