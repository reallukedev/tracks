//! Name folding, the base of every identity the engine groups on.
//!
//! These match Foundation's
//! `trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive,
//! .diacriticInsensitive], locale: nil)` byte for byte on the golden vectors in
//! `tests/fold_golden.rs`, which were produced by Foundation itself. Charts group on these
//! strings, so a drift here would split one song into two rows.

use unicode_normalization::UnicodeNormalization;

/// The separator between the parts of a compound key ("title␟artist").
pub const KEY_SEPARATOR: char = '\u{1F}';

/// Whether Foundation's diacritic folding drops this mark.
///
/// Foundation only strips the general-purpose combining diacritics. Marks that are part of a
/// script's spelling (kana voicing, Arabic harakat, Hebrew points, Indic signs) survive.
fn is_stripped_diacritic(c: char) -> bool {
    matches!(c,
        '\u{0300}'..='\u{036F}'
        | '\u{0483}'..='\u{0489}'
        | '\u{1AB0}'..='\u{1AFF}'
        | '\u{1DC0}'..='\u{1DFF}'
        | '\u{20D0}'..='\u{20FF}'
        | '\u{FE20}'..='\u{FE2F}')
}

/// Foundation folds Cherokee to its lowercase letters, where Unicode case folding maps the
/// other way, to the uppercase ones.
fn foundation_case_fold(c: char, out: &mut String) {
    match c {
        '\u{13A0}'..='\u{13EF}' => {
            // U+13A0..U+13EF lowercase to U+AB70..U+ABBF.
            out.push(char::from_u32(c as u32 - 0x13A0 + 0xAB70).unwrap_or(c));
        }
        '\u{13F0}'..='\u{13F5}' => out.push(char::from_u32(c as u32 + 8).unwrap_or(c)),
        '\u{AB70}'..='\u{ABBF}' | '\u{13F8}'..='\u{13FD}' => out.push(c),
        _ => {
            let mut buf = [0u8; 4];
            out.push_str(&caseless::default_case_fold_str(c.encode_utf8(&mut buf)));
        }
    }
}

/// Whether Foundation's `.whitespacesAndNewlines` contains this character: Unicode's
/// whitespace plus the zero-width space (but not U+180E or U+FEFF, which it keeps).
fn is_foundation_whitespace(c: char) -> bool {
    c.is_whitespace() || c == '\u{200B}'
}

/// Trims, case-folds and strips diacritics, the way every identity in Tracks is built.
///
/// The result is in NFC, so strings Swift treats as equal (canonically equivalent) fold to
/// the same bytes here.
///
/// ```
/// assert_eq!(tracks_model::folded("  Beyoncé "), "beyonce");
/// assert_eq!(tracks_model::folded("Straße"), "strasse");
/// ```
pub fn folded(name: &str) -> String {
    let trimmed = name.trim_matches(is_foundation_whitespace);
    if trimmed.is_ascii() {
        // Most names are plain ASCII: skip normalization entirely.
        return trimmed.to_ascii_lowercase();
    }
    let mut cased = String::with_capacity(trimmed.len());
    for c in strip_diacritics(trimmed.nfd()) {
        foundation_case_fold(c, &mut cased);
    }
    // Case folding can introduce new combining marks (İ folds to i + U+0307), so strip again.
    strip_diacritics(cased.nfd()).nfc().collect()
}

/// Drops diacritics that sit on a letter. A mark with nothing before it has no letter to
/// come off, and Foundation keeps it.
fn strip_diacritics(chars: impl Iterator<Item = char>) -> impl Iterator<Item = char> {
    let mut has_base = false;
    chars.filter(move |&c| {
        if is_stripped_diacritic(c) {
            !has_base
        } else {
            has_base = true;
            true
        }
    })
}

/// The identity of a song: folded title and folded artist, as `HistoryImport.key` builds it.
///
/// ```
/// assert_eq!(tracks_model::song_key("Halo", "Beyoncé"), "halo\u{1F}beyonce");
/// ```
pub fn song_key(title: &str, artist: &str) -> String {
    let mut key = folded(title);
    key.push(KEY_SEPARATOR);
    key.push_str(&folded(artist));
    key
}

