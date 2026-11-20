//! One-key typo correction of a finished word against the lexicon.

use std::collections::HashMap;
use std::sync::OnceLock;

use crate::hangul::{self, Jamo, JamoKind};
use crate::layout::{KeyAtom, KeyOutput, KeyboardLayout, dubeol};
use crate::lexicon::{Lexicon, nfc};
use crate::session_types::Language;
use crate::typo_log::TypoMemory;

/// Particles (including colloquial 두 for 도) and productive 하다 forms
/// attached to a known dictionary word.
pub mod korean_endings {
    pub const LONGEST_FIRST: [&str; 28] = [
        "에서", "으로", "하고", "하는", "하기", "하다", "하면", "해서", "하자", "는", "은", "이", "가", "를", "을",
        "에", "로", "와", "과", "도", "두", "만", "의", "한", "할", "함", "했", "해",
    ];

    /// Swift `KoreanEndings.set.contains`.
    pub fn contains(text: &str) -> bool {
        LONGEST_FIRST.contains(&text)
    }

    /// The stem and the longest ending `word` (NFC) finishes with.
    pub fn split(word: &str) -> Option<(&str, &'static str)> {
        let count = word.chars().count();
        for ending in LONGEST_FIRST {
            if count > ending.chars().count() && word.ends_with(ending) {
                let stem = &word[..word.len() - ending.len()];
                if !stem.is_empty() {
                    return Some((stem, ending));
                }
            }
        }
        None
    }
}

/// Verb and adjective endings. The validity list holds mostly dictionary
/// forms, so 오고, 와서, 주면, 먹었다 are missing from it. A word made of an
/// attested stem plus one of these endings is a correctly formed word, not a typo.
pub mod korean_verb_endings {
    pub const LONGEST_FIRST: [&str; 40] = [
        "습니다",
        "었는데",
        "았는데",
        "니까",
        "는데",
        "면서",
        "지만",
        "도록",
        "려고",
        "어서",
        "아서",
        "어요",
        "아요",
        "세요",
        "는지",
        "었다",
        "았다",
        "었어",
        "았어",
        "겠다",
        "고",
        "기",
        "면",
        "서",
        "지",
        "게",
        "는",
        "며",
        "니",
        "다",
        "요",
        "자",
        "네",
        "던",
        "도",
        "나",
        "냐",
        "죠",
        "어",
        "아",
    ];

    /// True when `word` is stem + ending and the stem is a known word, is seen
    /// with another verb ending, or ends in the past marker ㅆ (왔, 먹었).
    pub fn is_inflected(word: &str, is_known: impl Fn(&str) -> bool) -> bool {
        let count = word.chars().count();
        let mut joined = String::new();
        for ending in LONGEST_FIRST {
            if !(count > ending.chars().count() && word.ends_with(ending)) {
                continue;
            }
            let stem = &word[..word.len() - ending.len()];
            if stem.chars().count() > 3 {
                continue;
            }
            if is_known(stem) || ends_in_past_marker(stem) {
                return true;
            }
            let attested = LONGEST_FIRST.iter().any(|other| {
                if *other == ending {
                    return false;
                }
                joined.clear();
                joined.push_str(stem);
                joined.push_str(other);
                is_known(&joined)
            });
            if attested {
                return true;
            }
        }
        false
    }

    fn ends_in_past_marker(stem: &str) -> bool {
        let Some(last) = stem.chars().next_back() else { return false };
        let value = last as u32;
        (0xAC00..=0xD7A3).contains(&value) && (value - 0xAC00) % 28 == 20
    }
}

/// One adjacent-key substitution on an English word of at least four letters.
/// An inserted letter (850) loses to that substitution, so hellp becomes hello.
const SHORT_LIMIT: i64 = 700;
const LONG_LIMIT: i64 = 1500;
const MARGIN: i64 = 250;
const INSERT_COST: i64 = 850;
const TRANSPOSE_COST: i64 = 700;
const GENERIC_COST: i64 = 2000;

/// One confident dictionary replacement for a finished word, or `None`.
/// Costs are millicosts so the margin does not depend on binary fractions.
/// A short word allows a single cheap edit. A long one allows two.
pub struct TypoCorrector;

