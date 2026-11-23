//! Port of `Sources/SetoCore/Lexicon.swift`.
//!
//! Every word list is one sorted UTF-8 buffer (`\n`-terminated lines) plus a
//! `u32` table of line starts. Large lists are memory-mapped straight from the
//! sorted files that already ship with Seto; lookups binary-search the buffer
//! and compare byte slices, so no `String` is allocated per word.
//!
//! | Constructor            | English                                   | Valid Korean                          |
//! |------------------------|-------------------------------------------|---------------------------------------|
//! | [`Lexicon::load`]      | Resources/english-*.txt, plurals expanded | mmap Resources/korean-valid.txt       |
//! | [`Lexicon::load_for_keyboard`] | mmap keyboard-english.txt         | mmap keyboard-korean-valid.txt        |
//! | [`Lexicon::from_words`] | in-memory                                | in-memory                             |
//!
//! Byte order of NFC UTF-8 equals Swift's `String` ordering, so the files
//! sorted by `iOS/scripts/generate-project.py` (and `korean-valid.txt`, which
//! is sorted after its comment header) can be searched directly.

use std::collections::BTreeSet;
use std::fs::File;
use std::io;
use std::ops::{Deref, RangeInclusive};
use std::path::Path;

use memmap2::Mmap;
use unicode_normalization::{IsNormalized, UnicodeNormalization, is_nfc_quick};
use unicode_segmentation::UnicodeSegmentation;

use crate::typo_corrector::CandidateCache;

pub const DEFAULT_ABBREVIATIONS: &[&str] = &[
    "AI", "OK", "UI", "UX", "OS", "ID", "IP", "PC", "TV", "US", "UK", "KR", "PR", "CI", "CD", "DB", "IO", "QA", "ML",
    "API", "URL", "CPU", "GPU", "RAM", "SSH", "PDF", "USB", "SQL", "CSS", "HTML", "JSON", "HTTP", "HTTPS", "GIF",
    "PNG", "JPG", "SVG", "XML", "IDE", "CLI", "GUI", "NPM", "AWS", "GCP", "JWT", "UTF",
];

pub const DEFAULT_TECH_STEMS: &[&str] = &[
    "mp", "utf", "html", "css", "json", "xml", "http", "https", "ssh", "sql", "png", "jpg", "gif", "svg", "pdf", "usb",
    "cpu", "gpu", "ram", "api", "url", "npm", "js", "ts", "io", "id", "os", "ui", "ux", "db", "ip",
];

enum Storage {
    Mapped(Mmap),
    Owned(Vec<u8>),
}

impl Deref for Storage {
    type Target = [u8];

    fn deref(&self) -> &[u8] {
        match self {
            Storage::Mapped(map) => map,
            Storage::Owned(bytes) => bytes,
        }
    }
}

/// Sorted, de-duplicated UTF-8 lines with only a `u32` offset table resident.
pub struct WordList {
    data: Storage,
    /// Start of each word, plus one sentinel. Word `i` is
    /// `data[starts[i]..starts[i + 1]]` without its trailing `\n`.
    starts: Vec<u32>,
}

impl WordList {
    /// Memory-maps a sorted word file. A header of `#` comment or blank
    /// lines is skipped; after it every line must be a word in strictly
    /// ascending byte order.
    pub fn open(path: &Path) -> io::Result<WordList> {
        let file = File::open(path)?;
        if file.metadata()?.len() == 0 {
            return Ok(WordList::from_sorted(Vec::<String>::new()));
        }
        // SAFETY: the word files are read-only resources; nothing in this
        // process writes to them while the map is alive.
        let map = unsafe { Mmap::map(&file)? };
        WordList::from_storage(Storage::Mapped(map))
            .map_err(|message| io::Error::new(io::ErrorKind::InvalidData, format!("{}: {message}", path.display())))
    }