/// The identity of an album: folded title and its lead artist's identity, or `None` for a
/// blank title. Plenty of artists have an album called "Home".
pub fn album_key(album_title: &str, lead_artist_identity: &str) -> Option<String> {
    let album = folded(album_title);
    if album.is_empty() {
        return None;
    }
    let mut key = album;
    key.push(KEY_SEPARATOR);
    key.push_str(lead_artist_identity);
    Some(key)
}

/// Text as search compares it: folded, apostrophes dropped ("dont" finds "Don't"), other
/// punctuation read as a space ("ac dc" finds "AC/DC"), and "&" read as "and".
pub fn search_folded(text: &str) -> String {
    let base = folded(text);
    let mut out = String::with_capacity(base.len());
    let mut pending_space = false;
    for c in base.chars() {
        match c {
            '\'' | '\u{2019}' | '\u{2018}' | '`' | '\u{00B4}' => {}
            '&' => {
                if !out.is_empty() {
                    out.push(' ');
                }
                out.push_str("and");
                pending_space = true;
            }
            c if c.is_alphanumeric() || is_combining(c) => {
                if pending_space && !out.is_empty() {
                    out.push(' ');
                }
                pending_space = false;
                out.push(c);
            }
            _ => pending_space = true,
        }
    }
    out
}

/// Swift iterates grapheme clusters, so a mark that survived folding stays with its letter.
fn is_combining(c: char) -> bool {
    unicode_normalization::char::is_combining_mark(c)
}

/// Whether a typed word is one letter off a word of a name, or off the start of one: a letter
/// wrong, missing, extra, or swapped with the next. Only for words of four letters or more,
/// since a shorter word a letter off matches nearly anything.
pub fn is_near(typed: &str, word: &str) -> bool {
    let typed: Vec<char> = typed.chars().collect();
    if typed.len() < 4 {
        return false;
    }
    let word: Vec<char> = word.chars().collect();
    [typed.len() - 1, typed.len(), typed.len() + 1]
        .into_iter()
        .filter(|&len| len > 0 && len <= word.len())
        .any(|len| within_one(&typed, &word[..len]))
}

fn within_one(a: &[char], b: &[char]) -> bool {
    match a.len().abs_diff(b.len()) {
        0 => {
            let diffs: Vec<usize> = (0..a.len()).filter(|&i| a[i] != b[i]).collect();
            match diffs.as_slice() {
                [] | [_] => true,
                [i, j] => *j == i + 1 && a[*i] == b[*j] && a[*j] == b[*i],
                _ => false,
            }
        }
        1 => {
            let (long, short) = if a.len() > b.len() { (a, b) } else { (b, a) };
            let first = (0..short.len())
                .find(|&i| long[i] != short[i])
                .unwrap_or(short.len());
            long[first + 1..] == short[first..]
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ascii_fast_path_matches_the_unicode_path() {
        for s in ["Hello World", "  AC/DC\t", "", "Don't Stop"] {
            let slow: String = s
                .trim()
                .nfd()
                .flat_map(|c| {
                    caseless::default_case_fold_str(&c.to_string())
                        .chars()
                        .collect::<Vec<_>>()
                })
                .collect();
            assert_eq!(folded(s), slow);
        }
    }

    #[test]
    fn search_folding_reads_ampersands_and_punctuation() {
        assert_eq!(search_folded("AC/DC"), "ac dc");
        assert_eq!(search_folded("Don't Stop"), "dont stop");
        assert_eq!(search_folded("Simon & Garfunkel"), "simon and garfunkel");
        assert_eq!(search_folded("&"), "and");
    }

    #[test]
    fn near_words_allow_one_slip() {
        assert!(is_near("beyonse", "beyonce"));
        assert!(is_near("beyocne", "beyonce"));
        assert!(is_near("beyonc", "beyonce"));
        assert!(is_near("radi", "radiohead"));
        assert!(!is_near("abc", "abd"));
        assert!(!is_near("beyxxce", "beyonce"));
    }
}