impl TypoCorrector {
    pub fn correction(
        composed: &str,
        keys: &[KeyAtom],
        language: Language,
        lexicon: &Lexicon,
        memory: Option<&dyn TypoMemory>,
    ) -> Option<String> {
        let composed = nfc(composed);
        if composed.is_empty() {
            return None;
        }
        match language {
            Language::Korean => korean(&composed, keys, lexicon, memory),
            Language::English => english(&composed, lexicon, memory),
        }
    }

    /// The keys that type `word` on `layout`: Hangul syllables, plus the
    /// unfinished compatibility jamo a displayed Korean word can end with.
    pub fn keystrokes(word: &str, layout: KeyboardLayout) -> Option<String> {
        let mut result = String::new();
        for character in nfc(word).chars() {
            push_keystrokes(character, layout, &mut result)?;
        }
        (!result.is_empty()).then_some(result)
    }
}

/// A valid or plausible Hangul word is left alone. Otherwise replace it
/// only when one frequent word (or that word plus the typed ending) uses
/// the same keys with exactly one of them different. An extra or missing
/// jamo stays, so 갔어 is not rewritten as 갔었.
fn korean(composed: &str, keys: &[KeyAtom], lexicon: &Lexicon, memory: Option<&dyn TypoMemory>) -> Option<String> {
    if is_already_korean(composed, lexicon) {
        return None;
    }
    if let Some(logged) = logged_korean(composed, memory, lexicon) {
        return Some(logged);
    }
    if composed.chars().count() < 2 || !composed.chars().all(is_modern_syllable) {
        return None;
    }
    let typed: Vec<char> = keys.iter().map(|atom| atom.english).collect();
    if typed.len() < 2 {
        return None;
    }
    let layout = keys.first().map_or(KeyboardLayout::Sebeol390, |atom| atom.layout);
    let candidates = frequent_candidates(lexicon, layout);
    let mut winner: Option<String> = None;
    for row in &candidates.rows {
        if !is_one_key_substitution(&typed, candidates.keys(row)) {
            continue;
        }
        let word = candidates.word(row, lexicon);
        if winner.as_ref().is_some_and(|winner| *winner != word) {
            return None;
        }
        winner = Some(word);
    }
    winner.filter(|winner| winner != composed)
}

fn english(composed: &str, lexicon: &Lexicon, memory: Option<&dyn TypoMemory>) -> Option<String> {
    if !composed.chars().all(char::is_alphabetic) || composed.chars().count() < 2 {
        return None;
    }
    if composed.chars().all(char::is_uppercase) {
        return None;
    }
    if composed.chars().skip(1).any(char::is_uppercase) {
        return None;
    }
    let lower = composed.to_lowercase();
    if lexicon.is_english_word(&lower) || lexicon.is_abbreviation(composed) || lexicon.is_code_token(composed) {
        return None;
    }
    let logged = memory.and_then(|memory| memory.unique_final(composed).or_else(|| memory.unique_final(&lower)));
    if let Some(logged) = logged {
        let logged_lower = logged.to_lowercase();
        if logged_lower != lower && logged.chars().all(char::is_alphabetic) && lexicon.is_english_word(&logged_lower) {
            return Some(matching_case(&logged_lower, composed));
        }
    }
    let source: Vec<char> = lower.chars().collect();
    if source.len() < 4 {
        return None;
    }
    let limit = if source.len() >= 8 { LONG_LIMIT } else { SHORT_LIMIT };
    let band = (source.len() - 1).max(1)..=source.len() + 1;

    // Swift collects every candidate within the limit and then asks for a
    // unique winner: one word at the lowest cost, and the runner-up more
    // than the margin behind. Dictionary entries are unique, so the lowest
    // cost, how many share it, and the next cost are enough.
    let mut scratch = EditScratch::default();
    let mut candidate_chars: Vec<char> = Vec::new();
    let mut best: Option<(i64, &str)> = None;
    let mut best_count = 0usize;
    let mut second = i64::MAX;
    for candidate in lexicon.english_words_with_length(band) {
        if candidate == lower {
            continue;
        }
        candidate_chars.clear();
        candidate_chars.extend(candidate.chars());
        let cost = scratch.edit_cost(&source, &candidate_chars, limit, letter_cost, true);
        if !(1..=limit).contains(&cost) {
            continue;
        }
        match best {
            Some((best_cost, _)) if cost > best_cost => second = second.min(cost),
            Some((best_cost, _)) if cost == best_cost => best_count += 1,
            Some((best_cost, _)) => {
                // A cheaper candidate: the old best is now the runner-up.
                second = best_cost;
                best = Some((cost, candidate));
                best_count = 1;
            }
            None => {
                best = Some((cost, candidate));
                best_count = 1;
            }
        }
    }
    let (best_cost, winner) = best?;
    if best_count != 1 || second <= best_cost + MARGIN {
        return None;
    }
    let cased = matching_case(winner, composed);
    (cased != composed).then_some(cased)
}