    /// Builds an in-memory list. Input need not be sorted or unique.
    pub fn from_words<I, S>(words: I) -> WordList
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        let set: BTreeSet<Vec<u8>> = words
            .into_iter()
            .map(|word| word.as_ref().as_bytes().to_vec())
            .filter(|word| !word.is_empty() && !word.contains(&b'\n'))
            .collect();
        WordList::from_sorted(set)
    }

    fn from_sorted<I, W>(sorted: I) -> WordList
    where
        I: IntoIterator<Item = W>,
        W: AsRef<[u8]>,
    {
        let mut data = Vec::new();
        let mut starts = Vec::new();
        for word in sorted {
            starts.push(offset(data.len()));
            data.extend_from_slice(word.as_ref());
            data.push(b'\n');
        }
        starts.push(offset(data.len()));
        WordList { data: Storage::Owned(data), starts }
    }

    fn from_storage(data: Storage) -> Result<WordList, String> {
        if u32::try_from(data.len()).is_err() {
            return Err("word list is larger than 4 GiB".into());
        }
        let mut starts = Vec::new();
        let mut in_header = true;
        let mut previous: Option<&[u8]> = None;
        let mut line_start = 0usize;
        while line_start < data.len() {
            let line_end = memchr_newline(&data[line_start..]).map_or(data.len(), |at| line_start + at);
            let mut line = &data[line_start..line_end];
            // Windows checkouts may store the same sorted lists with CRLF.
            // The `\r` is not part of the word.
            if line.last() == Some(&b'\r') {
                line = &line[..line.len() - 1];
            }
            let skippable = line.is_empty() || line[0] == b'#' || line.iter().all(u8::is_ascii_whitespace);
            if in_header && skippable {
                line_start = line_end + 1;
                continue;
            }
            in_header = false;
            if line.is_empty()
                || line.contains(&b'\r')
                || line[0].is_ascii_whitespace()
                || line[line.len() - 1].is_ascii_whitespace()
            {
                return Err(format!("blank or untrimmed line at byte {line_start}"));
            }
            if std::str::from_utf8(line).is_err() {
                return Err(format!("invalid UTF-8 at byte {line_start}"));
            }
            if previous.is_some_and(|previous| previous >= line) {
                return Err(format!("not strictly sorted at byte {line_start}"));
            }
            previous = Some(line);
            starts.push(line_start as u32);
            line_start = line_end + 1;
        }
        // Sentinel: one past the last word's terminator (or the end of a
        // file without a final newline).
        let end = match starts.last() {
            Some(&last) => {
                let last = last as usize;
                memchr_newline(&data[last..]).map_or(data.len(), |at| last + at + 1)
            }
            None => data.len(),
        };
        starts.push(end as u32);
        Ok(WordList { data, starts })
    }

    pub fn len(&self) -> usize {
        self.starts.len() - 1
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Word `index` as bytes, without its newline. No allocation.
    pub fn word_bytes(&self, index: usize) -> &[u8] {
        let start = self.starts[index] as usize;
        let mut end = self.starts[index + 1] as usize;
        if end > start && self.data[end - 1] == b'\n' {
            end -= 1;
        }
        if end > start && self.data[end - 1] == b'\r' {
            end -= 1;
        }
        &self.data[start..end]
    }

    pub fn word(&self, index: usize) -> &str {
        // Validated at construction.
        std::str::from_utf8(self.word_bytes(index)).unwrap_or_default()
    }

    pub fn iter(&self) -> impl Iterator<Item = &str> + '_ {
        (0..self.len()).map(|index| self.word(index))
    }

    /// First index whose word is not less than `key`.
    pub fn lower_bound(&self, key: &[u8]) -> usize {
        let (mut low, mut high) = (0, self.len());
        while low < high {
            let mid = (low + high) / 2;
            if self.word_bytes(mid) < key {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        low
    }

    pub fn contains(&self, key: &str) -> bool {
        let index = self.lower_bound(key.as_bytes());
        index < self.len() && self.word_bytes(index) == key.as_bytes()
    }

    pub fn has_prefix(&self, key: &str) -> bool {
        if key.is_empty() {
            return false;
        }
        let index = self.lower_bound(key.as_bytes());
        index < self.len() && self.word_bytes(index).starts_with(key.as_bytes())
    }

    /// Up to `limit` words starting with `key`, in sorted order.
    pub fn completions(&self, key: &str, limit: usize) -> Vec<String> {
        let mut result = Vec::new();
        let mut index = self.lower_bound(key.as_bytes());
        while index < self.len() && result.len() < limit {
            let candidate = self.word_bytes(index);
            if !candidate.starts_with(key.as_bytes()) {
                break;
            }
            result.push(self.word(index).to_owned());
            index += 1;
        }
        result
    }
}

/// `stem` is the finished syllables. The next character of a matching word
/// must be a syllable whose choseong index is `choseong_index` (ㄱ is 0).
fn continues_with_choseong(list: &WordList, stem: &str, choseong_index: u32) -> bool {
    if stem.is_empty() {
        return false;
    }
    let stem_bytes = stem.as_bytes();
    let mut index = list.lower_bound(stem_bytes);
    while index < list.len() {
        let word = list.word_bytes(index);
        if !word.starts_with(stem_bytes) {
            return false;
        }
        if let Ok(rest) = std::str::from_utf8(&word[stem_bytes.len()..])
            && let Some(next) = rest.chars().next()
            && syllable_choseong_index(next) == Some(choseong_index)
        {
            return true;
        }
        index += 1;
    }
    false
}

fn syllable_choseong_index(character: char) -> Option<u32> {
    let value = character as u32;
    (0xAC00..=0xD7A3).contains(&value).then_some((value - 0xAC00) / 588)
}

fn offset(position: usize) -> u32 {
    u32::try_from(position).expect("in-memory word list is larger than 4 GiB")
}

fn memchr_newline(bytes: &[u8]) -> Option<usize> {
    bytes.iter().position(|&byte| byte == b'\n')
}

/// NFC form, borrowing when the text is already NFC (the common case).
pub(crate) fn nfc(text: &str) -> std::borrow::Cow<'_, str> {
    if is_nfc_quick(text.chars()) == IsNormalized::Yes {
        std::borrow::Cow::Borrowed(text)
    } else {
        std::borrow::Cow::Owned(text.nfc().collect())
    }
}

