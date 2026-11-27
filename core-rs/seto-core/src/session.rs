//! Korean/English session: composition, auto-switch, and typo correction.
//!
//! `tests/golden_replay.rs` replays the checked-in session corpus against
//! this implementation, call by call.
//!
//! Swift `Character` properties map to `char` as follows: `isLetter` is
//! `is_alphabetic`, `isNumber` is `is_numeric`, `isUppercase` /
//! `isLowercase` are `is_uppercase` / `is_lowercase`. A key is one `char`,
//! so `String.count` of a key spelling is its number of `char`s.

use std::cell::RefCell;
use std::sync::Arc;

use unicode_segmentation::UnicodeSegmentation;

use crate::composer::{CompositionPiece, compose, preserves_boundary};
use crate::hangul::{self, JamoKind};
use crate::layout::{KeyAtom, KeyOutput, KeyboardLayout};
use crate::lexicon::Lexicon;
use crate::session_types::{FieldEdit, Language, SessionUpdate, utf16_len};
use crate::typo_corrector::{TypoCorrector, korean_endings};
use crate::typo_log::{TypoLogPolicy, TypoMemory};

pub struct InputGate;

impl InputGate {
    pub fn should_pass_through(secure_input: bool, command: bool, control: bool, option: bool) -> bool {
        secure_input || command || control || option
    }
}

/// Everything `Session.init` takes besides the lexicon, with Swift's defaults.
#[derive(Clone)]
pub struct SessionOptions {
    pub auto_switch: bool,
    /// Initial confirmed language.
    pub mode: Language,
    pub typos: Option<Arc<dyn TypoMemory>>,
    pub layout: KeyboardLayout,
}

