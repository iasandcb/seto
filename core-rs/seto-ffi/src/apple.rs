//! Per-session lexicon, layout atoms, composition, and typo correction for Swift.
//! Android does not call these entry points.
use crate::{Result, failure};
use seto_core::{
    KeyAtom, KeyOutput, KeyboardLayout, Lexicon, LexiconWords, TypoCorrector, TypoMemory, compose, jamo_sequence,
    korean_endings, korean_verb_endings, preserves_boundary,
};
use std::path::Path;
use std::sync::Arc;

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum LayoutKind {
    Sebeol390,
    Dubeol,
    SebeolFinal,
}
impl From<LayoutKind> for KeyboardLayout {
    fn from(value: LayoutKind) -> Self {
        match value {
            LayoutKind::Sebeol390 => Self::Sebeol390,
            LayoutKind::Dubeol => Self::Dubeol,
            LayoutKind::SebeolFinal => Self::SebeolFinal,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum JamoPosition {
    Choseong,
    Jungseong,
    Jongseong,
}
impl From<JamoPosition> for seto_core::JamoKind {
    fn from(value: JamoPosition) -> Self {
        match value {
            JamoPosition::Choseong => Self::Choseong,
            JamoPosition::Jungseong => Self::Jungseong,
            JamoPosition::Jongseong => Self::Jongseong,
        }
    }
}
impl From<seto_core::JamoKind> for JamoPosition {
    fn from(value: seto_core::JamoKind) -> Self {
        match value {
            seto_core::JamoKind::Choseong => Self::Choseong,
            seto_core::JamoKind::Jungseong => Self::Jungseong,
            seto_core::JamoKind::Jongseong => Self::Jongseong,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum AtomReading {
    Jamo { scalar: u32, position: JamoPosition },
    Character { value: String },
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct Atom {
    pub layout: LayoutKind,
    pub english: String,
    pub korean: AtomReading,
}

pub(crate) fn one_char(text: &str) -> Result<char> {
    let mut chars = text.chars();
    let ch = chars.next().ok_or_else(|| failure("Expected one Unicode scalar"))?;
    if chars.next().is_some() {
        return Err(failure("Expected one Unicode scalar"));
    }
    Ok(ch)
}

pub(crate) fn to_key_atom(atom: Atom) -> Result<KeyAtom> {
    let english = one_char(&atom.english)?;
    let korean = match atom.korean {
        AtomReading::Jamo { scalar, position } => KeyOutput::Jamo(seto_core::Jamo::new(scalar, position.into())),
        AtomReading::Character { value } => KeyOutput::Character(one_char(&value)?),
    };
    Ok(KeyAtom { layout: atom.layout.into(), english, korean })
}

fn atoms(keys: Vec<Atom>) -> Result<Vec<KeyAtom>> {
    keys.into_iter().map(to_key_atom).collect()
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum Piece {
    Syllable,
    BareChoseong,
    BareJungseong,
    BareJongseong,
    Digit,
    Symbol,
}
impl From<seto_core::CompositionPiece> for Piece {
    fn from(value: seto_core::CompositionPiece) -> Self {
        use seto_core::CompositionPiece as P;
        match value {
            P::Syllable => Self::Syllable,
            P::BareChoseong => Self::BareChoseong,
            P::BareJungseong => Self::BareJungseong,
            P::BareJongseong => Self::BareJongseong,
            P::Digit => Self::Digit,
            P::Symbol => Self::Symbol,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct Composed {
    pub text: String,
    pub pieces: Vec<Piece>,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct JamoBits {
    pub scalar: u32,
    pub position: JamoPosition,
}

#[uniffi::export]
pub fn compose_atoms(keys: Vec<Atom>) -> Result<Composed> {
    let keys = atoms(keys)?;
    let composition = compose(&keys);
    Ok(Composed { text: composition.text, pieces: composition.pieces.into_iter().map(Into::into).collect() })
}

#[uniffi::export]
pub fn boundary_preserved(index: u32, keys: Vec<Atom>) -> Result<bool> {
    let keys = atoms(keys)?;
    Ok(preserves_boundary(index as usize, &keys))
}

#[uniffi::export]
pub fn sequence_jamo(keys: Vec<Atom>) -> Result<Option<Vec<JamoBits>>> {
    let keys = atoms(keys)?;
    Ok(jamo_sequence(&keys)
        .map(|seq| seq.into_iter().map(|jamo| JamoBits { scalar: jamo.scalar, position: jamo.kind.into() }).collect()))
}

/// Synchronous typo log. Called while the session lock is held; the Swift
/// implementation must not re-enter the same `FieldSession`.
#[uniffi::export(callback_interface)]
pub trait TypoStore: Send + Sync {
    fn record(&self, wrong: String, wrong_keys: String, final_text: String, final_keys: String);
    fn unique_final(&self, wrong: String) -> Option<String>;
}

pub(crate) struct DirectStore {
    pub(crate) store: Box<dyn TypoStore>,
}
impl TypoMemory for DirectStore {
    fn record(&self, wrong: &str, wrong_keys: &str, final_text: &str, final_keys: &str) {
        self.store.record(wrong.into(), wrong_keys.into(), final_text.into(), final_keys.into());
    }
    fn unique_final(&self, wrong: &str) -> Option<String> {
        self.store.unique_final(wrong.into())
    }
}

#[derive(uniffi::Object)]
pub struct SharedLexicon {
    inner: Arc<Lexicon>,
}
impl SharedLexicon {
    pub(crate) fn lexicon(&self) -> Arc<Lexicon> {
        self.inner.clone()
    }
}
#[uniffi::export]
impl SharedLexicon {
    #[uniffi::constructor]
    pub fn from_directory(directory: String) -> Result<Arc<Self>> {
        let lexicon = Lexicon::load(Path::new(&directory)).map_err(|error| failure(error.to_string()))?;
        Ok(Arc::new(Self { inner: Arc::new(lexicon) }))
    }
    #[uniffi::constructor]
    pub fn for_keyboard(directory: String) -> Result<Arc<Self>> {
        let lexicon = Lexicon::load_for_keyboard(Path::new(&directory)).map_err(|error| failure(error.to_string()))?;
        Ok(Arc::new(Self { inner: Arc::new(lexicon) }))
    }
    #[uniffi::constructor]
    pub fn from_lists(
        english: Vec<String>,
        korean: Vec<String>,
        abbreviations: Vec<String>,
        tech_stems: Vec<String>,
        valid_korean: Vec<String>,
    ) -> Arc<Self> {
        let lexicon = Lexicon::from_words(LexiconWords {
            english: &refs(&english),
            korean: &refs(&korean),
            abbreviations: &refs(&abbreviations),
            tech_stems: &refs(&tech_stems),
            valid_korean: &refs(&valid_korean),
        });
        Arc::new(Self { inner: Arc::new(lexicon) })
    }
}
fn refs(words: &[String]) -> Vec<&str> {
    words.iter().map(String::as_str).collect()
}

#[uniffi::export]
pub fn correct_typo(
    composed: String,
    keys: Vec<Atom>,
    language: crate::Language,
    lexicon: Arc<SharedLexicon>,
    memory: Option<Box<dyn TypoStore>>,
) -> Result<Option<String>> {
    let keys = atoms(keys)?;
    let memory = memory.map(|store| DirectStore { store });
    Ok(TypoCorrector::correction(
        &composed,
        &keys,
        language.into(),
        lexicon.inner.as_ref(),
        memory.as_ref().map(|memory| memory as &dyn TypoMemory),
    ))
}

#[uniffi::export]
pub fn keystrokes_for(word: String, layout: LayoutKind) -> Option<String> {
    TypoCorrector::keystrokes(&word, layout.into())
}

#[uniffi::export]
pub fn korean_ending_table() -> Vec<String> {
    korean_endings::LONGEST_FIRST.into_iter().map(str::to_owned).collect()
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct EndingSplit {
    pub stem: String,
    pub ending: String,
}

#[uniffi::export]
pub fn split_korean_ending(word: String) -> Option<EndingSplit> {
    korean_endings::split(&word).map(|(stem, ending)| EndingSplit { stem: stem.to_owned(), ending: ending.to_owned() })
}

#[uniffi::export]
pub fn verb_ending_table() -> Vec<String> {
    korean_verb_endings::LONGEST_FIRST.into_iter().map(str::to_owned).collect()
}

#[uniffi::export(callback_interface)]
pub trait KnownStem: Send + Sync {
    fn is_known(&self, word: String) -> bool;
}

#[uniffi::export]
pub fn verb_is_inflected(word: String, known: Box<dyn KnownStem>) -> bool {
    korean_verb_endings::is_inflected(&word, |stem| known.is_known(stem.to_owned()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{FieldSession, Language};

    #[test]
    fn opened_session_keeps_its_lexicon_and_layout() {
        let lexicon = SharedLexicon::from_lists(vec!["hello".into()], vec!["안녕".into()], vec![], vec![], vec![]);
        let session = FieldSession::open(lexicon, false, Language::Korean, LayoutKind::Sebeol390, None);
        for ch in "kf ".chars() {
            session.input(ch.to_string()).unwrap();
        }
        let state = session.state().unwrap();
        assert_eq!(state.document, "가 ");
        assert!(session.debug_line().unwrap().contains("가 "));
    }

    fn jamo(layout: LayoutKind, english: char, scalar: u32, position: JamoPosition) -> Atom {
        Atom { layout, english: english.to_string(), korean: AtomReading::Jamo { scalar, position } }
    }

    #[test]
    fn one_key_korean_typo_uses_the_lexicon() {
        let lexicon = SharedLexicon::from_lists(vec![], vec!["한글".into(), "맑다".into()], vec![], vec![], vec![]);
        let typed = vec![
            jamo(LayoutKind::Sebeol390, 'm', 0x1112, JamoPosition::Choseong),
            jamo(LayoutKind::Sebeol390, 'f', 0x1161, JamoPosition::Jungseong),
            jamo(LayoutKind::Sebeol390, 's', 0x11AB, JamoPosition::Jongseong),
            jamo(LayoutKind::Sebeol390, 'k', 0x1100, JamoPosition::Choseong),
            jamo(LayoutKind::Sebeol390, 'b', 0x116E, JamoPosition::Jungseong),
            jamo(LayoutKind::Sebeol390, 'w', 0x11AF, JamoPosition::Jongseong),
        ];
        assert_eq!(
            correct_typo("한굴".into(), typed, Language::Korean, lexicon.clone(), None).unwrap().as_deref(),
            Some("한글")
        );
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let resources = SharedLexicon::from_directory(root.join("Resources").to_string_lossy().into()).unwrap();
        let session = FieldSession::open(resources, true, Language::Korean, LayoutKind::Sebeol390, None);
        // gitdms as dubeol atoms, while the session's own layout stays 390.
        let dubeol = [
            ('g', 0x1112u32, JamoPosition::Choseong),
            ('i', 0x1163, JamoPosition::Jungseong),
            ('t', 0x1109, JamoPosition::Choseong),
            ('d', 0x110B, JamoPosition::Choseong),
            ('m', 0x1173, JamoPosition::Jungseong),
            ('s', 0x1102, JamoPosition::Choseong),
            (' ', 0, JamoPosition::Choseong),
        ];
        for (index, (english, scalar, position)) in dubeol.into_iter().enumerate() {
            let update = if english == ' ' {
                session
                    .input_atom(Atom {
                        layout: LayoutKind::Dubeol,
                        english: " ".into(),
                        korean: AtomReading::Character { value: " ".into() },
                    })
                    .unwrap()
            } else {
                session.input_atom(jamo(LayoutKind::Dubeol, english, scalar, position)).unwrap()
            };
            if index == 2 {
                assert_eq!(update.preedit, "", "{:?}", session.debug_line());
            }
        }
        assert_eq!(session.state().unwrap().document, "git은 ", "{:?}", session.debug_line());
        let clear = SharedLexicon::from_lists(vec![], vec!["맑다".into()], vec![], vec![], vec![]);
        let typed_final = "if!uf"
            .chars()
            .map(|key| {
                let atom = seto_core::KeyboardLayout::SebeolFinal.atom(key);
                let korean = match atom.korean {
                    seto_core::KeyOutput::Jamo(jamo) => {
                        AtomReading::Jamo { scalar: jamo.scalar, position: jamo.kind.into() }
                    }
                    seto_core::KeyOutput::Character(character) => {
                        AtomReading::Character { value: character.to_string() }
                    }
                };
                Atom { layout: LayoutKind::SebeolFinal, english: key.to_string(), korean }
            })
            .collect();
        let fixed = correct_typo("맊다".into(), typed_final, Language::Korean, clear, None).unwrap();
        assert_eq!(fixed.as_deref(), Some("맑다"));
    }

    #[test]
    fn compose_and_endings_match_the_core() {
        let keys = vec![
            Atom {
                layout: LayoutKind::Sebeol390,
                english: "k".into(),
                korean: AtomReading::Jamo { scalar: 0x1100, position: JamoPosition::Choseong },
            },
            Atom {
                layout: LayoutKind::Sebeol390,
                english: "f".into(),
                korean: AtomReading::Jamo { scalar: 0x1161, position: JamoPosition::Jungseong },
            },
        ];
        assert_eq!(compose_atoms(keys).unwrap().text, "가");
        assert_eq!(
            split_korean_ending("공부하다".into()).unwrap(),
            EndingSplit { stem: "공부".into(), ending: "하다".into() }
        );
        assert!(korean_ending_table().iter().any(|ending| ending == "만"));
        struct Known;
        impl KnownStem for Known {
            fn is_known(&self, word: String) -> bool {
                word == "먹"
            }
        }
        assert!(verb_is_inflected("먹기".into(), Box::new(Known)));
        assert_eq!(keystrokes_for("가".into(), LayoutKind::Dubeol).as_deref(), Some("rk"));
    }
}