fn logged_korean(composed: &str, memory: Option<&dyn TypoMemory>, lexicon: &Lexicon) -> Option<String> {
    let logged = memory?.unique_final(composed)?;
    if logged == composed {
        return None;
    }
    (is_hangul_reading(&logged) && is_already_korean(&logged, lexicon)).then_some(logged)
}

/// Frequent words, the large validity list, a stem plus one ending, or an ending alone.
fn is_already_korean(word: &str, lexicon: &Lexicon) -> bool {
    let word = nfc(word);
    let known = |text: &str| lexicon.is_korean_word(text) || lexicon.is_valid_korean(text);
    if korean_endings::contains(&word) {
        return true;
    }
    if known(&word) {
        return true;
    }
    if let Some((stem, _)) = korean_endings::split(&word)
        && known(stem)
    {
        return true;
    }
    korean_verb_endings::is_inflected(&word, known)
}

fn is_modern_syllable(character: char) -> bool {
    (0xAC00..=0xD7A3).contains(&(character as u32))
}

fn is_hangul_reading(word: &str) -> bool {
    !word.is_empty()
        && word.chars().all(|character| {
            let value = character as u32;
            (0xAC00..=0xD7A3).contains(&value) || (0x3131..=0x318E).contains(&value)
        })
}

fn matching_case(replacement: &str, source: &str) -> String {
    if !source.chars().next().is_some_and(char::is_uppercase) {
        return replacement.to_owned();
    }
    let mut characters = replacement.chars();
    match characters.next() {
        Some(first) => first.to_uppercase().chain(characters).collect(),
        None => String::new(),
    }
}

fn letter_cost(left: char, right: char) -> i64 {
    if left == right {
        0
    } else if orthogonal(left, right) {
        550
    } else {
        GENERIC_COST
    }
}

/// Rows of the edit-distance table, reused across candidates.
#[derive(Default)]
struct EditScratch {
    previous_previous: Vec<i64>,
    previous: Vec<i64>,
    current: Vec<i64>,
}

impl EditScratch {
    fn edit_cost(
        &mut self,
        left: &[char],
        right: &[char],
        limit: i64,
        substitute: impl Fn(char, char) -> i64,
        allow_transpose: bool,
    ) -> i64 {
        if left == right {
            return 0;
        }
        let length_gap = left.len().abs_diff(right.len()) as i64;
        if length_gap * INSERT_COST > limit {
            return limit + 1;
        }
        let columns = right.len() + 1;
        self.previous.clear();
        self.previous.extend((0..columns).map(|column| column as i64 * INSERT_COST));
        self.current.clear();
        self.current.resize(columns, 0);
        self.previous_previous.clear();
        self.previous_previous.resize(columns, 0);
        for row in 1..=left.len() {
            self.current[0] = row as i64 * INSERT_COST;
            let mut row_min = self.current[0];
            for column in 1..=right.len() {
                let mut best = (self.previous[column - 1] + substitute(left[row - 1], right[column - 1]))
                    .min(self.previous[column] + INSERT_COST)
                    .min(self.current[column - 1] + INSERT_COST);
                if allow_transpose
                    && row > 1
                    && column > 1
                    && left[row - 1] == right[column - 2]
                    && left[row - 2] == right[column - 1]
                {
                    best = best.min(self.previous_previous[column - 2] + TRANSPOSE_COST);
                }
                self.current[column] = best;
                row_min = row_min.min(best);
            }
            if row_min > limit {
                return limit + 1;
            }
            // previousPrevious = previous; previous = current. The old
            // previousPrevious row is overwritten in full on the next pass.
            std::mem::swap(&mut self.previous_previous, &mut self.previous);
            std::mem::swap(&mut self.previous, &mut self.current);
        }
        self.previous[right.len()]
    }
}