/// Swift `String.count`: extended grapheme clusters.
fn character_count(text: &str) -> usize {
    if text.is_ascii() && !text.contains('\r') { text.len() } else { text.graphemes(true).count() }
}

/// Word lists for [`Lexicon::from_words`]; mirrors the Swift initializer.
#[derive(Clone, Debug, Default)]
pub struct LexiconWords<'a> {
    pub english: &'a [&'a str],
    pub korean: &'a [&'a str],
    pub abbreviations: &'a [&'a str],
    pub tech_stems: &'a [&'a str],
    pub valid_korean: &'a [&'a str],
}

pub struct Lexicon {
    english: WordList,
    korean: WordList,
    /// Large Hangul list used only to refuse auto-correction. Not the language lexicon.
    valid_korean: WordList,
    abbreviations: WordList,
    tech_stems: WordList,
    /// `TypoCorrector`'s frequent-word key table, built on first use.
    pub(crate) typo_candidates: CandidateCache,
}

impl Lexicon {
    /// `Lexicon(english:korean:)` with no abbreviations, stems or validity list.
    pub fn new(english: &[&str], korean: &[&str]) -> Lexicon {
        Lexicon::from_words(LexiconWords { english, korean, ..Default::default() })
    }

    /// `Lexicon(english:korean:abbreviations:techStems:validKorean:)`.
    pub fn from_words(words: LexiconWords<'_>) -> Lexicon {
        Lexicon {
            english: WordList::from_words(expand_english(words.english.iter().copied())),
            korean: WordList::from_words(words.korean.iter().map(|word| nfc(word))),
            valid_korean: WordList::from_words(words.valid_korean.iter().map(|word| nfc(word))),
            abbreviations: WordList::from_words(words.abbreviations.iter().map(|word| word.to_uppercase())),
            tech_stems: WordList::from_words(words.tech_stems.iter().map(|word| word.to_lowercase())),
            typo_candidates: CandidateCache::default(),
        }
    }