impl Default for SessionOptions {
    fn default() -> Self {
        SessionOptions { auto_switch: true, mode: Language::Korean, typos: None, layout: KeyboardLayout::Sebeol390 }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Segment {
    start: usize,
    end: usize,
    lang: Language,
}

#[derive(Clone, Copy)]
struct ReadingQuality {
    score: i64,
    solid: bool,
}

#[derive(Clone, Copy)]
struct Path {
    score: i64,
    prev: usize,
    lang: Language,
}

struct Undo {
    keys: Vec<KeyAtom>,
    segments: Vec<Segment>,
    committed_suffix: Option<String>,
}

struct Rejection {
    keys: Vec<KeyAtom>,
    text: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Shape {
    Invalid,
    SingleBare,
    Trailing(usize),
    Digits,
    Clean(usize),
    Symbol,
}

fn is_bare_piece(piece: CompositionPiece) -> bool {
    matches!(piece, CompositionPiece::BareChoseong | CompositionPiece::BareJungseong | CompositionPiece::BareJongseong)
}

fn shape_of(pieces: &[CompositionPiece]) -> Shape {
    if pieces.is_empty() {
        return Shape::Invalid;
    }
    if pieces.iter().all(|piece| *piece == CompositionPiece::Symbol) {
        return if pieces.len() == 1 { Shape::Symbol } else { Shape::Invalid };
    }
    if pieces.contains(&CompositionPiece::Symbol) {
        return Shape::Invalid;
    }
    if pieces.iter().all(|piece| *piece == CompositionPiece::Digit) {
        return Shape::Digits;
    }
    if pieces.len() == 1 && is_bare_piece(pieces[0]) {
        return Shape::SingleBare;
    }

    let mut body = pieces;
    let mut trailing = false;
    if body.last() == Some(&CompositionPiece::BareChoseong) {
        body = &body[..body.len() - 1];
        trailing = true;
    }
    if body.iter().any(|piece| is_bare_piece(*piece)) {
        return Shape::Invalid;
    }
    if !body.iter().all(|piece| matches!(piece, CompositionPiece::Syllable | CompositionPiece::Digit)) {
        return Shape::Invalid;
    }
    let syllables = body.iter().filter(|piece| **piece == CompositionPiece::Syllable).count();
    match (trailing, syllables > 0) {
        (true, true) => Shape::Trailing(syllables),
        (false, true) => Shape::Clean(syllables),
        _ => Shape::Invalid,
    }
}

mod code_token {
    /// Breakers that stay inside a filename, URL, email, or identifier.
    pub fn is_joiner(character: char) -> bool {
        matches!(character, '.' | ':' | '@' | '_' | '-' | '+' | '?' | '=' | '&' | '%' | '#')
    }

    /// A lone bare jamo plus one of these is a dotted label ("a.b"), not a word.
    pub fn is_starter(character: char) -> bool {
        matches!(character, '.' | ':' | '@' | '_' | '-' | '+')
    }

    /// Same as joiners, plus "/" which is already inside the token (it is ㅗ on 390).
    pub fn is_interior(character: char) -> bool {
        character == '/' || is_joiner(character)
    }
}

mod scoring {
    /// How far a new segmentation must lead before it replaces the reading
    /// already on screen.
    pub const MARGIN: i64 = 28;
    /// Cost of a language change inside one token.
    pub const SWITCH_PENALTY: i64 = 48;
    /// Cost of every extra piece. Without this, 하+ㄴ outscores 한.
    pub const JOIN_PENALTY: i64 = 64;
    pub const MODE_BONUS: i64 = 16;
    pub const MAX_SEGMENT: usize = 24;
}

/// Particles and short endings that attach to a word with no space.
fn is_particle(text: &str) -> bool {
    korean_endings::contains(text)
}

/// Everyday 해요체 whose 두벌식 spelling is not a common English word.
/// `sody` is only a US dialect of soda, so 내요 wins in either mode.
/// Real English words that also end in a 요 reading (`giddy` → 향요,
/// `wordy` → 잭요, `world` → 재깅) are not in this set.
fn is_common_polite_yo(text: &str) -> bool {
    matches!(text, "내요" | "해요" | "돼요" | "되요" | "가요")
}

/// Short words that are a real English word and also a Hangul reading.
/// `of` is 차. Preserve an explicit undo reading for English context.
const ENGLISH_CONTEXT_WORDS: [&str; 21] = [
    "of", "to", "in", "is", "it", "on", "at", "as", "or", "if", "an", "be", "do", "go", "no", "so", "up", "we", "me",
    "my", "the",
];

/// Short heads that may keep a Hangul particle (`ktx는`, `api를`).
/// A 3-letter Webster hit such as "jfk" is not enough: it steals the
/// first ㄱ of 까.
const ACRONYM_HEADS: [&str; 14] =
    ["ktx", "srt", "api", "url", "mvp", "sdk", "llm", "gpt", "nlp", "cpu", "gpu", "html", "css", "aws"];

const NUMBER_COUNTERS: [&str; 43] = [
    "개", "대", "명", "분", "번", "회", "권", "장", "잔", "병", "마리", "살", "세", "년", "월", "일", "시", "초", "원",
    "층", "곳", "쪽", "줄", "주", "달", "점", "등", "차", "위", "배", "평", "건", "통", "벌", "편", "판", "호", "부",
    "단", "곡", "번째", "가지", "켤레",
];

fn is_acronym_head(lower: &str) -> bool {
    ACRONYM_HEADS.contains(&lower)
}

/// ㅅ for 시·살·세: the bare initial of a counter's first syllable.
fn is_counter_initial(text: &str) -> bool {
    const INITIALS: [char; 19] = [
        'ㄱ', 'ㄲ', 'ㄴ', 'ㄷ', 'ㄸ', 'ㄹ', 'ㅁ', 'ㅂ', 'ㅃ', 'ㅅ', 'ㅆ', 'ㅇ', 'ㅈ', 'ㅉ', 'ㅊ', 'ㅋ', 'ㅌ', 'ㅍ',
        'ㅎ',
    ];
    let mut characters = text.chars();
    let (Some(only), None) = (characters.next(), characters.next()) else { return false };
    NUMBER_COUNTERS.iter().any(|counter| {
        counter.chars().next().is_some_and(|first| {
            let scalar = first as u32;
            (0xAC00..=0xD7A3).contains(&scalar) && INITIALS[((scalar - 0xAC00) / 588) as usize] == only
        })
    })
}

/// 8시, 3월에, 10개는: a counter, optionally followed by a particle.
fn starts_with_counter(text: &str) -> bool {
    NUMBER_COUNTERS
        .iter()
        .any(|counter| text.strip_prefix(counter).is_some_and(|rest| rest.is_empty() || is_particle(rest)))
}

/// Common chat jamo typed from English mode: j0 → ㅇㅋ, kn → ㄱㅅ.
/// A run with no letter key ("00", "55") stays a number, and real English
/// words, prefixes, abbreviations, and code tokens stay English.
const CHAT_REACTIONS: [&str; 7] = ["ㅇㅋ", "ㄱㅅ", "ㅇㅇ", "ㄴㄴ", "ㅊㅋ", "ㅈㅅ", "ㅎㅇ"];

fn has_vowel(lower: &str) -> bool {
    lower.chars().any(|character| "aeiou".contains(character))
}

fn all_same_from(text: &str, allowed: &str) -> bool {
    let Some(first) = text.chars().next() else { return false };
    text.chars().all(|character| character == first) && allowed.contains(first)
}

/// Bare jamo typed as a chat mark: ㅎㅎ, ㅋㅋ, ㅠㅠ, ㅜㅜ, ㄱㄱ, ㅇㅇ, ㄴㄴ,
/// ㅡㅡ, and the short reactions (ㄱㅅ, ㅇㅋ, ㅇㅋㅋ). One doubled choseong
/// (ㄲ) is a single jamo and is not a mark.
fn is_chat_mark_text(text: &str) -> bool {
    if text.chars().count() < 2 {
        return false;
    }
    let repeated = all_same_from(text, "ㅋㅎㅠㅜㅇㄱㄴㅡ");
    let extended_ok = text
        .strip_prefix("ㅇㅋ")
        .is_some_and(|rest| !rest.is_empty() && rest.chars().all(|character| character == 'ㅋ'));
    repeated || extended_ok || CHAT_REACTIONS.contains(&text)
}

/// Shifted key whose 390 output is a digit or symbol, not a jamo.
/// "I" is 8, "H" is "'", "P" is ">".
fn is_shifted_letter(atom: &KeyAtom) -> bool {
    atom.english.is_alphabetic() && atom.english.is_uppercase() && matches!(atom.korean, KeyOutput::Character(_))
}

/// Shifted letter whose Korean reading is punctuation, not a digit.
/// 390: B !, T ;, Y <, P >, G /, H '.
fn is_shifted_symbol(atom: &KeyAtom) -> bool {
    is_shifted_letter(atom)
        && matches!(atom.korean, KeyOutput::Character(character) if !character.is_alphabetic() && !character.is_numeric())
}

/// Every key is the same shifted punctuation key. Shift+B twice is `!!`,
/// not the two-letter acronym BB.
fn is_repeated_shifted_symbol(atoms: &[KeyAtom]) -> bool {
    let Some(first) = atoms.first() else { return false };
    atoms.len() >= 2
        && is_shifted_symbol(first)
        && atoms.iter().all(|atom| atom.english == first.english && atom.korean == first.korean)
}

fn is_pad_digit(atom: &KeyAtom) -> bool {
    matches!(atom.korean, KeyOutput::Character(character) if character.is_numeric())
}

fn is_separator(atom: &KeyAtom) -> bool {
    atom.english == '.' || atom.english == ','
}

fn extend(parts: &[Segment], count: usize) -> Option<Vec<Segment>> {
    let last = *parts.last()?;
    if last.end == count {
        return Some(parts.to_vec());
    }
    if last.end + 1 != count || last.start >= count {
        return None;
    }
    let mut copy = parts.to_vec();
    copy[parts.len() - 1].end = count;
    Some(copy)
}

fn all_english(parts: &[Segment]) -> bool {
    parts.iter().all(|part| part.lang == Language::English)
}

/// One word-in-progress. Each physical key is kept, and the visible text is
/// re-read as QWERTY or using the selected Korean layout. A reading changes
/// only when the one in progress stops being plausible and another reading is.
///
/// Confirmed Latin text is inserted immediately. `preedit` holds open Hangul
/// and shifted punctuation whose Korean or English reading is still undecided.
pub struct Session {
    layout: KeyboardLayout,
    pub auto_switch: bool,
    /// When false, a finished word stays as typed. Retype logging still runs.
    pub corrects_typos: bool,
    /// When false, the host cannot keep a composing span (Android `TYPE_NULL`,
    /// or an editor that drops the span with `finishComposingText` / `setText`).
    /// The Hangul reading is unchanged; edits only insert and replace committed
    /// text, so the client can `commitText` and `deleteSurroundingText`.
    composing: bool,
    /// Confirmed input language. Tentative readings do not change the keyboard mode.
    mode: Language,
    /// Open Hangul or an undecided shifted-punctuation reading.
    preedit: String,

    lexicon: Arc<Lexicon>,
    /// Change only through `push_key` / `pop_key` / `set_keys`, which drop
    /// the boundary cache the way Swift's `didSet` does.
    keys: Vec<KeyAtom>,
    composition_boundaries: RefCell<Vec<Option<bool>>>,
    segments: Vec<Segment>,
    /// Confirmed language when the open word started, even when a lone
    /// jamo is temporarily displayed as QWERTY.
    word_mode: Language,
    locked: Option<Language>,
    pending_undo: Option<Undo>,
    /// Closed words, already inserted.
    finished: String,
    /// Open-token prefix already inserted. The marked syllable, if any, follows it.
    plain: String,
    typos: Option<Arc<dyn TypoMemory>>,
    /// First backspace in this word, before the user retypes.
    rejected: Option<Rejection>,
    /// Language of the previous word in this run. `None` after a sentence or newline.
    context_language: Option<Language>,
    /// `context_language` as it was when the open word started. Undo puts it back.
    context_at_word_start: Option<Language>,
    /// Korean reading to restore when a function word was kept in English.
    preferred_undo: Option<Vec<Segment>>,
}

impl Session {
    /// `Session(lexicon:)` with Swift's defaults: auto-switch on, Korean
    /// mode, no typo memory, 세벌식 390.
    pub fn new(lexicon: Arc<Lexicon>) -> Session {
        Session::with_options(lexicon, SessionOptions::default())
    }

    pub fn with_options(lexicon: Arc<Lexicon>, options: SessionOptions) -> Session {
        Session {
            layout: options.layout,
            auto_switch: options.auto_switch,
            corrects_typos: true,
            composing: true,
            mode: options.mode,
            preedit: String::new(),
            lexicon,
            keys: Vec::new(),
            composition_boundaries: RefCell::new(Vec::new()),
            segments: Vec::new(),
            word_mode: options.mode,
            locked: None,
            pending_undo: None,
            finished: String::new(),
            plain: String::new(),
            typos: options.typos,
            rejected: None,
            context_language: None,
            context_at_word_start: None,
            preferred_undo: None,
        }
    }

    pub fn layout(&self) -> KeyboardLayout {
        self.layout
    }

    /// Commit the open word, then read later `input_char` keys with `layout`.
    /// The committed document stays. The same layout does not commit.
    /// Explicit [`KeyAtom`](crate::KeyAtom)s (the touch keyboard) keep the
    /// layout stored on the atom.
    pub fn set_layout(&mut self, layout: KeyboardLayout) -> SessionUpdate {
        if self.layout == layout {
            return self.make(FieldEdit::None, self.preedit.clone(), false);
        }
        let update = self.commit_displayed(true);
        self.layout = layout;
        update
    }

    pub fn mode(&self) -> Language {
        self.mode
    }

    pub fn preedit(&self) -> &str {
        &self.preedit
    }

    /// True while this word still has physical keys. Latin letters are already
    /// inserted, but Backspace still belongs to the session until the word ends.
    pub fn has_open_word(&self) -> bool {
        !self.keys.is_empty()
    }

    pub fn document(&self) -> String {
        let mut document = String::with_capacity(self.finished.len() + self.plain.len() + self.preedit.len());
        document.push_str(&self.finished);
        document.push_str(&self.plain);
        document.push_str(&self.preedit);
        document
    }

    /// `Session.input(Character)`: the key as the session's layout reads it.
    pub fn input_char(&mut self, english: char) -> SessionUpdate {
        self.input(self.layout.atom(english))
    }

    pub fn input(&mut self, atom: KeyAtom) -> SessionUpdate {
        // Keep a leading shifted digit available until its following text
        // distinguishes a Korean number from QWERTY punctuation (>과목).
        let pending_number =
            self.auto_switch && self.locked.is_none() && is_pad_digit(&atom) && self.keys.iter().all(is_pad_digit);
        let english_punctuation = self.mode == Language::English
            && !atom.english.is_alphabetic()
            && !atom.english.is_numeric()
            && !self.continues_as_korean(&atom);
        if (atom.is_neutral_breaker() || english_punctuation) && !pending_number && !self.continues_as_code(&atom) {
            return self.finish_word(atom.english);
        }
        // Moved 390 punctuation (Shift+B → !) ends a Hangul word too.
        // Including it in language scoring invalidates the clean Hangul
        // reading and can turn 고맙습니다 into kvif3습니다!.
        // A chat mark is the same kind of word: ㅎㅎ plus the final-layout
        // `?` key (which inserts !) must not be rescored as the token `mm?`.
        let ends_hangul_word =
            self.prefers_whole_korean(false) || (self.word_mode == Language::Korean && self.is_open_korean_chat_mark());
        if self.mode == Language::Korean
            && !self.keys.is_empty()
            && ends_hangul_word
            && let KeyOutput::Character(character) = atom.korean
            && !character.is_alphabetic()
            && !character.is_numeric()
        {
            return self.finish_word(character);
        }
        self.pending_undo = None;
        if self.keys.is_empty() {
            self.word_mode = self.mode;
            self.context_at_word_start = self.context_language;
        }
        let previous = self.segments.clone();
        self.push_key(atom);
        let converted = self.recompute(false, Some(&previous));
        if let Some(undo_segments) = self.preferred_undo.take() {
            self.pending_undo = Some(Undo { keys: self.keys.clone(), segments: undo_segments, committed_suffix: None });
        } else if converted && let Some(extended) = extend(&previous, self.keys.len()) {
            self.pending_undo = Some(Undo { keys: self.keys.clone(), segments: extended, committed_suffix: None });
        }
        self.sync_client(converted)
    }

    pub fn backspace(&mut self) -> SessionUpdate {
        self.pending_undo = None;
        if self.rejected.is_none() && !self.keys.is_empty() {
            let text = self.render(&self.segments);
            if !text.is_empty() {
                self.rejected = Some(Rejection { keys: self.keys.clone(), text });
            }
        }
        if self.keys.is_empty() {
            // The client deletes one committed character. Drop it here too, or the
            // next word boundary inserts the stale prefix again.
            if let Some((start, _)) = self.finished.grapheme_indices(true).next_back() {
                self.finished.truncate(start);
            }
            return self.make(FieldEdit::None, String::new(), false);
        }
        let before = self.document();
        self.pop_key();
        if self.keys.is_empty() {
            self.segments.clear();
            self.locked = None;
            self.rejected = None;
        } else {
            self.recompute(false, None);
        }
        let (next_plain, next_marked) = self.client_split();
        let after = format!("{}{next_plain}{next_marked}", self.finished);
        // A committed letter the client can delete itself. Only when nothing
        // has to become a composition again — a hidden mark would be inserted
        // on the next key beside the characters still on screen.
        if self.preedit.is_empty()
            && next_marked.is_empty()
            && before.starts_with(&after)
            && utf16_len(&before) == utf16_len(&after) + 1
        {
            self.plain = next_plain;
            self.preedit.clear();
            return self.make(FieldEdit::None, String::new(), false);
        }
        self.emit(next_plain, next_marked, false)
    }

    /// Shift+Space / Caps Lock. Immediately after an automatic conversion,
    /// or typo correction, this restores what was typed and holds it.
    /// Otherwise it flips the reading of the current word, or the mode for the next word.
    pub fn toggle(&mut self) -> SessionUpdate {
        if !self.composing {
            // The buffered syllable cannot be rewritten in place. Commit it and
            // switch the language for the next word.
            let flushed = self.commit_displayed(true);
            self.mode = self.mode.flipped();
            self.word_mode = self.mode;
            self.locked = None;
            return SessionUpdate {
                mode: self.mode,
                did_auto_convert: false,
                preedit: String::new(),
                field: flushed.field,
            };
        }
        // A mixed token such as `AI로` can also have an automatic-conversion
        // undo snapshot. Resolve the explicit whole-word toggle first; using
        // that snapshot would restore the earlier reading instead of flipping
        // the whole word.
        if !self.keys.is_empty()
            && let Some(first) = self.segments.first()
            && self.segments.iter().skip(1).any(|segment| segment.lang != first.lang)
        {
            return self.hold_word(self.word_mode.flipped());
        }

        if let Some(undo) = self.pending_undo.take() {
            if let Some(suffix) = undo.committed_suffix.clone() {
                if self.finished.ends_with(&suffix) {
                    self.finished.truncate(self.finished.len() - suffix.len());
                }
                self.context_language = self.context_at_word_start;
                self.restore(undo);
                let (next_plain, next_marked) = self.client_split();
                let field = replace_finished_suffix(&suffix, &next_plain, &next_marked);
                self.plain = next_plain;
                self.preedit = next_marked;
                return self.make(field, self.preedit.clone(), false);
            }
            self.restore(undo);
            return self.sync_client(false);
        }

        if !self.keys.is_empty() {
            let language = self.segments.last().map_or(self.mode, |segment| segment.lang);
            return self.hold_word(language.flipped());
        }

        self.mode = self.mode.flipped();
        self.word_mode = self.mode;
        self.locked = None;
        self.make(FieldEdit::None, self.preedit.clone(), false)
    }

    /// Touch-keyboard long-press of ※. Re-read whatever the open word is
    /// showing, including an in-progress syllable, in the opposite of the
    /// current mode, and hold that choice so automatic conversion does not
    /// flip it back. A finished word is left alone: with no open keys, only
    /// the mode changes.
    pub fn convert_open_word(&mut self) -> SessionUpdate {
        if !self.composing {
            let flushed = self.commit_displayed(true);
            self.mode = self.mode.flipped();
            self.word_mode = self.mode;
            self.locked = None;
            return SessionUpdate {
                mode: self.mode,
                did_auto_convert: false,
                preedit: String::new(),
                field: flushed.field,
            };
        }
        if self.keys.is_empty() {
            self.mode = self.mode.flipped();
            self.word_mode = self.mode;
            self.locked = None;
            return self.make(FieldEdit::None, self.preedit.clone(), false);
        }
        self.hold_word(self.mode.flipped())
    }

    /// One language for every key of the open word, kept against auto-switch.
    fn hold_word(&mut self, language: Language) -> SessionUpdate {
        self.pending_undo = None;
        self.locked = Some(language);
        self.mode = language;
        self.segments = self.whole(language);
        self.sync_client(false)
    }

    /// Hand the caret back to the app without rewriting characters. English
    /// is already inserted. Hangul, if any, is unmarked in place.
    pub fn commit_displayed(&mut self, ending_run: bool) -> SessionUpdate {
        let had_token = !self.keys.is_empty();
        let displayed = self.render(&self.segments);
        self.note_retype(&displayed);
        self.pending_undo = None;
        // A host with no composing span never received `preedit`. Insert it.
        // `plain` is already on screen, so inserting it again would duplicate.
        let field = if self.preedit.is_empty() {
            FieldEdit::None
        } else if self.composing {
            FieldEdit::Unmark { text: self.preedit.clone() }
        } else {
            FieldEdit::Insert { text: self.preedit.clone() }
        };
        self.finished.push_str(&self.plain);
        self.finished.push_str(&self.preedit);
        self.clear_token();
        if ending_run || had_token {
            self.context_language = None;
        }
        self.make(field, String::new(), false)
    }

    /// Turn composing spans on or off without changing the Hangul reading.
    ///
    /// `already_committed` means the current preedit is already in the field
    /// (the host finished composing, or the client just wrote it with
    /// `commitText`). It is folded into the committed prefix and no edit is
    /// returned. Pass `false` when a `setComposingText` was rejected: the
    /// returned edit commits that preedit.
    pub fn set_composing(&mut self, enabled: bool, already_committed: bool) -> SessionUpdate {
        if enabled {
            self.composing = true;
            return self.make(FieldEdit::None, self.preedit.clone(), false);
        }
        let was_composing = self.composing;
        self.composing = false;
        if already_committed {
            if !self.preedit.is_empty() {
                self.plain.push_str(&self.preedit);
                self.preedit.clear();
            }
            return self.make(FieldEdit::None, String::new(), false);
        }
        if !was_composing || self.preedit.is_empty() {
            return self.make(FieldEdit::None, String::new(), false);
        }
        self.sync_client(false)
    }

    pub fn force_mode(&mut self, language: Language) -> SessionUpdate {
        let update = self.commit_displayed(false);
        self.mode = language;
        self.word_mode = language;
        self.locked = None;
        SessionUpdate { mode: self.mode, did_auto_convert: false, preedit: String::new(), field: update.field }
    }

    pub fn discard(&mut self) -> SessionUpdate {
        self.rejected = None;
        self.context_language = None;
        let field = if self.preedit.is_empty() { FieldEdit::None } else { FieldEdit::Mark { text: String::new() } };
        self.finished.push_str(&self.plain);
        self.clear_token();
        self.pending_undo = None;
        self.make(field, String::new(), false)
    }

    pub fn debug_line(&self) -> String {
        let description = self
            .segments
            .iter()
            .map(|segment| format!("{}:{}-{}", segment.lang.raw_value(), segment.start, segment.end))
            .collect::<Vec<_>>()
            .join(" ");
        format!(
            "{} {{{description}}} mode={} lock={} mark={}",
            self.document(),
            self.mode.raw_value(),
            self.locked.map_or("-", Language::raw_value),
            self.preedit
        )
    }

    // MARK: - Keys

    fn push_key(&mut self, atom: KeyAtom) {
        self.keys.push(atom);
        self.composition_boundaries.get_mut().clear();
    }

    fn pop_key(&mut self) {
        self.keys.pop();
        self.composition_boundaries.get_mut().clear();
    }

    fn set_keys(&mut self, keys: Vec<KeyAtom>) {
        self.keys = keys;
        self.composition_boundaries.get_mut().clear();
    }

    fn whole(&self, lang: Language) -> Vec<Segment> {
        vec![Segment { start: 0, end: self.keys.len(), lang }]
    }

    fn split_at(&self, head_end: usize) -> Vec<Segment> {
        vec![
            Segment { start: 0, end: head_end, lang: Language::English },
            Segment { start: head_end, end: self.keys.len(), lang: Language::Korean },
        ]
    }

    // MARK: - Word boundary

    fn finish_word(&mut self, breaker: char) -> SessionUpdate {
        let previous = self.segments.clone();
        let before = self.render(&self.segments);
        self.recompute(true, if previous.is_empty() { None } else { Some(&previous) });
        let composed_segments = self.segments.clone();
        let composed = self.render(&self.segments);
        self.note_retype(&composed);
        let mut word = composed.clone();
        if self.corrects_typos
            && self.locked.is_none()
            && let Some(fixed) = self.corrected(&composed)
        {
            word = fixed;
        }
        // Already-sent syllables cannot be deleted on a raw field. Keep them
        // and only append the buffered tail.
        if !self.composing && !word.starts_with(&self.plain) {
            word = format!("{}{}", self.plain, self.preedit);
        }
        let mut suffix = word.clone();
        suffix.push(breaker);
        let carried = match &self.pending_undo {
            Some(undo) => undo.committed_suffix.is_none() && undo.keys.len() == self.keys.len(),
            None => false,
        };
        if word != composed && !self.keys.is_empty() {
            self.pending_undo = Some(Undo {
                keys: self.keys.clone(),
                segments: composed_segments.clone(),
                committed_suffix: Some(suffix.clone()),
            });
        } else if composed != before && !self.keys.is_empty() {
            self.pending_undo =
                Some(Undo { keys: self.keys.clone(), segments: previous, committed_suffix: Some(suffix.clone()) });
        } else if carried && !self.keys.is_empty() {
            if let Some(undo) = &mut self.pending_undo {
                undo.committed_suffix = Some(suffix.clone());
            }
        } else {
            self.pending_undo = None;
        }
        let field = self.finish_field(&word, breaker);
        self.finished.push_str(&suffix);
        // jc stays Latin until this boundary, then becomes 에. Confirm Korean
        // for the next word, as a frequent syllable recognized while typing does.
        if composed_segments.len() == 1
            && composed_segments[0].lang == Language::Korean
            && self.lexicon.is_korean_word(&composed)
        {
            self.mode = Language::Korean;
        }
        let sentence = is_sentence_boundary(breaker) || ".?!".contains(composed.chars().next_back().unwrap_or(' '));
        if sentence {
            self.context_language = None;
        } else if !self.keys.is_empty()
            && let Some(last) = composed_segments.last()
        {
            self.context_language = if last.lang == self.mode { Some(last.lang) } else { None };
        }
        let converted = composed != before && !before.is_empty();
        self.clear_token();
        self.make(field, String::new(), converted)
    }

    /// A finished token whose spelling was not what the keys composed.
    fn corrected(&self, composed: &str) -> Option<String> {
        let [only] = self.segments.as_slice() else { return None };
        if only.start != 0 || only.end != self.keys.len() {
            return None;
        }
        TypoCorrector::correction(composed, &self.keys, only.lang, &self.lexicon, self.typos.as_deref())
    }

    fn note_retype(&mut self, final_text: &str) {
        let Some(snapshot) = self.rejected.take() else { return };
        let wrong_keys: String = snapshot.keys.iter().map(|atom| atom.english).collect();
        let final_keys: String = self.keys.iter().map(|atom| atom.english).collect();
        if !TypoLogPolicy::should_store(&snapshot.text, final_text, &wrong_keys, &final_keys) {
            return;
        }
        if let Some(typos) = &self.typos {
            typos.record(&snapshot.text, &wrong_keys, final_text, &final_keys);
        }
    }

    fn finish_field(&self, word: &str, breaker: char) -> FieldEdit {
        if !self.composing {
            let rest = word.strip_prefix(self.plain.as_str()).unwrap_or(self.preedit.as_str());
            let mut text = rest.to_owned();
            text.push(breaker);
            return FieldEdit::Insert { text };
        }
        let with_breaker = |text: &str| {
            let mut text = text.to_owned();
            text.push(breaker);
            text
        };
        let displayed_matches = word.len() == self.plain.len() + self.preedit.len()
            && word.starts_with(&self.plain)
            && word.ends_with(&self.preedit);
        if displayed_matches {
            if self.preedit.is_empty() {
                return FieldEdit::Insert { text: breaker.to_string() };
            }
            return FieldEdit::Insert { text: with_breaker(&self.preedit) };
        }
        if self.preedit.is_empty() {
            return FieldEdit::InsertReplacing { utf16: utf16_len(&self.plain), text: with_breaker(word) };
        }
        if let Some(rest) = word.strip_prefix(self.plain.as_str()) {
            // Covers an empty `plain` too: the rest is the whole word.
            return FieldEdit::Insert { text: with_breaker(rest) };
        }
        let span = utf16_len(&self.plain) + utf16_len(&self.preedit);
        FieldEdit::InsertReplacing { utf16: span, text: with_breaker(word) }
    }

    fn clear_token(&mut self) {
        self.set_keys(Vec::new());
        self.segments.clear();
        self.locked = None;
        self.plain.clear();
        self.preedit.clear();
        self.rejected = None;
    }

    fn restore(&mut self, undo: Undo) {
        let language = undo.segments.last().map_or(self.mode, |segment| segment.lang);
        self.set_keys(undo.keys);
        self.segments = undo.segments;
        self.locked = Some(language);
        self.mode = language;
    }

    // MARK: - Reading selection

    fn recompute(&mut self, word_final: bool, previous: Option<&[Segment]>) -> bool {
        self.preferred_undo = None;
        let changed = self.select_reading(word_final, previous);
        // Keep real-time conversion; word boundaries do not drive mode changes.
        if !word_final {
            self.confirm_mode();
        }
        changed
    }

    fn select_reading(&mut self, word_final: bool, previous: Option<&[Segment]>) -> bool {
        if let Some(locked) = self.locked {
            self.segments = if self.keys.is_empty() { Vec::new() } else { self.whole(locked) };
            self.mode = locked;
            return false;
        }
        if !self.auto_switch {
            self.segments = if self.keys.is_empty() { Vec::new() } else { self.whole(self.mode) };
            return false;
        }
        if self.keys.is_empty() {
            self.segments.clear();
            return false;
        }
        let korean = self.whole(Language::Korean);
        let english = self.whole(Language::English);

        // Keep the filename intact when a Korean particle follows its
        // extension: a.md + 를 must not reinterpret md as 히.
        if let Some(head_end) = self.single_k_ro_split().or_else(|| self.code_particle_split()) {
            return self.install_reading(self.split_at(head_end), previous);
        }

        // Shifted number keys can initially look like a capitalized English
        // prefix (Mu…). Once the tail is Korean, recover the number too.
        if self.prefers_number_with_korean_tail() {
            return self.install_reading(korean, previous);
        }

        // Shift+B is !. BB and BBB are !! and !!!, not the acronyms BB and
        // BBB. The other moved symbols are the same shape (;; << >> // '').
        // A different letter is still an acronym: HP, BBC, Hello, TV.
        if self.prefers_repeated_symbol() {
            return self.install_reading(korean, previous);
        }

        // "Open" is 9펴 and "Int" is 8서: a shifted digit plus a syllable.
        // That shape must not outrank a capitalized English word. A pure
        // digit run (OK → 95) is excluded and stays a number.
        if self.prefers_capitalized_english() {
            return self.install_reading(english, previous);
        }

        if self.keys.iter().all(KeyAtom::is_dubeol) {
            let korean_text = compose(&self.keys).text;
            // Common chat reactions outrank dictionary abbreviations such as
            // dd, even when the word starts in English mode.
            let is_chat_reaction = korean_text.chars().count() >= 2 && all_same_from(&korean_text, "ㅇㅋㅎㅠㅜ");
            let known = |text: &str| self.lexicon.is_korean_word(text) || self.lexicon.is_valid_korean(text);
            let known_whole = is_chat_reaction || known(&korean_text);
            // 내요 is 내 + polite 요. Treat that reading as a known stem so an
            // obscure headword (`sody`) cannot keep the buffer in English
            // after `sod` has already confirmed English mode.
            let known_stem = korean_endings::split(&korean_text).is_some_and(|(stem, _)| known(stem))
                || is_common_polite_yo(&korean_text);
            let spelling = self.english_text(0, self.keys.len());
            if (known_whole || known_stem)
                && (is_chat_reaction
                    || self.mode == Language::Korean
                    || known_stem
                    || !self.lexicon.is_english_word(&spelling))
            {
                return self.install_reading(korean, previous);
            }
        }

        // After a known acronym, start the Korean mark on its initial key.
        // Committing AI+h first would require replacing plain text when 느
        // appears, which web editors can leave behind as AIh느.
        if let Some(head_end) = self.pending_acronym_initial_split() {
            return self.install_reading(self.split_at(head_end), previous);
        }

        // "ktx는" is two legal syllables (걱는), so Hangul stickiness would
        // swallow the acronym. A short acronym plus a particle splits first.
        // "한은" stays Hangul: 한 starts a real dictionary word.
        if let Some(head_end) = self.acronym_particle_split() {
            return self.install_reading(self.split_at(head_end), previous);
        }

        // "of" is the syllable 차. After an English word the short function
        // word stays English. Hangul stickiness still wins for every other buffer.
        if self.prefers_contextual_english() {
            // The key before this one may already be Latin because the mode
            // followed the English word. Undo still has to bring back 차.
            let english_text = self.render(&english);
            if english_text != self.render(&korean) {
                self.preferred_undo = Some(korean);
            }
            let mut changed = self.preferred_undo.is_some();
            if let Some(previous) = previous
                && let Some(extended) = extend(previous, self.keys.len())
            {
                changed = changed || english_text != self.render(&extended);
            }
            self.segments = english;
            return changed;
        }

        // In English mode a syllable-shaped prefix is not evidence of a
        // language change. Keep QWERTY until a stronger Korean reading appears.
        // A finished prefix can still be one frequent syllable (에, 돼).
        if self.prefers_current_english_mode(word_final) {
            return self.install_reading(english, previous);
        }

        // Two-set keys can form clean but unknown Hangul from an ordinary
        // English word (world → 재깅). Prefer the known whole English word,
        // while preserving known Korean readings and short ambiguous words.
        // 내요/해요/돼요/가요 stay Korean: their spellings are not common English.
        if self.keys.iter().all(KeyAtom::is_dubeol) {
            let spelling = self.english_text(0, self.keys.len());
            let korean_text = compose(&self.keys).text;
            if spelling.chars().count() >= 3
                && self.lexicon.is_english_word(&spelling)
                && !self.lexicon.is_korean_word(&korean_text)
                && !self.lexicon.is_valid_korean(&korean_text)
                && !is_common_polite_yo(&korean_text)
            {
                return self.install_reading(english, previous);
            }
        }

        // A later syllable's keys can spell an English word ("력" is y-e-x,
        // and "yex" is a Webster headword). While the buffer is still one or
        // more syllables, optionally with a trailing choseong, it stays Korean.
        if self.prefers_whole_korean(word_final) {
            return self.install_reading(korean, previous);
        }

        // Shifted 390 digits sit on letter keys (1 is M, 0 is N). "MN" is an
        // English prefix, so it must not outrank the digits while typing Korean.
        if self.prefers_pad_digits() {
            return self.install_reading(korean, previous);
        }

        // "N.M" is the digit keys for 0.1. A dot must not turn that into an
        // English token the way "agents.md" stays English.
        if self.prefers_shifted_number() {
            return self.install_reading(korean, previous);
        }

        // ㄲ·ㄸ·ㅃ·ㅆ·ㅉ are one choseong typed with two keys. "ll" is also the
        // prefix of "llvm", so the pair must stay ㅉ and not become Latin.
        if self.prefers_doubled_choseong() {
            return self.install_reading(korean, previous);
        }

        // ㄹㄴㅈ has no vowel, so it is not a Korean word. If those keys spell
        // a dictionary English word (`wsl`, `jsx`, `ssl`), both modes read Latin.
        if self.bare_jamo_spells_english_word() {
            return self.install_reading(english, previous);
        }

        // ㅎㅎ, ㅋㅋ, ㅠㅠ, ㄱㅅ. A lone ㅠ may display as "5", but
        // that tentative reading does not change the Korean mode.
        if self.prefers_bare_jamo_run(previous) {
            return self.install_reading(korean, previous);
        }

        // "agents.md" and "https://agents.md" are one token. A dot only ends
        // the word when the buffer is already a Hangul syllable.
        if self.prefers_whole_english_code() {
            return self.install_reading(english, previous);
        }

        // "agents" is still a prefix of "agentship", and "nts" is the syllable
        // 선. A pure letter run that is a word or a prefix stays one English
        // reading. "AIyv" is not a prefix, so 로 can still take the tail.
        if self.prefers_whole_english_word(word_final) {
            return self.install_reading(english, previous);
        }

        // 수고 was typed nbv: ㅜ cannot take ㅗ, and "v" is a one-letter
        // dictionary hit. Scoring then commits Latin `수v`. The vowel stays
        // Hangul (수ㅗ) unless the whole buffer is already an English word.
        if self.prefers_hangul_with_orphan_vowels() {
            return self.install_reading(korean, previous);
        }

        // "ansible" is absent from Webster, so it is not a prefix either.
        // 두벌식 keeps the leading syllable 무 and spells the tail with short
        // English hits (sib, le) → 무sible. `splunk` does the same (네lunk).
        // A letter run that starts with that fragment stays Latin. An English
        // word plus a particle (`api는`) is a different split and stays.
        if self.prefers_latin_over_mixed_hangul(word_final) {
            return self.install_reading(english, previous);
        }

        self.select_best_path(previous, word_final)
    }

    fn install_reading(&mut self, candidate: Vec<Segment>, previous: Option<&[Segment]>) -> bool {
        let changed = previous
            .and_then(|previous| extend(previous, self.keys.len()))
            .is_some_and(|previous_reading| self.render(&candidate) != self.render(&previous_reading));
        self.segments = candidate;
        changed
    }

    /// Selects a scored path while preserving a still-plausible live reading.
    /// Keeping this stage separate from the ordered priority rules makes the
    /// fallback decision easier to inspect without changing rule precedence.
    fn select_best_path(&mut self, previous: Option<&[Segment]>, word_final: bool) -> bool {
        let chosen = self.best_path(word_final).unwrap_or_else(|| self.whole(self.mode));
        if let Some(previous) = previous
            && let Some(extended) = extend(previous, self.keys.len())
        {
            let extended_score = self.score(&extended, word_final);
            let extended_solid = self.last_is_solid(&extended, word_final);
            let reserved = self.reserves_english_prefix(&extended, word_final);
            let chosen_score = self.score(&chosen, word_final).unwrap_or(i64::MIN);
            let take_new = if !self.preserves_composition_in(&extended) {
                true
            } else if extended_solid || reserved {
                false
            } else {
                match extended_score {
                    None => true,
                    Some(extended_score) => chosen_score > extended_score + scoring::MARGIN,
                }
            };
            if take_new {
                let changed = self.render(&chosen) != self.render(&extended);
                self.segments = chosen;
                return changed;
            }
            self.segments = extended;
            return false;
        }

        self.segments = chosen;
        false
    }

    /// Only recognized words/tokens or a multi-syllable Korean reading may
    /// change the mode. Lone keys, digits, and dictionary prefixes cannot.
    fn confirm_mode(&mut self) {
        if !self.auto_switch || self.locked.is_some() {
            return;
        }
        let Some(last) = self.segments.last().copied() else { return };
        let atoms = &self.keys[last.start..last.end];
        match last.lang {
            Language::English => {
                let spelling = self.english_text(last.start, last.end);
                if spelling.chars().count() < 2 || atoms.iter().all(is_pad_digit) {
                    return;
                }
                if self.lexicon.is_english_word(&spelling.to_lowercase())
                    || self.lexicon.is_abbreviation(&spelling)
                    || self.lexicon.is_code_token(&spelling)
                    || self.is_english_code(&spelling)
                {
                    self.mode = Language::English;
                }
            }
            Language::Korean => {
                // 8시 started in Korean but read as "In" for a moment, which
                // confirmed English. The counter puts Korean back.
                let number_end = atoms.iter().take_while(|atom| is_pad_digit(atom)).count();
                if self.word_mode == Language::Korean
                    && number_end > 0
                    && number_end < atoms.len()
                    && starts_with_counter(&compose(&atoms[number_end..]).text)
                {
                    self.mode = Language::Korean;
                    return;
                }
                let composition = compose(atoms);
                if let Shape::Clean(syllables) | Shape::Trailing(syllables) = shape_of(&composition.pieces)
                    && (syllables >= 2
                        || self.lexicon.is_korean_word(&composition.text)
                        || (self.segments.len() > 1 && is_particle(&composition.text)))
                {
                    self.mode = Language::Korean;
                }
            }
        }
    }

    fn prefers_current_english_mode(&self, word_final: bool) -> bool {
        if self.mode != Language::English {
            return false;
        }
        let spelling = self.english_text(0, self.keys.len());
        if self.prefers_whole_english_word(word_final)
            || self.prefers_whole_english_code()
            || spelling.chars().all(|character| character.is_alphabetic() && character.is_uppercase())
        {
            return true;
        }
        // `5` is ㅠ and `4` is ㅛ, so 공유 (`kvaj5`) and 메뉴 (`ich5`) match a
        // version token. That shape loses when the keys are a dictionary word.
        // `v2`, `utf8`, and `mp3` do not compose one, so they stay Latin.
        // `0` is ㅋ, so `zou20` and `i18n0` also look like a token plus a new
        // initial. Extra digits stay in the token; a finished Hangul word does not.
        if self.alphanumeric_continuation_stays_english(&spelling) {
            return true;
        }
        let composition = compose(&self.keys);
        match shape_of(&composition.pieces) {
            Shape::SingleBare | Shape::Digits | Shape::Symbol => true,
            // A recognized Korean word is stronger evidence than its length.
            // English words/prefixes were checked first, so of stays English.
            // A lone syllable whose keys spell no English word or prefix is
            // Korean when the large validity list knows it (hga → 능).
            Shape::Clean(syllables) => {
                syllables < 2
                    && !self.lexicon.is_korean_word(&composition.text)
                    && !self.lexicon.is_valid_korean(&composition.text)
            }
            Shape::Trailing(syllables) => syllables < 2,
            Shape::Invalid => false,
        }
    }

    /// Unshifted number-row keys are jamo on 390, so a Hangul word can look
    /// like `page2`. It converts when every piece is a syllable of a dictionary
    /// word and the spelling is not itself English (`v2`, `utf8`, `i18n`).
    fn number_row_keys_spell_korean_word(&self, spelling: &str) -> bool {
        if !spelling.chars().any(char::is_numeric) {
            return false;
        }
        if self.lexicon.is_english_word(&spelling.to_lowercase()) {
            return false;
        }
        let composition = compose(&self.keys);
        if !matches!(shape_of(&composition.pieces), Shape::Clean(_)) {
            return false;
        }
        self.lexicon.is_korean_word(&composition.text) || self.lexicon.is_valid_korean(&composition.text)
    }

    /// Letters and digits that are still one token, not a Hangul word.
    /// `i18n0` is not itself `is_code_token` (a letter follows the digits), but
    /// it is that token plus another digit. `0` must not become bare ㅋ.
    fn alphanumeric_continuation_stays_english(&self, spelling: &str) -> bool {
        if self.number_row_keys_spell_korean_word(spelling) {
            return false;
        }
        if self.lexicon.is_code_token(spelling) {
            return true;
        }
        if !spelling.chars().all(|character| character.is_ascii_alphanumeric()) {
            return false;
        }
        let head = spelling.trim_end_matches(|character: char| character.is_ascii_digit());
        if head.is_empty() || head.len() == spelling.len() {
            return false;
        }
        self.lexicon.is_code_token(head) || self.lexicon.is_abbreviation(head)
    }

    /// On 390, ; and ' are initials, / is a vowel, and ! is a final.
    /// Keep those keys available to a Korean reading instead of committing
    /// half a word as punctuation (0ts'gyvw → 컨트롤).
    fn continues_as_korean(&self, atom: &KeyAtom) -> bool {
        let KeyOutput::Jamo(jamo) = atom.korean else { return false };
        if self.keys.is_empty() {
            return jamo.kind == JamoKind::Choseong;
        }
        // Recognized English spellings still own their punctuation: of;,
        // it!, don't, filenames, and paths must not become Korean fragments.
        // A prefix alone (jd in jdb/jdeps) must leave the next initial
        // available: jd;ts is 이번. Complete English words still own it.
        let spelling = self.english_text(0, self.keys.len());
        // ' is ㅌ. After a short English word that is also clean Hangul
        // (nc → 세), keep the apostrophe in the buffer: the contraction
        // scorer still makes don't English, and nc'v can become 세토.
        let apostrophe_joins = atom.english == '\''
            && self.lexicon.is_english_word(&spelling)
            && !self.prefers_whole_english_code()
            && !self.lexicon.is_code_token(&spelling)
            && self.prefers_whole_korean(false);
        if !apostrophe_joins
            && (self.lexicon.is_english_word(&spelling)
                || self.prefers_whole_english_code()
                || self.lexicon.is_code_token(&spelling))
        {
            return false;
        }
        let composition = compose(self.keys.iter().chain(std::iter::once(atom)));
        match shape_of(&composition.pieces) {
            Shape::Clean(syllables) | Shape::Trailing(syllables) => syllables > 0,
            _ => false,
        }
    }

    fn best_path(&self, word_final: bool) -> Option<Vec<Segment>> {
        let count = self.keys.len();
        if count == 0 {
            return None;
        }
        let mut best: Vec<Option<Path>> = vec![None; count + 1];
        best[0] = Some(Path { score: 0, prev: usize::MAX, lang: self.mode });
        let order = match self.mode {
            Language::Korean => [Language::Korean, Language::English],
            Language::English => [Language::English, Language::Korean],
        };

        for start in 0..count {
            let Some(base) = best[start] else { continue };
            let can_switch = self.preserves_composition_at(start);
            let limit = count.min(start + scoring::MAX_SEGMENT);
            for end in start + 1..=limit {
                for lang in order {
                    if start > 0 && (lang == Language::Korean || base.lang == Language::Korean) && !can_switch {
                        continue;
                    }
                    let is_final = word_final && end == count;
                    let Some(quality) = self.quality(start, end, lang, is_final) else { continue };
                    let mut total = base.score + quality.score;
                    if start > 0 {
                        total -= scoring::JOIN_PENALTY;
                        if lang != base.lang {
                            total -= scoring::SWITCH_PENALTY;
                        }
                    }
                    if start == 0 && lang == self.mode {
                        total += scoring::MODE_BONUS;
                    }
                    if best[end].is_none_or(|current| total > current.score) {
                        best[end] = Some(Path { score: total, prev: start, lang });
                    }
                }
            }
        }
        best[count]?;
        let mut parts = Vec::new();
        let mut cursor = count;
        while cursor > 0 {
            let path = best[cursor]?;
            parts.push(Segment { start: path.prev, end: cursor, lang: path.lang });
            cursor = path.prev;
        }
        parts.reverse();
        Some(parts)
    }

    fn score(&self, parts: &[Segment], word_final: bool) -> Option<i64> {
        if parts.is_empty() {
            return Some(0);
        }
        let mut total = 0;
        for (index, part) in parts.iter().enumerate() {
            if index > 0
                && (parts[index - 1].lang == Language::Korean || part.lang == Language::Korean)
                && !self.preserves_composition_at(part.start)
            {
                return None;
            }
            let is_final = word_final && index == parts.len() - 1;
            let quality = self.quality(part.start, part.end, part.lang, is_final)?;
            total += quality.score;
            if index > 0 {
                total -= scoring::JOIN_PENALTY;
                if parts[index - 1].lang != part.lang {
                    total -= scoring::SWITCH_PENALTY;
                }
            }
        }
        if parts[0].lang == self.mode {
            total += scoring::MODE_BONUS;
        }
        Some(total)
    }

    fn last_is_solid(&self, parts: &[Segment], word_final: bool) -> bool {
        let Some(last) = parts.last() else { return false };
        self.quality(last.start, last.end, last.lang, word_final).is_some_and(|quality| quality.solid)
    }

    fn reserves_english_prefix(&self, parts: &[Segment], word_final: bool) -> bool {
        if word_final {
            return false;
        }
        let Some(last) = parts.last() else { return false };
        if last.lang != Language::English {
            return false;
        }
        let lower = self.english_text(last.start, last.end).to_lowercase();
        let count = lower.chars().count();
        if count < 2 || !lower.chars().all(char::is_alphabetic) {
            return false;
        }
        if !has_vowel(&lower) {
            return false;
        }
        if self.lexicon.is_english_word(&lower) {
            return false;
        }
        if !self.lexicon.is_english_prefix(&lower) {
            return false;
        }
        count >= 3 || self.mode == Language::English
    }

    fn quality(&self, start: usize, end: usize, lang: Language, word_final: bool) -> Option<ReadingQuality> {
        let atoms = &self.keys[start..end];
        match lang {
            Language::English => {
                // A run of nothing but 390 digit keys is not an English word.
                // "AI" still is: only the I key is a digit, and the abbreviation stands.
                if self.mode == Language::Korean && !atoms.is_empty() && atoms.iter().all(is_pad_digit) {
                    return None;
                }
                // BB is !! even after another jamo. `tt` and `pp` must not
                // take that slice back as an English prefix or word.
                if self.mode == Language::Korean && is_repeated_shifted_symbol(atoms) {
                    return None;
                }
                self.english_quality(&self.english_text(start, end), word_final)
            }
            Language::Korean => self.korean_quality(atoms, word_final),
        }
    }

    fn english_quality(&self, text: &str, word_final: bool) -> Option<ReadingQuality> {
        if text.is_empty() {
            return None;
        }
        let quality = |score: usize, solid: bool| Some(ReadingQuality { score: score as i64, solid });
        let count = text.chars().count();
        if self.lexicon.is_abbreviation(text) {
            return quality(230 + count, true);
        }
        let lower = text.to_lowercase();
        if self.lexicon.is_code_token(text) {
            let strong = count >= 4 || lower.starts_with('v');
            // `e2e` / `b2b` / `p2p` are real tokens, but the same three-key
            // shape is the vowel, ㅆ, and the next choseong of a syllable
            // (`r2h` inside 했ㄴ). A full code-token score lets that slice
            // replace the Hangul. Keep the token only strong enough to beat
            // a reading that is not a syllable.
            let letter_to_letter = count == 3
                && lower.as_bytes().first().is_some_and(u8::is_ascii_lowercase)
                && lower.as_bytes().get(1) == Some(&b'2')
                && lower.as_bytes().get(2).is_some_and(u8::is_ascii_lowercase);
            let score = if strong {
                210
            } else if letter_to_letter {
                24
            } else {
                96
            };
            return quality(score, strong);
        }
        if text.chars().all(char::is_numeric) {
            // One number-row key is a jamo ("2" is ㅆ). A run of them ("2024")
            // is a number. A syllable that merely contains ㅆ is not this case.
            if count == 1 {
                return quality(18, false);
            }
            return quality(90 + count * 4, true);
        }
        if self.lexicon.is_english_word(&lower) && text.chars().any(char::is_numeric) {
            return quality(200 + count, true);
        }
        if let Some(apostrophe) = self.apostrophe_quality(&lower, word_final) {
            return Some(apostrophe);
        }
        let lower_count = lower.chars().count();
        let letters = lower.chars().all(char::is_alphabetic);
        if letters && self.lexicon.is_english_word(&lower) {
            if lower_count >= 3 {
                return quality(172 + lower_count * 8, true);
            }
            if lower_count == 2 {
                return quality(64, false);
            }
        }
        if !word_final
            && lower_count >= 2
            && letters
            && self.lexicon.is_english_prefix(&lower)
            && !self.lexicon.is_english_word(&lower)
        {
            let base = if has_vowel(&lower) { 28 } else { 14 };
            return quality(base + lower_count * 2, false);
        }
        if count == 1 {
            let first = text.chars().next()?;
            if first.is_alphabetic() || first.is_numeric() {
                return quality(if word_final { 12 } else { 20 }, false);
            }
            return quality(10, false);
        }
        None
    }

    fn apostrophe_quality(&self, lower: &str, word_final: bool) -> Option<ReadingQuality> {
        if lower.chars().filter(|character| *character == '\'').count() != 1 {
            return None;
        }
        let (left, right) = lower.split_once('\'')?;
        if left.is_empty() || !left.chars().all(char::is_alphabetic) {
            return None;
        }
        const ENDINGS: [&str; 7] = ["t", "s", "re", "ve", "ll", "d", "m"];
        let known = || self.lexicon.is_english_word(left) || self.lexicon.is_english_prefix(left);
        if ENDINGS.contains(&right) && known() {
            let solid = self.lexicon.is_english_word(left);
            return Some(ReadingQuality { score: 200 + lower.chars().count() as i64, solid });
        }
        if right.is_empty() && !word_final && known() {
            return Some(ReadingQuality { score: 30 + left.chars().count() as i64 * 2, solid: false });
        }
        None
    }

    fn korean_quality(&self, atoms: &[KeyAtom], word_final: bool) -> Option<ReadingQuality> {
        let composition = compose(atoms);
        let quality = |score: usize, solid: bool| Some(ReadingQuality { score: score as i64, solid });
        match shape_of(&composition.pieces) {
            Shape::Invalid => None,
            Shape::Symbol => quality(14, false),
            Shape::SingleBare => {
                // A choseong, including ㄲ·ㄸ·ㅃ, can still open a syllable.
                // A lone jungseong or jongseong cannot ("x" is ㄱ). A finished
                // word that never became a syllable is not Korean either ("k ").
                if word_final || composition.pieces != [CompositionPiece::BareChoseong] {
                    return None;
                }
                quality(26, false)
            }
            Shape::Trailing(syllables) => quality(34 + syllables * 8, false),
            Shape::Digits => {
                // English mode keeps the QWERTY letters (MN, API). Korean mode
                // reads this same key run as digits.
                if self.mode == Language::English {
                    return None;
                }
                quality(48 + composition.pieces.len() * 6, composition.pieces.len() >= 2)
            }
            Shape::Clean(syllables) => {
                let mut score = 100 + syllables.saturating_sub(1) * 24;
                if syllables >= 2 && self.lexicon.is_korean_word(&composition.text) {
                    score += 40;
                }
                quality(score, syllables >= 2)
            }
        }
    }

    /// A language boundary must also be a composition boundary. Splitting
    /// inside an initial, vowel, or final changes the Hangul on either side.
    fn preserves_composition_at(&self, index: usize) -> bool {
        let mut cache = self.composition_boundaries.borrow_mut();
        if cache.len() <= index {
            cache.resize(index + 1, None);
        }
        if let Some(cached) = cache[index] {
            return cached;
        }
        let safe = preserves_boundary(index, &self.keys);
        cache[index] = Some(safe);
        safe
    }

    fn preserves_composition_in(&self, parts: &[Segment]) -> bool {
        parts.windows(2).all(|pair| {
            !(pair[0].lang == Language::Korean || pair[1].lang == Language::Korean)
                || self.preserves_composition_at(pair[1].start)
        })
    }

    /// A scored path glued a short Hangul fragment onto Latin letters.
    /// `무` + `sible` and `ansib` + `져` are that shape. A particle
    /// (`github에서`) or a multi-syllable Korean word stays Hangul.
    fn prefers_latin_over_mixed_hangul(&self, word_final: bool) -> bool {
        let spelling = self.english_text(0, self.keys.len());
        let lower = spelling.to_lowercase();
        if lower.chars().count() < 5 || !lower.chars().all(char::is_alphabetic) || !has_vowel(&lower) {
            return false;
        }
        let korean_text = compose(&self.keys).text;
        if self.lexicon.is_korean_word(&korean_text)
            || self.lexicon.is_valid_korean(&korean_text)
            || is_common_polite_yo(&korean_text)
        {
            return false;
        }
        // 수ㅗ / 수ㅗㄱ already returned above when this is reached from
        // select_reading. The check also covers a direct call.
        if self.prefers_hangul_with_orphan_vowels() {
            return false;
        }
        if self.unwanted_hangul_latin_mix(&self.best_path(word_final).unwrap_or_default()) {
            return true;
        }
        // At a boundary, prefix scores drop, so `lunk` may no longer justify
        // the mix and the fallback would commit the Hangul fragment. The
        // in-progress segmentation is the same token.
        word_final && self.unwanted_hangul_latin_mix(&self.best_path(false).unwrap_or_default())
    }

    fn unwanted_hangul_latin_mix(&self, parts: &[Segment]) -> bool {
        if parts.len() < 2 {
            return false;
        }
        // Only a Hangul fragment in front of Latin (`무` + `sible`, `네` +
        // `lunk`). An English word followed by a particle (`api는`,
        // `github에서`) starts with Latin and must keep that split, including
        // while the particle is still one jamo short (`api느`, `github엣`).
        if parts[0].lang != Language::Korean {
            return false;
        }
        let english_keys: usize =
            parts.iter().filter(|part| part.lang == Language::English).map(|part| part.end - part.start).sum();
        if english_keys < 2 {
            return false;
        }
        parts
            .iter()
            .filter(|part| part.lang == Language::Korean)
            .all(|part| !self.korean_reading_should_stay(part.start, part.end))
    }

    /// Particles and multi-syllable dictionary words are intentional Hangul.
    /// One syllable (`무`, `유`, `져`) is how a Latin token gets stuck.
    fn korean_reading_should_stay(&self, start: usize, end: usize) -> bool {
        let text = compose(&self.keys[start..end]).text;
        if is_particle(&text) {
            return true;
        }
        text.chars().count() >= 2 && (self.lexicon.is_korean_word(&text) || self.lexicon.is_valid_korean(&text))
    }

    /// Syllables plus a vowel that could not join, optionally with the next
    /// choseong already typed (`nbv` → 수ㅗ, `nbvk` → 수ㅗㄱ). A real English
    /// word or prefix (`head`, `oct`) is decided before this runs. Two-set
    /// input uses the vowel to reopen the previous syllable, so it is left
    /// to the existing rules.
    fn prefers_hangul_with_orphan_vowels(&self) -> bool {
        if self.word_mode != Language::Korean || self.keys.iter().any(KeyAtom::is_dubeol) {
            return false;
        }
        let mut pieces = compose(&self.keys).pieces;
        if pieces.last() == Some(&CompositionPiece::BareChoseong) {
            pieces.pop();
        }
        pieces.len() >= 2
            && pieces.first() == Some(&CompositionPiece::Syllable)
            && pieces.contains(&CompositionPiece::BareJungseong)
            && pieces.iter().all(|piece| matches!(piece, CompositionPiece::Syllable | CompositionPiece::BareJungseong))
    }

    /// The buffer is still a Korean word being typed: one or more syllables,
    /// optionally with the first consonant of the next syllable. English words
    /// made of those same keys ("yex", "ivy", "uvr2") do not get to interrupt it.
    /// A reading that is not a syllable anymore ("hello", "other", "deploy")
    /// falls through and can switch.
    ///
    /// A finished English word beats a trailing choseong only at a word
    /// boundary. `lean` is 졍ㅅ while the keys are still open, including as the
    /// start of `leaning` or `leaky`, and becomes `lean` once the word ends.
    /// Switching at the fourth letter is what made `health` leave Hangul at
    /// `heal`.
    fn prefers_whole_korean(&self, word_final: bool) -> bool {
        match self.buffer_shape() {
            Shape::Clean(syllables) => syllables >= 1,
            Shape::Trailing(syllables) => syllables >= 1 && !self.english_word_beats_trailing_choseong(word_final),
            _ => false,
        }
    }

    /// `true` when a word boundary should replace an unfinished trailing
    /// choseong with the English word those keys spell. Open words stay
    /// Hangul: `lean` inside `leaning` is still 졍ㅅ.
    fn english_word_beats_trailing_choseong(&self, word_final: bool) -> bool {
        if !word_final {
            return false;
        }
        let lower = self.english_text(0, self.keys.len()).to_lowercase();
        // Three keys is 모ㄹ (`ivy`) and 메ㄴ (`ich` inside 메뉴). A syllable
        // with a batchim, or two syllables, plus the next choseong is four.
        lower.chars().count() >= 4 && lower.chars().all(char::is_alphabetic) && self.lexicon.is_english_word(&lower)
    }

    /// Filenames, URLs, domains, paths, and emails are one English token.
    /// Interior punctuation does not open a new language decision, so "md"
    /// after a dot is not free to become the syllable 히.
    fn prefers_whole_english_code(&self) -> bool {
        self.is_english_code(&self.english_text(0, self.keys.len()))
    }

    fn code_particle_split(&self) -> Option<usize> {
        if self.keys.len() < 4 {
            return None;
        }
        for end in (2..self.keys.len()).rev() {
            let tail = compose(&self.keys[end..]).text;
            if !is_particle(&tail) {
                continue;
            }
            let head = self.english_text(0, end);
            let Some(last) = head.chars().next_back() else { continue };
            if !(last.is_alphabetic() || last.is_numeric()) {
                continue;
            }
            let established_code = self.lexicon.is_code_token(&head)
                && self.segments.first().is_some_and(|first| first.lang == Language::English && first.end >= end);
            if (self.is_english_code(&head) || established_code) && self.preserves_composition_at(end) {
                return Some(end);
            }
        }
        None
    }

    fn is_english_code(&self, text: &str) -> bool {
        if !text.chars().any(code_token::is_interior) {
            return false;
        }
        if !text
            .chars()
            .all(|character| character.is_alphabetic() || character.is_numeric() || code_token::is_interior(character))
        {
            return false;
        }
        let mut labels = text.split(code_token::is_interior).filter(|label| !label.is_empty()).peekable();
        if labels.peek().is_none() {
            return false;
        }
        labels.all(|label| self.label_stays_english(label))
    }

    fn label_stays_english(&self, label: &str) -> bool {
        let lower = label.to_lowercase();
        // One syllable stays in the token: "md" is 히, and a file extension is
        // the same shape. Two syllables are Korean unless they are a real
        // English word. 요 sits on the 4 key, so a Hangul word must not be
        // kept just because it looks like a version token.
        if self.clean_syllable_count(label) < 2 {
            return true;
        }
        lower.chars().all(char::is_alphabetic) && self.lexicon.is_english_word(&lower)
    }

    /// The whole buffer is one English letter run: a word, or the start of one.
    /// In Korean mode Hangul stickiness runs first; English mode gives
    /// dictionary words and prefixes priority over syllable-shaped readings.
    /// An all-digit pad run is handled first, so "MN" is not read as a prefix.
    fn prefers_whole_english_word(&self, word_final: bool) -> bool {
        let spelling = self.english_text(0, self.keys.len());
        let lower = spelling.to_lowercase();
        if lower.chars().count() < 2 || !lower.chars().all(char::is_alphabetic) {
            return false;
        }
        // 390 yv is the common particle 로. Do not let the name Yvonne's
        // dictionary prefix keep this explicitly preferred reading in English.
        if lower == "yv" && spelling == "yv" && compose(&self.keys).text == "로" {
            return false;
        }
        if self.lexicon.is_english_word(&lower) {
            return true;
        }
        if self.is_english_mode_chat_reaction() {
            return false;
        }
        if !self.lexicon.is_english_prefix(&lower) {
            return false;
        }
        // jc, jd, uv, and uvr prefix jcmd, jdb, uva, and uvrou. Keep that
        // Latin while the next letter may still finish the word. At a word
        // boundary the letters are not an English word, so one frequent
        // syllable wins whether it took two keys (에, 이, 도) or more
        // (돼 is uvr, 뭐 is ibt). Real words (of → 차, ut → 더, jew → 열,
        // uvrou) returned above. "md" is valid Hangul 히 but not frequent,
        // so frequent_open_syllable leaves it Latin.
        if word_final && spelling.chars().all(char::is_lowercase) && self.frequent_open_syllable() {
            return false;
        }
        true
    }

    /// One finished syllable from the frequent list (에, 이, 도, 돼), not
    /// merely the large validity list. "md" is valid Hangul 히 and must stay
    /// a prefix. Key count is not limited to two: a compound vowel or batchim
    /// is still one syllable.
    fn frequent_open_syllable(&self) -> bool {
        let composition = compose(&self.keys);
        shape_of(&composition.pieces) == Shape::Clean(1) && self.lexicon.is_korean_word(&composition.text)
    }

    /// Korean-mode run of shifted 390 digit keys (M N U I O J K L < >).
    fn prefers_pad_digits(&self) -> bool {
        self.mode == Language::Korean && !self.keys.is_empty() && self.keys.iter().all(is_pad_digit)
    }

    fn prefers_contextual_english(&self) -> bool {
        if self.context_language != Some(Language::English) {
            return false;
        }
        if !(2..=3).contains(&self.keys.len()) {
            return false;
        }
        let spelling = self.english_text(0, self.keys.len());
        if !spelling.chars().all(|character| character.is_alphabetic() && character.is_lowercase()) {
            return false;
        }
        ENGLISH_CONTEXT_WORDS.contains(&spelling.as_str()) && self.lexicon.is_english_word(&spelling)
    }

    fn pending_acronym_initial_split(&self) -> Option<usize> {
        if self.keys.len() < 3 {
            return None;
        }
        let head_end = self.keys.len() - 1;
        let head = self.english_text(0, head_end);
        let established_code = self.lexicon.is_code_token(&head)
            && all_english(&self.segments)
            && self.segments.last().is_some_and(|last| last.end == head_end);
        if !(is_acronym_head(&head.to_lowercase()) || self.lexicon.is_abbreviation(&head) || established_code) {
            return None;
        }
        let spelling = self.english_text(0, self.keys.len());
        if self.lexicon.is_english_word(&spelling) || self.lexicon.is_english_prefix(&spelling) {
            return None;
        }
        // Number-row `0` is choseong ㅋ. After an acronym, abbreviation, or
        // code token it continues the digits (`zou2` → `zou20`), instead of
        // opening a syllable the way `h` opens AI는. The whole token is then
        // kept Latin unless those keys are a dictionary word (`kvaj5` → 공유).
        if self.keys[head_end].english.is_ascii_digit() {
            return None;
        }
        if compose(&self.keys[head_end..]).pieces != [CompositionPiece::BareChoseong]
            || !self.preserves_composition_at(head_end)
        {
            return None;
        }
        if self.lexicon.is_korean_word(&compose(&self.keys).text) {
            return None;
        }
        Some(head_end)
    }

    fn single_k_ro_split(&self) -> Option<usize> {
        // Prefer k로/K로 over ㄱ로/5로, before shifted-number handling.
        (self.keys.len() == 3
            && !self.keys.iter().any(KeyAtom::is_dubeol)
            && self.english_text(0, 1).to_lowercase() == "k"
            && compose(&self.keys[1..]).text == "로")
            .then_some(1)
    }

    /// Index where an English acronym ends and a Hangul particle begins.
    /// `None` when the buffer should stay one language.
    fn acronym_particle_split(&self) -> Option<usize> {
        let count = self.keys.len();
        if count < 4 {
            return None;
        }
        let spelling = self.english_text(0, count).to_lowercase();
        let whole = compose(&self.keys);
        // 아까, 아는, 뭔가, 쪽에서. A dictionary reading is never an acronym.
        if self.lexicon.is_korean_word(&whole.text) {
            return None;
        }
        let english_run = || self.lexicon.is_english_word(&spelling) || self.lexicon.is_english_prefix(&spelling);
        if self.keys.iter().all(KeyAtom::is_dubeol) {
            // In two-set input the final consonant of an English spelling can
            // borrow a vowel from the particle. The Hangul-only composition
            // boundary therefore cannot decide an English/Korean split.
            for head_end in 3..count {
                let head = self.english_text(0, head_end);
                let listed = is_acronym_head(&head.to_lowercase());
                if !(head.chars().all(char::is_alphabetic)
                    && (self.lexicon.is_english_word(&head) || listed || self.lexicon.is_abbreviation(&head)))
                {
                    continue;
                }
                if !listed && english_run() {
                    continue;
                }
                let tail = compose(&self.keys[head_end..]);
                if !is_particle(&tail.text) || !matches!(shape_of(&tail.pieces), Shape::Clean(_)) {
                    continue;
                }
                return Some(head_end);
            }
        }
        // Retain whole English words except for explicit two-set acronym
        // plus particle readings above (apisms is also an English plural).
        if english_run() {
            return None;
        }
        let limit = 6.min(count - 1);
        if limit < 3 {
            return None;
        }
        let whole_clean = matches!(shape_of(&whole.pieces), Shape::Clean(_));
        for head_end in 3..=limit {
            let tail = compose(&self.keys[head_end..]);
            if !is_particle(&tail.text) {
                continue;
            }
            if !matches!(shape_of(&tail.pieces), Shape::Clean(_)) {
                continue;
            }
            if !self.preserves_composition_at(head_end) {
                continue;
            }
            let head = compose(&self.keys[..head_end]);
            // 열 is "jew". The syllable itself is a Korean word.
            if self.lexicon.is_korean_word(&head.text) {
                continue;
            }
            // Clean Hangul stays Korean. That includes a split which would
            // break ㄲ·ㄸ·ㅃ·ㅆ·ㅉ or a compound batchim: 아까 is not 아ㄱ+가.
            // Only an allowlisted acronym (ktx는) may still divide it.
            let accepted = if whole_clean {
                is_acronym_head(&self.english_text(0, head_end).to_lowercase())
            } else {
                self.strong_acronym_head(head_end)
            };
            if accepted {
                return Some(head_end);
            }
        }
        None
    }

    /// Allowlisted acronym, or an English dictionary word of at least four
    /// letters. Used when the buffer is not itself clean Hangul (`github에`).
    fn strong_acronym_head(&self, head_end: usize) -> bool {
        let head = &self.keys[..head_end];
        let spelling = self.english_text(0, head_end);
        let count = spelling.chars().count();
        if !(3..=6).contains(&count) || !spelling.chars().all(char::is_alphabetic) {
            return false;
        }
        if head.iter().all(is_pad_digit) {
            return false;
        }
        let lower = spelling.to_lowercase();
        if is_acronym_head(&lower) {
            return true;
        }
        count >= 4 && self.lexicon.is_english_word(&lower)
    }

    /// ㄲ·ㄸ·ㅃ·ㅆ·ㅉ before the vowel. Two choseong keys, one jamo.
    fn prefers_doubled_choseong(&self) -> bool {
        if self.word_mode != Language::Korean {
            return false;
        }
        let [first, second] = self.keys.as_slice() else { return false };
        let (KeyOutput::Jamo(first), KeyOutput::Jamo(second)) = (first.korean, second.korean) else { return false };
        first.kind == JamoKind::Choseong
            && second.kind == JamoKind::Choseong
            && hangul::merge(first, second).is_some()
            && compose(&self.keys).pieces == [CompositionPiece::BareChoseong]
    }

    fn prefers_number_with_korean_tail(&self) -> bool {
        let number_end = self.keys.iter().take_while(|atom| is_pad_digit(atom)).count();
        if number_end == 0 || number_end >= self.keys.len() {
            return false;
        }
        let spelling = self.english_text(0, self.keys.len());
        let lower = spelling.to_lowercase();
        let tail = compose(&self.keys[number_end..]);
        let tail_shape = shape_of(&tail.pieces);
        let korean_word = self.word_mode == Language::Korean;
        if korean_word
            && !self.lexicon.is_english_word(&lower)
            && !(self.lexicon.is_english_prefix(&lower) && has_vowel(&lower))
        {
            // The initial in 5ㅇ → 5오 → 5와 is still Korean input.
            // Reinterpreting Kj as English here commits text that a web
            // editor may be unable to replace when the vowel arrives.
            if matches!(tail_shape, Shape::SingleBare | Shape::Trailing(_)) {
                return true;
            }
        }
        let tail_clean = matches!(tail_shape, Shape::Clean(_));
        // Colloquial 두 must not turn the English prefix Kub into 5두.
        // Keep the existing precedence for standard particles and counters.
        if korean_word
            && is_particle(&tail.text)
            && tail_clean
            && (tail.text != "두" || !self.prefers_capitalized_english())
        {
            return true;
        }
        // 8시 is also "Ind", 9대 "Our" and 9장 "Olfa". In Korean mode a counter
        // after the number outranks a capitalized English word or prefix.
        if korean_word && starts_with_counter(&tail.text) && tail_clean {
            return true;
        }
        if spelling.chars().all(char::is_alphabetic)
            && (self.lexicon.is_english_word(&spelling) || self.lexicon.is_english_prefix(&spelling))
        {
            return false;
        }
        match tail_shape {
            Shape::Clean(syllables) => {
                syllables >= 2
                    || self.lexicon.is_korean_word(&tail.text)
                    || NUMBER_COUNTERS.contains(&tail.text.as_str())
            }
            _ => false,
        }
    }

    /// BB is !! on 390 (Shift+B), and the same run on the other moved
    /// symbol keys stays punctuation. On 최종, B N M read as ?, -, and a quote.
    /// HP, BBC, and Hello add a different letter and are not this case.
    fn prefers_repeated_symbol(&self) -> bool {
        self.mode == Language::Korean && is_repeated_shifted_symbol(&self.keys)
    }

    /// "Introduce" / "Open" / "Hello". The first shifted key is a digit or
    /// symbol on 390, and it is put back once the spelling is English.
    /// "OK" and "IO" are only digit keys, so they stay 95 and 89.
    fn prefers_capitalized_english(&self) -> bool {
        let spelling = self.english_text(0, self.keys.len());
        if spelling.chars().count() < 2 || !spelling.chars().all(char::is_alphabetic) {
            return false;
        }
        if !self.keys.iter().any(is_shifted_letter) {
            return false;
        }
        if self.keys.iter().all(is_pad_digit) {
            return false;
        }
        // Unknown acronyms (DJI → D48) still carry explicit uppercase intent.
        // Pure 390 digit runs retain their number reading above.
        if spelling.chars().all(char::is_uppercase) {
            return true;
        }
        if self.lexicon.is_abbreviation(&spelling) {
            return true;
        }
        let lower = spelling.to_lowercase();
        self.lexicon.is_english_word(&lower) || self.lexicon.is_english_prefix(&lower)
    }

    /// 0.1, 3.14, 1,000, 2026.10.23. The keys are shifted digits with '.'
    /// or ',' between them. "OK." stays an abbreviation: a trailing
    /// separator after a word is a period, not a decimal point.
    fn prefers_shifted_number(&self) -> bool {
        if self.mode != Language::Korean || self.keys.is_empty() {
            return false;
        }
        let mut digits = 0;
        let mut separators = 0;
        for atom in &self.keys {
            if is_pad_digit(atom) {
                digits += 1;
            } else if is_separator(atom) {
                separators += 1;
            } else {
                return false;
            }
        }
        if digits == 0 || separators == 0 {
            return false;
        }
        if let Some((last, body)) = self.keys.split_last()
            && is_separator(last)
            && !body.iter().any(is_separator)
        {
            let letters: String = body.iter().map(|atom| atom.english).collect();
            let lower = letters.to_lowercase();
            if self.lexicon.is_abbreviation(&letters)
                || self.lexicon.is_english_word(&lower)
                || self.lexicon.is_english_prefix(&lower)
            {
                return false;
            }
        }
        true
    }

    /// True when every piece is a bare jamo and the QWERTY spelling is an
    /// English word. That reading is not Hangul (`wsl` → ㄹㄴㅈ).
    fn bare_jamo_spells_english_word(&self) -> bool {
        let composition = compose(&self.keys);
        if composition.pieces.len() < 2 || !composition.pieces.iter().all(|piece| is_bare_piece(*piece)) {
            return false;
        }
        let lower = self.english_text(0, self.keys.len()).to_lowercase();
        lower.chars().count() >= 2 && lower.chars().all(char::is_alphabetic) && self.lexicon.is_english_word(&lower)
    }

    /// Repeated bare jamo in a word that was started in Korean: ㅎㅎ, ㅋㅋ,
    /// ㅠㅠ, ㅜㅜ, ㄱㅅ. An English word ("to", "know", "wsl") and a prefix that
    /// was already Latin ("th", "ws" inside `wsl`) are left alone. ㄲ·ㄸ·ㅃ are
    /// one choseong, not this case.
    fn prefers_bare_jamo_run(&self, previous: Option<&[Segment]>) -> bool {
        // Repeated m is laughter even when the token starts in English.
        // Check the active layout so two-set m (ㅡ) keeps its usual reading.
        if self.keys.len() >= 2 && self.keys.iter().all(|atom| atom.english == 'm') {
            let text = compose(&self.keys).text;
            if text.chars().count() == self.keys.len() && text.chars().all(|character| character == 'ㅎ') {
                return true;
            }
        }
        if self.word_mode == Language::English {
            return self.is_english_mode_chat_reaction();
        }
        let composition = compose(&self.keys);
        if composition.pieces.len() < 2 || !composition.pieces.iter().all(|piece| is_bare_piece(*piece)) {
            return false;
        }
        let spelling = self.english_text(0, self.keys.len());
        let lower = spelling.to_lowercase();
        // "src/" is a path. The slash key is also ㅗ, so the pieces are bare jamo.
        if spelling.chars().any(code_token::is_interior) {
            return false;
        }
        if self.lexicon.is_english_word(&lower)
            || self.lexicon.is_code_token(&spelling)
            || self.lexicon.is_abbreviation(&spelling)
        {
            return false;
        }
        if let Some(previous) = previous
            && !previous.is_empty()
            && all_english(previous)
            && (self.lexicon.is_english_prefix(&lower) || self.lexicon.is_english_word(&lower))
        {
            return false;
        }
        true
    }

    fn is_english_mode_chat_reaction(&self) -> bool {
        if self.keys.len() < 2 {
            return false;
        }
        let composition = compose(&self.keys);
        if !composition.pieces.iter().all(|piece| is_bare_piece(*piece)) {
            return false;
        }
        let text = composition.text.as_str();
        let repeated = all_same_from(text, "ㅋㅎㅠㅜ");
        let okk = text.strip_prefix("ㅇㅋ").is_some_and(|rest| rest.chars().all(|character| character == 'ㅋ'));
        if !(repeated || okk || CHAT_REACTIONS.contains(&text)) {
            return false;
        }
        let spelling = self.english_text(0, self.keys.len());
        let lower = spelling.to_lowercase();
        if !spelling.chars().any(char::is_alphabetic)
            || !spelling.chars().all(|character| character.is_alphabetic() || character.is_numeric())
        {
            return false;
        }
        // ㅇㅇ is already an explicit chat reaction. The dictionary's "jjs"
        // prefix must not mask it; complete English words still win.
        !self.lexicon.is_english_word(&lower)
            && (text == "ㅇㅇ" || !self.lexicon.is_english_prefix(&lower))
            && !self.lexicon.is_code_token(&spelling)
            && !self.lexicon.is_abbreviation(&spelling)
    }

    fn clean_syllable_count(&self, text: &str) -> usize {
        let layout = self.keys.first().map_or(self.layout, |atom| atom.layout);
        let atoms: Vec<KeyAtom> = text.chars().map(|character| layout.atom(character)).collect();
        match shape_of(&compose(&atoms).pieces) {
            Shape::Clean(count) => count,
            _ => 0,
        }
    }

    /// Korean reading of an open chat mark (ㅎㅎ, ㄱㅅ, …). Established
    /// Latin (`ss`, `aa`, `wsl`) is not this, even when those keys are bare jamo.
    fn is_open_korean_chat_mark(&self) -> bool {
        if self.segments.is_empty() || self.segments.iter().any(|segment| segment.lang != Language::Korean) {
            return false;
        }
        let composition = compose(&self.keys);
        composition.pieces.len() >= 2
            && composition.pieces.iter().all(|piece| is_bare_piece(*piece))
            && is_chat_mark_text(&composition.text)
    }

    /// A period after a Hangul syllable commits the word. After an English
    /// token or bare jamo label, it stays available for a filename or domain.
    fn continues_as_code(&self, atom: &KeyAtom) -> bool {
        if !self.auto_switch || self.locked.is_some() || self.keys.is_empty() {
            return false;
        }
        if !(code_token::is_joiner(atom.english) || (self.mode == Language::English && atom.english == '/')) {
            return false;
        }
        if !self.segments.is_empty() && all_english(&self.segments) {
            return true;
        }
        // ㅎㅎ. ㅋㅋ. ㅠㅠ. ㄱㄱ. ㅇㅇ. The mark is already the word, so a
        // joiner ends it instead of turning the buffer into a domain label.
        // English mode still starts a label at the period (`jj.`). Mixed
        // bare jamo (`namu`) is not a mark and falls through.
        if self.word_mode == Language::Korean && self.is_open_korean_chat_mark() {
            return false;
        }
        // Bare jamo such as namu → ㅅㅇㅎㄷ can be a domain label.
        // Keep the period in the buffer so code scoring can recover namu.wiki.
        // A composed Korean syllable still ends its word at a period.
        if atom.english == '.' && self.keys.iter().all(|key| key.english.is_alphabetic()) {
            let pieces = compose(&self.keys).pieces;
            if pieces.len() >= 2 && pieces.iter().all(|piece| is_bare_piece(*piece)) {
                return true;
            }
        }
        if self.keys.len() != 1 || !code_token::is_starter(atom.english) {
            return false;
        }
        self.buffer_shape() == Shape::SingleBare
    }

    fn buffer_shape(&self) -> Shape {
        shape_of(&compose(&self.keys).pieces)
    }

    fn english_text(&self, start: usize, end: usize) -> String {
        self.keys[start..end].iter().map(|atom| atom.english).collect()
    }

    fn render(&self, parts: &[Segment]) -> String {
        let mut text = String::new();
        for part in parts {
            let slice = &self.keys[part.start..part.end];
            match part.lang {
                Language::English => text.extend(slice.iter().map(|atom| atom.english)),
                Language::Korean => text.push_str(&compose(slice).text),
            }
        }
        text
    }

    // MARK: - Client edits

    fn sync_client(&mut self, did_auto_convert: bool) -> SessionUpdate {
        let (next_plain, next_marked) = self.client_split();
        self.emit(next_plain, next_marked, did_auto_convert)
    }

    /// Confirmed English, digits, and symbols are inserted once. Trailing Hangul,
    /// including every syllable of the open word, stays one marked range.
    /// Committing a finished syllable and then inserting the whole word again
    /// types that syllable twice (`프로에서` → `프프로프로에서`). Digits that
    /// share a segment with a syllable ("1개") stay inserted; only the
    /// syllable is marked.
    fn client_split(&self) -> (String, String) {
        let split = self.live_split();
        if self.composing { split } else { buffer_open_syllable(split.0, split.1) }
    }

    fn live_split(&self) -> (String, String) {
        if self.segments.is_empty() {
            return (String::new(), String::new());
        }
        let undecided = self.auto_switch && self.locked.is_none() && self.plain.is_empty();
        let all_marked = || (String::new(), self.render(&self.segments));
        let recognized = |spelling: &str| {
            self.lexicon.is_english_word(spelling)
                || self.lexicon.is_abbreviation(spelling)
                || self.lexicon.is_code_token(spelling)
                || self.is_english_code(spelling)
        };
        // English-mode prefixes such as p/pf/pfj may still become 파이.
        // Keep them replaceable until English is confirmed; web editors can
        // refuse to replace Latin characters once they leave the marked range.
        if undecided
            && self.word_mode == Language::English
            && let Some(first) = self.keys.first()
            && first.english.is_lowercase()
            && let KeyOutput::Jamo(initial) = first.korean
            && initial.kind == JamoKind::Choseong
        {
            let spelling = self.english_text(0, self.keys.len());
            let confirmed = spelling.chars().count() >= 2 && recognized(&spelling);
            let plausible = matches!(self.buffer_shape(), Shape::SingleBare | Shape::Clean(_) | Shape::Trailing(_));
            if !confirmed && plausible {
                return all_marked();
            }
        }
        // Shift+H is an opening quote, but Hp can temporarily read as an
        // English prefix before Hpf becomes '파. Keep that undecided prefix
        // in one mark: terminals and web editors cannot reliably replace
        // punctuation or Latin text after it has been committed.
        if undecided
            && self.word_mode == Language::Korean
            && let Some(first) = self.keys.first()
            && is_shifted_letter(first)
            && !is_pad_digit(first)
        {
            let spelling = self.english_text(0, self.keys.len());
            let confirmed_english = all_english(&self.segments)
                && (recognized(&spelling)
                    || (spelling.chars().count() >= 2 && spelling.chars().all(char::is_uppercase)));
            if !confirmed_english {
                return all_marked();
            }
        }
        // Shift+I is 8, but I-n-d is also "Ind" and I-n-t is "Int". Keep the
        // number and any undecided English reading in one mark until the word
        // settles: web editors cannot replace an 8 or "In" already committed,
        // which left 8시 as "Ind" or "8In8시".
        if undecided
            && self.word_mode == Language::Korean
            && let Some(first) = self.keys.first()
            && is_pad_digit(first)
            && is_shifted_letter(first)
        {
            let spelling = self.english_text(0, self.keys.len());
            let count = spelling.chars().count();
            // "My" is settled; "In" can still become 8시 (ㅅ starts a counter).
            let undecided_length = count == 2 && is_counter_initial(&compose(&self.keys[1..]).text);
            let confirmed_english =
                all_english(&self.segments) && count >= 2 && !undecided_length && recognized(&spelling);
            if !confirmed_english {
                return all_marked();
            }
        }
        // 수v put the syllable and the stray Latin letter into committed
        // text. Backspace then replaces that range, and a web editor ignores
        // a replacement when nothing is marked, so the typo stays beside the
        // correction (수v수고). An open Hangul-then-Latin token stays one mark
        // until an earlier part of it has already been committed.
        if self.plain.is_empty() && self.english_follows_hangul() {
            return all_marked();
        }
        let mut split_at = self.segments.len();
        while split_at > 0 {
            let segment = self.segments[split_at - 1];
            if segment.lang == Language::Korean && self.segment_composes(segment) {
                split_at -= 1;
            } else {
                break;
            }
        }
        let head = self.render(&self.segments[..split_at]);
        let tail = &self.segments[split_at..];
        let Some(first) = tail.first() else { return (head, String::new()) };
        let (peeled_stable, peeled_open) = self.peel_digits_and_symbols(*first);
        let mut marked = peeled_open;
        if tail.len() > 1 {
            marked.push_str(&self.render(&tail[1..]));
        }
        if marked.is_empty() {
            return (head + &self.render(tail), String::new());
        }
        // A particle can keep growing (에 → 에서). Keep the entire Korean
        // suffix marked until a real boundary, including after ASCII heads.
        (head + &peeled_stable, marked)
    }

    fn english_follows_hangul(&self) -> bool {
        let mut saw_hangul = false;
        for segment in self.segments.iter().filter(|segment| segment.end > segment.start) {
            if segment.lang == Language::Korean {
                saw_hangul = true;
            } else if saw_hangul {
                return true;
            }
        }
        false
    }

    /// A 390 digit or symbol at the front of a Hangul segment was already
    /// inserted. Putting it inside the new marked text types it a second time.
    fn peel_digits_and_symbols(&self, segment: Segment) -> (String, String) {
        let composition = compose(&self.keys[segment.start..segment.end]);
        if composition.text.chars().count() != composition.pieces.len() {
            return (String::new(), composition.text);
        }
        let mut characters = composition.text.char_indices();
        for piece in &composition.pieces {
            let Some((offset, _)) = characters.next() else { break };
            match piece {
                CompositionPiece::Digit | CompositionPiece::Symbol => {}
                _ => {
                    let (stable, open) = composition.text.split_at(offset);
                    return (stable.to_owned(), open.to_owned());
                }
            }
        }
        (composition.text, String::new())
    }

    fn segment_composes(&self, segment: Segment) -> bool {
        compose(&self.keys[segment.start..segment.end])
            .pieces
            .iter()
            .any(|piece| !matches!(piece, CompositionPiece::Digit | CompositionPiece::Symbol))
    }

    /// Append newly finished text. The open syllable stays in `preedit` and is
    /// not sent. A raw host cannot delete, so a reading that is not a suffix of
    /// what was already committed does not touch the field.
    fn emit_append_only(&mut self, to_plain: String, to_marked: String, did_auto_convert: bool) -> SessionUpdate {
        let extends = to_plain.starts_with(&self.plain);
        let field = if extends {
            let delta = &to_plain[self.plain.len()..];
            if delta.is_empty() { FieldEdit::None } else { FieldEdit::Insert { text: delta.to_owned() } }
        } else {
            FieldEdit::None
        };
        if extends {
            self.plain = to_plain;
            self.preedit = to_marked;
        } else {
            let full = format!("{to_plain}{to_marked}");
            if let Some(rest) = full.strip_prefix(self.plain.as_str()) {
                self.preedit = rest.to_owned();
            } else if self.plain.starts_with(&to_plain) && to_marked.is_empty() {
                // Backspace removed a character the host will delete itself.
                self.plain = to_plain;
                self.preedit.clear();
            } else {
                self.preedit = to_marked;
            }
        }
        self.make(field, self.preedit.clone(), did_auto_convert)
    }

    fn emit(&mut self, to_plain: String, to_marked: String, did_auto_convert: bool) -> SessionUpdate {
        if !self.composing {
            return self.emit_append_only(to_plain, to_marked, did_auto_convert);
        }
        let mut field = client_diff(&self.plain, &self.preedit, &to_plain, &to_marked);
        let mut next_plain = to_plain;
        let mut next_marked = to_marked;
        // insertThenMark and a rewrite that also marks are two client calls.
        // The second call still sees the old caret and inserts the text again.
        if field.sends_more_than_one_edit() && marks_after_insert(&field) {
            let text = format!("{next_plain}{next_marked}");
            if self.plain.is_empty() {
                // The syllables already on screen are still inside the mark.
                // insertText of the whole word lands beside that mark, which is
                // how 프로에서 became 프프로프로에서. One setMarkedText replaces it.
                field = FieldEdit::Mark { text: text.clone() };
                next_plain = String::new();
                next_marked = text;
            } else {
                let span = utf16_len(&self.plain) + utf16_len(&self.preedit);
                field = FieldEdit::InsertReplacing { utf16: span, text: text.clone() };
                next_plain = text;
                next_marked = String::new();
            }
        }
        self.plain = next_plain;
        self.preedit = next_marked;
        self.make(field, self.preedit.clone(), did_auto_convert)
    }

    fn make(&self, field: FieldEdit, marked: String, did_auto_convert: bool) -> SessionUpdate {
        SessionUpdate { mode: self.mode, did_auto_convert, preedit: marked, field }
    }
}

/// Keep the whole open Hangul or undecided tail off the host. A boundary can
/// reread it (`jj` is ㅇㅇ until `.`), and a raw field cannot delete what was
/// already committed. Confirmed plain text is stable and may be inserted.
fn buffer_open_syllable(plain: String, marked: String) -> (String, String) {
    (plain, marked)
}

fn is_sentence_boundary(breaker: char) -> bool {
    matches!(breaker, '.' | '\n' | '?' | '!')
}

fn replace_finished_suffix(suffix: &str, next_plain: &str, next_marked: &str) -> FieldEdit {
    let width = utf16_len(suffix);
    if next_marked.is_empty() {
        return FieldEdit::InsertReplacing { utf16: width, text: next_plain.to_owned() };
    }
    if next_plain.is_empty() {
        return FieldEdit::ReplaceBeforeCaret { utf16: width, text: next_marked.to_owned() };
    }
    FieldEdit::InsertReplacingThenMark { utf16: width, insert: next_plain.to_owned(), mark: next_marked.to_owned() }
}

fn marks_after_insert(field: &FieldEdit) -> bool {
    match field {
        FieldEdit::InsertThenMark { .. } | FieldEdit::InsertReplacingThenMark { .. } => true,
        FieldEdit::Rewrite { then_mark, .. } => !then_mark.is_empty(),
        _ => false,
    }
}

fn client_diff(from_plain: &str, from_marked: &str, to_plain: &str, to_marked: &str) -> FieldEdit {
    let mark = || FieldEdit::Mark { text: to_marked.to_owned() };
    // Appending to the committed prefix. Swift tests this once with an empty
    // mark and once without; both branches build the same edit.
    let appended = |delta: &str| {
        if to_marked.is_empty() {
            FieldEdit::Insert { text: delta.to_owned() }
        } else if delta.is_empty() {
            mark()
        } else {
            FieldEdit::InsertThenMark { insert: delta.to_owned(), mark: to_marked.to_owned() }
        }
    };
    if from_plain == to_plain && from_marked == to_marked {
        return FieldEdit::None;
    }
    if from_plain == to_plain {
        return mark();
    }
    if from_marked.is_empty()
        && let Some(delta) = to_plain.strip_prefix(from_plain)
    {
        return appended(delta);
    }
    if from_marked.is_empty()
        && let Some(dropped) = from_plain.strip_prefix(to_plain)
    {
        let removed = utf16_len(dropped);
        if to_marked.is_empty() {
            return FieldEdit::InsertReplacing { utf16: removed, text: String::new() };
        }
        return FieldEdit::ReplaceBeforeCaret { utf16: removed, text: to_marked.to_owned() };
    }
    if let Some(delta) = to_plain.strip_prefix(from_plain) {
        return appended(delta);
    }
    if let Some(dropped) = from_plain.strip_prefix(to_plain) {
        let removed = utf16_len(dropped);
        if removed == 0 {
            return mark();
        }
        // One range covers the committed tail and the live mark. A second
        // call would still see the old caret and insert the tail again.
        let span = removed + utf16_len(from_marked);
        if to_marked.is_empty() {
            return FieldEdit::InsertReplacing { utf16: span, text: String::new() };
        }
        return FieldEdit::ReplaceBeforeCaret { utf16: span, text: to_marked.to_owned() };
    }
    let span = utf16_len(from_plain) + utf16_len(from_marked);
    FieldEdit::Rewrite { utf16: span, text: to_plain.to_owned(), then_mark: to_marked.to_owned() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use CompositionPiece::*;

    #[test]
    fn shapes() {
        assert_eq!(shape_of(&[]), Shape::Invalid);
        assert_eq!(shape_of(&[Symbol]), Shape::Symbol);
        assert_eq!(shape_of(&[Symbol, Symbol]), Shape::Invalid);
        assert_eq!(shape_of(&[Syllable, Symbol]), Shape::Invalid);
        assert_eq!(shape_of(&[Digit, Digit]), Shape::Digits);
        assert_eq!(shape_of(&[BareChoseong]), Shape::SingleBare);
        assert_eq!(shape_of(&[BareJungseong]), Shape::SingleBare);
        assert_eq!(shape_of(&[Syllable, Syllable]), Shape::Clean(2));
        assert_eq!(shape_of(&[Digit, Syllable]), Shape::Clean(1));
        assert_eq!(shape_of(&[Syllable, BareChoseong]), Shape::Trailing(1));
        assert_eq!(shape_of(&[Digit, BareChoseong]), Shape::Invalid);
        assert_eq!(shape_of(&[BareChoseong, BareChoseong]), Shape::Invalid);
        assert_eq!(shape_of(&[Syllable, BareJungseong]), Shape::Invalid);
    }

    #[test]
    fn counters() {
        assert!(starts_with_counter("시"));
        assert!(starts_with_counter("개는"));
        assert!(starts_with_counter("번째"));
        assert!(starts_with_counter("마리가"));
        assert!(!starts_with_counter("시간"));
        assert!(!starts_with_counter(""));
        assert!(is_counter_initial("ㅅ"));
        assert!(is_counter_initial("ㄱ"));
        assert!(!is_counter_initial("ㄸ"));
        assert!(!is_counter_initial("시"));
        assert!(!is_counter_initial(""));
    }

    #[test]
    fn extend_grows_only_the_last_segment_by_one_key() {
        let parts = [
            Segment { start: 0, end: 2, lang: Language::English },
            Segment { start: 2, end: 3, lang: Language::Korean },
        ];
        assert_eq!(extend(&parts, 3), Some(parts.to_vec()));
        assert_eq!(extend(&parts, 4).unwrap()[1].end, 4);
        assert_eq!(extend(&parts, 5), None);
        assert_eq!(extend(&[], 1), None);
    }

    #[test]
    fn client_diffs() {
        assert_eq!(client_diff("a", "가", "a", "가"), FieldEdit::None);
        assert_eq!(client_diff("a", "가", "a", "각"), FieldEdit::Mark { text: "각".into() });
        assert_eq!(client_diff("a", "", "ab", ""), FieldEdit::Insert { text: "b".into() });
        assert_eq!(
            client_diff("a", "", "ab", "가"),
            FieldEdit::InsertThenMark { insert: "b".into(), mark: "가".into() }
        );
        assert_eq!(client_diff("ab", "", "a", ""), FieldEdit::InsertReplacing { utf16: 1, text: "".into() });
        assert_eq!(client_diff("ab", "", "a", "가"), FieldEdit::ReplaceBeforeCaret { utf16: 1, text: "가".into() });
        assert_eq!(client_diff("a", "가", "a가", ""), FieldEdit::Insert { text: "가".into() });
        assert_eq!(client_diff("ab", "가", "a", "나"), FieldEdit::ReplaceBeforeCaret { utf16: 2, text: "나".into() });
        assert_eq!(client_diff("ab", "가", "a", ""), FieldEdit::InsertReplacing { utf16: 2, text: "".into() });
        assert_eq!(
            client_diff("ab", "가", "cd", "나"),
            FieldEdit::Rewrite { utf16: 3, text: "cd".into(), then_mark: "나".into() }
        );
    }

    #[test]
    fn input_gate() {
        assert!(!InputGate::should_pass_through(false, false, false, false));
        assert!(InputGate::should_pass_through(true, false, false, false));
        assert!(InputGate::should_pass_through(false, false, false, true));
    }
}