/// Frequent words, and each of those words with one grammatical ending, as
/// the keys that type them. Rows point into one key buffer and into the
/// lexicon's word list, so a candidate word is only built when its keys match.
pub(crate) struct FrequentCandidates {
    keys: String,
    rows: Vec<CandidateRow>,
}

struct CandidateRow {
    keys_start: u32,
    keys_len: u32,
    /// Index into the lexicon's frequent Korean words.
    word: u32,
    /// 0 for the bare word, otherwise 1 + index into `korean_endings::LONGEST_FIRST`.
    ending: u8,
}

impl FrequentCandidates {
    fn keys(&self, row: &CandidateRow) -> &str {
        let start = row.keys_start as usize;
        &self.keys[start..start + row.keys_len as usize]
    }

    fn word(&self, row: &CandidateRow, lexicon: &Lexicon) -> String {
        let mut word = lexicon.korean_list().word(row.word as usize).to_owned();
        if row.ending > 0 {
            word.push_str(korean_endings::LONGEST_FIRST[row.ending as usize - 1]);
        }
        word
    }
}

/// Per-lexicon candidate tables, one per layout. Swift keys the same cache by
/// `ObjectIdentifier(lexicon)`.
#[derive(Default)]
pub(crate) struct CandidateCache {
    layouts: [OnceLock<FrequentCandidates>; 3],
}

fn layout_index(layout: KeyboardLayout) -> usize {
    match layout {
        KeyboardLayout::Sebeol390 => 0,
        KeyboardLayout::Dubeol => 1,
        KeyboardLayout::SebeolFinal => 2,
    }
}

/// The ending's keys are part of the same one-key comparison. Swift drops
/// repeated (word, keys) rows; they cannot change the winner, so they stay.
fn frequent_candidates(lexicon: &Lexicon, layout: KeyboardLayout) -> &FrequentCandidates {
    lexicon.typo_candidates.layouts[layout_index(layout)].get_or_init(|| {
        let endings: Vec<Option<String>> =
            korean_endings::LONGEST_FIRST.iter().map(|ending| TypoCorrector::keystrokes(ending, layout)).collect();
        let mut keys = String::new();
        let mut rows = Vec::new();
        let words = lexicon.korean_list();
        for index in 0..words.len() {
            let Some(word_keys) = TypoCorrector::keystrokes(words.word(index), layout) else { continue };
            let mut add = |keys: &mut String, tail: &str, ending: u8| {
                let start = keys.len();
                keys.push_str(&word_keys);
                keys.push_str(tail);
                rows.push(CandidateRow {
                    keys_start: start as u32,
                    keys_len: (keys.len() - start) as u32,
                    word: index as u32,
                    ending,
                });
            };
            add(&mut keys, "", 0);
            for (ending, tail) in endings.iter().enumerate() {
                if let Some(tail) = tail {
                    add(&mut keys, tail, ending as u8 + 1);
                }
            }
        }
        FrequentCandidates { keys, rows }
    })
}

/// Same number of keys, one position different. Inserting or deleting a key
/// is not a correction: 갔어 and 갔었 differ by the final ㅆ.
fn is_one_key_substitution(typed: &[char], canonical: &str) -> bool {
    // Canonical keys are ASCII, so bytes are keys.
    if typed.len() != canonical.len() {
        return false;
    }
    let mut mismatches = 0;
    for (left, right) in typed.iter().zip(canonical.bytes()) {
        if *left != right as char {
            mismatches += 1;
            if mismatches > 1 {
                return false;
            }
        }
    }
    mismatches == 1
}

fn push_keystrokes(syllable: char, layout: KeyboardLayout, result: &mut String) -> Option<()> {
    let value = syllable as u32;
    if !(0xAC00..=0xD7A3).contains(&value) {
        // Suggestions also receive the unfinished compatibility jamo at the
        // end of the currently displayed Korean word. Choseong and jongseong
        // share compatibility letters; Swift takes whichever its dictionary
        // yields first, this port always prefers choseong, then jungseong.
        let jamo = canonical_keys(layout).ordered.iter().find(|jamo| jamo.compat() == syllable)?;
        return push_key_sequence(*jamo, layout, result);
    }
    let code = value - 0xAC00;
    let cho = 0x1100 + code / 588;
    let jung = 0x1161 + (code % 588) / 28;
    let jong = code % 28;
    // Nothing is appended unless every part of the syllable has keys.
    let mut text = String::new();
    push_key_sequence(Jamo::cho(cho), layout, &mut text)?;
    push_key_sequence(Jamo::jung(jung), layout, &mut text)?;
    if jong != 0 {
        push_key_sequence(Jamo::jong(0x11A8 + jong - 1), layout, &mut text)?;
    }
    result.push_str(&text);
    Some(())
}

