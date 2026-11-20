//! Hangul composition from 390, 최종, and 두벌식 key atoms.

use crate::hangul::{self, Jamo, JamoKind};
use crate::layout::{KeyAtom, KeyOutput, dubeol};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum CompositionPiece {
    Syllable,
    BareChoseong,
    BareJungseong,
    BareJongseong,
    Digit,
    Symbol,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Composition {
    pub text: String,
    pub pieces: Vec<CompositionPiece>,
}

impl Composition {
    pub fn syllable_count(&self) -> usize {
        self.pieces.iter().filter(|piece| **piece == CompositionPiece::Syllable).count()
    }
}

/// A split is safe only when both sides compose exactly as they did together,
/// including doubled initials and compound vowels/finals.
pub fn preserves_boundary(index: usize, atoms: &[KeyAtom]) -> bool {
    if index == 0 || index >= atoms.len() {
        return true;
    }
    let whole = compose(atoms).text;
    let mut split = compose(&atoms[..index]).text;
    split.push_str(&compose(&atoms[index..]).text);
    whole == split
}

pub fn compose<'a, I>(atoms: I) -> Composition
where
    I: IntoIterator<Item = &'a KeyAtom>,
{
    let mut engine = Engine::default();
    for atom in atoms {
        match atom.korean {
            KeyOutput::Jamo(jamo) => {
                if atom.is_dubeol() {
                    engine.push_dubeol(jamo)
                } else {
                    engine.push(jamo)
                }
            }
            KeyOutput::Character(character) => engine.push_character(character),
        }
    }
    engine.flush();
    Composition { text: engine.text, pieces: engine.pieces }
}

/// Merged jamo in composition order. `None` when a key is not jamo, so a digit
/// or symbol is not compared as Hangul. ㄲ typed as ㄱㄱ is one unit.
pub fn jamo_sequence<'a, I>(atoms: I) -> Option<Vec<Jamo>>
where
    I: IntoIterator<Item = &'a KeyAtom>,
{
    let mut engine = Engine::default();
    for atom in atoms {
        match atom.korean {
            KeyOutput::Jamo(jamo) => {
                if atom.is_dubeol() {
                    engine.push_dubeol(jamo)
                } else {
                    engine.push(jamo)
                }
            }
            KeyOutput::Character(_) => return None,
        }
    }
    engine.flush();
    Some(engine.units)
}

#[derive(Default)]
struct Engine {
    cho: Vec<Jamo>,
    jung: Vec<Jamo>,
    jong: Vec<Jamo>,
    text: String,
    pieces: Vec<CompositionPiece>,
    units: Vec<Jamo>,
}

impl Engine {
    fn push(&mut self, jamo: Jamo) {
        match jamo.kind {
            JamoKind::Choseong => {
                if self.jung.is_empty() && self.jong.is_empty() {
                    if self.cho.is_empty() {
                        self.cho = vec![jamo];
                    } else if can_append(&self.cho, jamo) {
                        self.cho.push(jamo);
                    } else {
                        self.flush();
                        self.cho = vec![jamo];
                    }
                } else {
                    self.flush();
                    self.cho = vec![jamo];
                }
            }
            JamoKind::Jungseong => {
                if !self.jong.is_empty() {
                    self.flush();
                    self.jung = vec![jamo];
                } else if self.jung.is_empty() {
                    self.jung = vec![jamo];
                } else if can_append(&self.jung, jamo) {
                    self.jung.push(jamo);
                } else {
                    self.flush();
                    self.jung = vec![jamo];
                }
            }
            JamoKind::Jongseong => {
                if !self.jung.is_empty() {
                    if self.jong.is_empty() {
                        self.jong = vec![jamo];
                    } else if can_append(&self.jong, jamo) {
                        self.jong.push(jamo);
                    } else {
                        self.flush();
                        self.jong = vec![jamo];
                    }
                } else {
                    if !self.cho.is_empty() || !self.jong.is_empty() {
                        self.flush();
                    }
                    self.jong = vec![jamo];
                }
            }
        }
    }

    fn push_dubeol(&mut self, jamo: Jamo) {
        if jamo.kind == JamoKind::Jungseong {
            if let Some(last) = self.jong.pop() {
                // The last final becomes the next initial; earlier finals stay.
                let initial = dubeol::initial_for_final(last);
                self.flush();
                if let Some(initial) = initial {
                    self.cho = vec![initial];
                }
            }
            self.push(jamo);
            return;
        }
        if !self.jung.is_empty()
            && let Some(last) = dubeol::final_for_initial(jamo)
        {
            if self.jong.is_empty() {
                self.jong = vec![last];
                return;
            }
            if can_append(&self.jong, last) {
                self.jong.push(last);
                return;
            }
        }
        self.flush();
        self.cho = vec![jamo];
    }

    fn push_character(&mut self, character: char) {
        self.flush();
        self.text.push(character);
        if character.is_numeric() {
            self.pieces.push(CompositionPiece::Digit);
        } else if !character.is_whitespace() {
            self.pieces.push(CompositionPiece::Symbol);
        }
    }

    fn flush(&mut self) {
        self.render_open();
        for parts in [&self.cho, &self.jung, &self.jong] {
            if let Some(unit) = combined(parts) {
                self.units.push(unit);
            }
        }
        self.cho.clear();
        self.jung.clear();
        self.jong.clear();
    }

    fn render_open(&mut self) {
        let cho = combined(&self.cho);
        let jung = combined(&self.jung);
        let jong = combined(&self.jong);
        if let (Some(cho), Some(jung)) = (cho, jung) {
            self.text.push(hangul::syllable(cho.scalar, jung.scalar, jong.map(|j| j.scalar)));
            self.pieces.push(CompositionPiece::Syllable);
            return;
        }
        if let Some(cho) = cho {
            self.text.push(cho.compat());
            self.pieces.push(CompositionPiece::BareChoseong);
        }
        if let Some(jung) = jung {
            self.text.push(jung.compat());
            self.pieces.push(CompositionPiece::BareJungseong);
        }
        if let Some(jong) = jong {
            self.text.push(jong.compat());
            self.pieces.push(CompositionPiece::BareJongseong);
        }
    }
}

fn can_append(parts: &[Jamo], next: Jamo) -> bool {
    combined(parts).is_some_and(|current| hangul::merge(current, next).is_some())
}

fn combined(parts: &[Jamo]) -> Option<Jamo> {
    let (first, rest) = parts.split_first()?;
    rest.iter().try_fold(*first, |acc, part| hangul::merge(acc, *part))
}