    /// Desktop lexicon from the `Resources/` directory, like Swift
    /// `Lexicon.load(from:)`. English is expanded with regular plurals in
    /// memory (one buffer); `korean-valid.txt` is memory-mapped.
    pub fn load(directory: &Path) -> io::Result<Lexicon> {
        let english = read_lines(&directory.join("english-words.txt"))?;
        let extra = read_lines(&directory.join("english-extra.txt")).unwrap_or_default();
        let korean = read_lines(&directory.join("korean-words.txt"))?;
        let valid_path = directory.join("korean-valid.txt");
        let valid_korean =
            if valid_path.exists() { WordList::open(&valid_path)? } else { WordList::from_words(Vec::<String>::new()) };
        Ok(Lexicon {
            english: WordList::from_words(expand_english(english.iter().chain(extra.iter()).map(String::as_str))),
            korean: WordList::from_words(korean.iter().map(|word| nfc(word))),
            valid_korean,
            abbreviations: WordList::from_words(DEFAULT_ABBREVIATIONS.iter().map(|word| word.to_uppercase())),
            tech_stems: WordList::from_words(DEFAULT_TECH_STEMS.iter().map(|word| word.to_lowercase())),
            typo_candidates: CandidateCache::default(),
        })
    }

    /// Keyboard lexicon from one directory holding `keyboard-english.txt`,
    /// `keyboard-korean-valid.txt` and `korean-words.txt`, like Swift
    /// `Lexicon.loadForKeyboard(from:)`.
    pub fn load_for_keyboard(directory: &Path) -> io::Result<Lexicon> {
        Lexicon::load_for_keyboard_files(
            &directory.join("keyboard-english.txt"),
            &directory.join("keyboard-korean-valid.txt"),
            &directory.join("korean-words.txt"),
        )
    }

    /// Pre-expanded, sorted word files are mapped, never materialized.
    pub fn load_for_keyboard_files(english: &Path, valid_korean: &Path, korean_words: &Path) -> io::Result<Lexicon> {
        let korean = read_lines(korean_words)?;
        Ok(Lexicon {
            english: WordList::open(english)?,
            korean: WordList::from_words(korean.iter().map(|word| nfc(word))),
            valid_korean: WordList::open(valid_korean)?,
            abbreviations: WordList::from_words(DEFAULT_ABBREVIATIONS.iter().map(|word| word.to_uppercase())),
            tech_stems: WordList::from_words(DEFAULT_TECH_STEMS.iter().map(|word| word.to_lowercase())),
            typo_candidates: CandidateCache::default(),
        })
    }

    pub fn is_english_word(&self, word: &str) -> bool {
        self.english.contains(&word.to_lowercase())
    }

    pub fn is_english_prefix(&self, prefix: &str) -> bool {
        self.english.has_prefix(&prefix.to_lowercase())
    }

    /// Bounded prefix lookup; never materializes the dictionary.
    pub fn english_completions(&self, prefix: &str, limit: usize) -> Vec<String> {
        let key = prefix.to_lowercase();
        if key.is_empty() || limit == 0 {
            return Vec::new();
        }
        self.english.completions(&key, limit)
    }

    pub fn is_korean_word(&self, word: &str) -> bool {
        self.korean.contains(&nfc(word))
    }

    /// A dictionary word starts with `stem` and its next syllable uses this
    /// choseong index (ㄱ is 0). Both the frequent list and the large validity
    /// list count, so an in-progress word is not read as English.
    pub(crate) fn continues_with_choseong(&self, stem: &str, choseong_index: u32) -> bool {
        continues_with_choseong(&self.korean, stem, choseong_index)
            || continues_with_choseong(&self.valid_korean, stem, choseong_index)
    }

    /// True when `word` is in the large validity list. Frequent words live in
    /// [`Lexicon::is_korean_word`].
    pub fn is_valid_korean(&self, word: &str) -> bool {
        self.valid_korean.contains(&nfc(word))
    }

    pub fn korean_word_count(&self) -> usize {
        self.korean.len()
    }

    pub fn valid_korean_word_count(&self) -> usize {
        self.valid_korean.len()
    }

    /// The frequent Korean words, sorted (Swift returns them in set order).
    pub fn korean_words(&self) -> Vec<String> {
        self.korean.iter().map(str::to_owned).collect()
    }

    /// The frequent Korean words as stored: sorted, borrowed, no allocation.
    pub(crate) fn korean_list(&self) -> &WordList {
        &self.korean
    }

    /// English entries whose length in characters is inside `length`.
    pub fn english_words(&self, length: RangeInclusive<usize>) -> Vec<String> {
        self.english_words_with_length(length).map(str::to_owned).collect()
    }