/// Prefer a direct key for the selected layout, then try two merging keys.
/// A lowercase letter wins over a digit that produces the same jamo.
fn push_key_sequence(target: Jamo, layout: KeyboardLayout, result: &mut String) -> Option<()> {
    let canonical = canonical_keys(layout);
    if let Some(key) = canonical.by_jamo.get(&target) {
        result.push(*key);
        return Some(());
    }
    // Every compound jamo has exactly one pair of parts.
    let (first, second) = hangul::merge_parts(target)?;
    let first_key = canonical.by_jamo.get(&first)?;
    let second_key = canonical.by_jamo.get(&second)?;
    result.push(*first_key);
    result.push(*second_key);
    Some(())
}

struct CanonicalKeys {
    by_jamo: HashMap<Jamo, char>,
    /// Choseong, jungseong, then jongseong, each by scalar.
    ordered: Vec<Jamo>,
}

fn canonical_keys(layout: KeyboardLayout) -> &'static CanonicalKeys {
    static KEYS: OnceLock<[CanonicalKeys; 3]> = OnceLock::new();
    &KEYS.get_or_init(|| KeyboardLayout::ALL.map(canonical_key))[layout_index(layout)]
}

fn canonical_key(layout: KeyboardLayout) -> CanonicalKeys {
    let mut map: HashMap<Jamo, char> = HashMap::new();
    for character in "abcdefghijklmnopqrstuvwxyz".chars() {
        if let KeyOutput::Jamo(jamo) = layout.atom(character).korean {
            map.insert(jamo, character);
        }
    }
    let rest = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789`-=[]\\;',./~!@#$%^&*()_+{}|:\"<>?";
    for character in rest.chars() {
        if let KeyOutput::Jamo(jamo) = layout.atom(character).korean {
            map.entry(jamo).or_insert(character);
        }
    }
    if layout == KeyboardLayout::Dubeol {
        let initials: Vec<(Jamo, char)> =
            map.iter().filter(|(jamo, _)| jamo.kind == JamoKind::Choseong).map(|(jamo, key)| (*jamo, *key)).collect();
        for (jamo, key) in initials {
            if let Some(last) = dubeol::final_for_initial(jamo) {
                map.insert(last, key);
            }
        }
    }
    let mut ordered: Vec<Jamo> = map.keys().copied().collect();
    ordered.sort_by_key(|jamo| {
        let kind = match jamo.kind {
            JamoKind::Choseong => 0,
            JamoKind::Jungseong => 1,
            JamoKind::Jongseong => 2,
        };
        (kind, jamo.scalar)
    });
    CanonicalKeys { by_jamo: map, ordered }
}

/// Shares an edge. A diagonal pair is not a one-key slip.
fn orthogonal(left: char, right: char) -> bool {
    match (key_position(left), key_position(right)) {
        (Some(a), Some(b)) => a.0.abs_diff(b.0) + a.1.abs_diff(b.1) == 1,
        _ => false,
    }
}

fn key_position(key: char) -> Option<(usize, usize)> {
    const ROWS: [&str; 4] = ["`1234567890-=", "qwertyuiop[]\\", "asdfghjkl;'", "zxcvbnm,./"];
    ROWS.iter()
        .enumerate()
        .find_map(|(row, keys)| keys.chars().position(|other| other == key).map(|column| (row, column)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn endings_split_the_longest_suffix() {
        assert_eq!(korean_endings::split("학교에서"), Some(("학교", "에서")));
        assert_eq!(korean_endings::split("학교는"), Some(("학교", "는")));
        // An ending alone has no stem.
        assert_eq!(korean_endings::split("에서"), None);
        assert_eq!(korean_endings::split("는"), None);
        assert_eq!(korean_endings::split("학교"), None);
        assert!(korean_endings::contains("으로"));
        assert!(korean_endings::contains("두"));
        assert!(korean_endings::contains("한"));
        assert!(!korean_endings::contains("학교"));
        let lengths: Vec<usize> = korean_endings::LONGEST_FIRST.iter().map(|ending| ending.chars().count()).collect();
        assert!(lengths.windows(2).all(|pair| pair[0] >= pair[1]));
        for ending in ["하기", "하다", "하면", "해서", "하자", "하고", "하는"] {
            let word = format!("공부{ending}");
            assert_eq!(korean_endings::split(&word), Some(("공부", ending)));
        }
        for stem in ["못", "안", "공부"] {
            for ending in ["한", "할", "함", "했", "해"] {
                let word = format!("{stem}{ending}");
                assert_eq!(korean_endings::split(&word), Some((stem, ending)));
            }
        }
        for stem in ["너", "나", "저", "우리"] {
            for ending in ["두", "도"] {
                let word = format!("{stem}{ending}");
                assert_eq!(korean_endings::split(&word), Some((stem, ending)));
            }
        }
    }

    #[test]
    fn verb_endings_accept_attested_stems() {
        let known = |word: &str| ["먹다", "오다", "가"].contains(&word);
        // The stem is seen with another ending.
        assert!(korean_verb_endings::is_inflected("먹고", known));
        assert!(korean_verb_endings::is_inflected("오면", known));
        // The stem itself is a word.
        assert!(korean_verb_endings::is_inflected("가고", known));
        // Past marker ㅆ.
        assert!(korean_verb_endings::is_inflected("왔다", known));
        assert!(korean_verb_endings::is_inflected("먹었다", known));
        assert!(!korean_verb_endings::is_inflected("굴고", known));
        assert!(!korean_verb_endings::is_inflected("고", known));
        // Nominal 기: 먹기 is stem 먹, and 가기 is attested by 가다.
        assert!(korean_verb_endings::is_inflected("먹기", |word| word == "먹"));
        assert!(korean_verb_endings::is_inflected("가기", |word| word == "가다"));
        let lengths: Vec<usize> =
            korean_verb_endings::LONGEST_FIRST.iter().map(|ending| ending.chars().count()).collect();
        assert!(lengths.windows(2).all(|pair| pair[0] >= pair[1]));
    }

    #[test]
    fn edit_costs() {
        let chars = |text: &str| text.chars().collect::<Vec<_>>();
        let mut scratch = EditScratch::default();
        let mut cost = |left: &str, right: &str, limit: i64| {
            scratch.edit_cost(&chars(left), &chars(right), limit, letter_cost, true)
        };
        assert_eq!(cost("hello", "hello", SHORT_LIMIT), 0);
        // p and o share an edge; one substitution.
        assert_eq!(cost("hellp", "hello", SHORT_LIMIT), 550);
        // A transposition costs 700, but the row before it is already past
        // the short limit, so only a long word reaches it (as in Swift).
        assert_eq!(cost("wrold", "world", LONG_LIMIT), 700);
        assert_eq!(cost("wrold", "world", SHORT_LIMIT), SHORT_LIMIT + 1);
        // One inserted letter is past the short limit.
        assert_eq!(cost("helllo", "hello", SHORT_LIMIT), SHORT_LIMIT + 1);
        assert_eq!(cost("helllo", "hello", LONG_LIMIT), 850);
        // Two letters apart: the length gap alone is over the limit.
        assert_eq!(cost("hello", "hel", LONG_LIMIT), LONG_LIMIT + 1);
        // q is nowhere near o: delete and insert (2 x 850) beats the generic 2000.
        assert_eq!(cost("hellq", "hello", LONG_LIMIT), 1700);
    }

    #[test]
    fn orthogonal_keys_share_an_edge() {
        assert!(orthogonal('o', 'p'));
        assert!(orthogonal('o', 'l'));
        // Same column model as Swift (no keyboard stagger): 1 sits above w, not q.
        assert!(orthogonal('1', 'w'));
        assert!(!orthogonal('1', 'q'));
        assert!(!orthogonal('o', 'k'));
        assert!(!orthogonal('o', 'o'));
        assert!(!orthogonal('o', 'O'));
    }

    #[test]
    fn case_follows_the_typed_word() {
        assert_eq!(matching_case("hello", "Hellp"), "Hello");
        assert_eq!(matching_case("hello", "hellp"), "hello");
    }
}