    /// Like [`Lexicon::english_words`], borrowing each entry from the word
    /// buffer. Typo correction scans this at a word boundary.
    pub fn english_words_with_length(&self, length: RangeInclusive<usize>) -> impl Iterator<Item = &str> + '_ {
        self.english.iter().filter(move |word| length.contains(&character_count(word)))
    }

    pub fn is_abbreviation(&self, text: &str) -> bool {
        if character_count(text) < 2 || !text.chars().all(|c| c.is_alphabetic() && c.is_uppercase()) {
            return false;
        }
        self.abbreviations.contains(text)
    }

    /// v2, utf8, mp3, i18n, a11y, e2e. The number row is jamo on 390, so a single
    /// letter plus one digit ("r2", the middle of 했) is not a version token.
    /// One letter, the digit 2, and one letter (`e2e`, `b2b`, `p2p`) is: `2` is
    /// jongseong ㅆ, and a syllable's vowel would have to be that middle key, so
    /// the shape never composes Hangul. A different single digit can (`k8s` is
    /// ㄱ+ㅢ+ㄴ, `i1n` stays bare jamo inside a word). A letter after a version
    /// (`v2a`) is not a token either.
    pub fn is_code_token(&self, text: &str) -> bool {
        let lower = text.to_lowercase();
        let bytes = lower.as_bytes();
        let letters = bytes.iter().take_while(|b| b.is_ascii_lowercase()).count();
        let digits = bytes[letters..].iter().take_while(|b| b.is_ascii_digit()).count();
        let rest = &bytes[letters + digits..];
        // ^v\d+$
        if letters == 1 && bytes[0] == b'v' && digits > 0 && rest.is_empty() {
            return true;
        }
        // ^[a-z]{2,}\d+$
        if letters >= 2 && digits > 0 && rest.is_empty() {
            let stem = &lower[..letters];
            if stem.bytes().any(|b| b"aeiou".contains(&b)) || self.tech_stems.contains(stem) {
                return true;
            }
        }
        // ^[a-z]2[a-z]$ except v2x. See the comment above.
        if letters == 1
            && digits == 1
            && bytes[0] != b'v'
            && bytes[1] == b'2'
            && rest.len() == 1
            && rest[0].is_ascii_lowercase()
        {
            return true;
        }
        // ^[a-z]\d{2,}[a-z]+$
        letters == 1 && digits >= 2 && !rest.is_empty() && rest.iter().all(u8::is_ascii_lowercase)
    }
}

/// Lower-cased words plus their regular plurals. Webster's headwords omit
/// many plurals; indexing them keeps the typing prefixes English.
fn expand_english<'a>(words: impl Iterator<Item = &'a str>) -> BTreeSet<String> {
    let base: BTreeSet<String> = words.map(str::to_lowercase).collect();
    let mut recognized = base.clone();
    for word in &base {
        if character_count(word) < 3 || !word.chars().all(|c| c.is_ascii_alphabetic()) {
            continue;
        }
        let bytes = word.as_bytes();
        let ends = |suffix: &str| word.ends_with(suffix);
        if ends("y") && !b"aeiou".contains(&bytes[bytes.len() - 2]) {
            recognized.insert(format!("{}ies", &word[..word.len() - 1]));
        } else if ends("s") || ends("x") || ends("z") || ends("ch") || ends("sh") {
            recognized.insert(format!("{word}es"));
        } else {
            recognized.insert(format!("{word}s"));
        }
    }
    recognized
}

/// Swift `Lexicon.lines`: trimmed, non-empty lines that are not `#` comments.
fn read_lines(path: &Path) -> io::Result<Vec<String>> {
    let text = std::fs::read_to_string(path)?;
    Ok(text
        .lines()
        .map(|line| line.trim_matches(|c: char| c == ' ' || c == '\t' || c == '\r'))
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(str::to_owned)
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crlf_word_list_strips_the_carriage_return() {
        let path = std::env::temp_dir().join(format!("seto-crlf-{}", std::process::id()));
        std::fs::write(&path, b"# comment\r\n\r\napple\r\nbanana\r\n").unwrap();
        let list = WordList::open(&path).unwrap();
        std::fs::remove_file(&path).unwrap();
        assert_eq!(list.len(), 2);
        assert_eq!(list.word(0), "apple");
        assert_eq!(list.word(1), "banana");
        assert!(list.contains("apple"));
        assert!(!list.contains("apple\r"));
    }
}
