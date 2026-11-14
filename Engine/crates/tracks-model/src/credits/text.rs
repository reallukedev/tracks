//! The pieces of Foundation's string handling that `ArtistCredits` leans on: searches that
//! only match whole characters (grapheme clusters), case and diacritic insensitivity,
//! and its two whitespace sets.

use std::ops::Range;

use unicode_normalization::UnicodeNormalization;
use unicode_normalization::char::is_combining_mark;

/// How a search compares characters, after the `String.CompareOptions` it mirrors.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Compare {
    /// No options: canonical equivalence only.
    Exact,
    /// `.caseInsensitive`.
    Case,
    /// `[.caseInsensitive, .diacriticInsensitive]`.
    CaseAndDiacritics,
}

/// `CharacterSet.whitespacesAndNewlines`. Foundation keeps U+180E and U+FEFF out of it but
/// takes U+200B, which the golden vectors pin down.
pub(super) fn is_whitespace_or_newline(c: char) -> bool {
    c.is_whitespace() || c == '\u{200B}'
}

/// `CharacterSet.whitespaces`: the same without line and paragraph breaks.
pub(super) fn is_whitespace(c: char) -> bool {
    is_whitespace_or_newline(c)
        && !matches!(
            c,
            '\n' | '\u{B}' | '\u{C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}'
        )
}

pub(super) fn trim_whitespace_and_newlines(s: &str) -> &str {
    s.trim_matches(is_whitespace_or_newline)
}

pub(super) fn trim_whitespace(s: &str) -> &str {
    s.trim_matches(is_whitespace)
}

/// Swift's `Character.isLetter || Character.isNumber`, which look at the first scalar.
pub(super) fn is_letter_or_number(c: char) -> bool {
    c.is_alphabetic() || c.is_numeric()
}

/// Swift's `lowercased()`: scalar by scalar, with no final-sigma context.
pub(super) fn lowercased(s: &str) -> String {
    if s.is_ascii() {
        return s.to_ascii_lowercase();
    }
    s.chars().flat_map(char::to_lowercase).collect()
}

fn is_extend(c: char) -> bool {
    is_combining_mark(c)
        || matches!(c,
            '\u{200C}' | '\u{200D}' | '\u{FF9E}' | '\u{FF9F}'
            | '\u{1F3FB}'..='\u{1F3FF}'
            | '\u{E0020}'..='\u{E007F}')
}

fn is_prepend(c: char) -> bool {
    matches!(c,
        '\u{0600}'..='\u{0605}' | '\u{06DD}' | '\u{070F}' | '\u{0890}'..='\u{0891}' | '\u{08E2}'
        | '\u{0D4E}' | '\u{110BD}' | '\u{110CD}' | '\u{111C2}'..='\u{111C3}' | '\u{1193F}'
        | '\u{11941}' | '\u{11A3A}' | '\u{11A84}'..='\u{11A89}' | '\u{11D46}' | '\u{11F02}')
}

fn is_control(c: char) -> bool {
    !is_prepend(c)
        && (c.is_control()
            || matches!(c,
                '\u{00AD}' | '\u{061C}' | '\u{180E}' | '\u{200B}' | '\u{200E}' | '\u{200F}'
                | '\u{2028}'..='\u{202E}' | '\u{2060}'..='\u{206F}' | '\u{FEFF}'
                | '\u{FFF0}'..='\u{FFFB}' | '\u{E0000}'..='\u{E001F}'))
}

fn is_pictographic(c: char) -> bool {
    matches!(c,
        '\u{00A9}' | '\u{00AE}' | '\u{203C}' | '\u{2049}' | '\u{2122}' | '\u{2139}'
        | '\u{2194}'..='\u{21AA}' | '\u{231A}'..='\u{23FF}' | '\u{24C2}' | '\u{25AA}'..='\u{27BF}'
        | '\u{2934}'..='\u{2935}' | '\u{2B05}'..='\u{2B55}' | '\u{3030}' | '\u{303D}'
        | '\u{3297}' | '\u{3299}' | '\u{1F000}'..='\u{1FAFF}' | '\u{1FC00}'..='\u{1FFFD}')
}

/// Whether a Swift `Character` boundary falls at byte `i`. Follows the extended grapheme
/// cluster rules closely enough for searches whose ends are ASCII: control characters, CR LF,
/// combining marks and joiners, prepended marks and emoji ZWJ sequences.
pub(super) fn is_boundary(s: &str, i: usize) -> bool {
    if i == 0 || i >= s.len() {
        return true;
    }
    let (Some(prev), Some(next)) = (s[..i].chars().next_back(), s[i..].chars().next()) else {
        return true;
    };
    if prev.is_ascii() && next.is_ascii() {
        return !(prev == '\r' && next == '\n');
    }
    if is_control(prev) || is_control(next) {
        return true;
    }
    if is_extend(next) || is_prepend(prev) {
        return false;
    }
    !(prev == '\u{200D}' && is_pictographic(next))
}

/// The end of the character that starts at `i`.
pub(super) fn next_boundary(s: &str, i: usize) -> usize {
    let mut j = i;
    while let Some(c) = s[j..].chars().next() {
        j += c.len_utf8();
        if is_boundary(s, j) {
            break;
        }
    }
    j
}

/// The first scalar of the character that ends at `i`, as Swift's `s[s.index(before: i)]`.
pub(super) fn first_scalar_before(s: &str, i: usize) -> Option<char> {
    let mut j = i;
    loop {
        let c = s[..j].chars().next_back()?;
        j -= c.len_utf8();
        if is_boundary(s, j) {
            return s[j..].chars().next();
        }
    }
}

/// The characters of `s` with their byte offsets.
pub(super) fn characters(s: &str) -> impl Iterator<Item = (usize, &str)> {
    let mut i = 0;
    std::iter::from_fn(move || {
        if i >= s.len() {
            return None;
        }
        let start = i;
        i = next_boundary(s, i);
        Some((start, &s[start..i]))
    })
}

/// Swift's `hasPrefix`, which compares whole characters.
pub(super) fn has_prefix(s: &str, prefix: &str) -> bool {
    s.starts_with(prefix) && is_boundary(s, prefix.len())
}

/// The first match of `needle` in `hay` at or after byte `from`, starting and ending on
/// character boundaries, as `range(of:options:range:)`. `needle` must already be in the form
/// `how` compares in: NFC, and case folded for the insensitive searches.
pub(super) fn find(hay: &str, needle: &str, from: usize, how: Compare) -> Option<Range<usize>> {
    if needle.is_empty() || from > hay.len() {
        return None;
    }
    if hay.is_ascii() {
        if !needle.is_ascii() {
            return None;
        }
        return find_ascii(hay, needle, from, how);
    }
    let mut key = String::new();
    let mut start = from;
    while start < hay.len() {
        let mut consumed = 0;
        let mut end = start;
        while consumed < needle.len() && end < hay.len() {
            let next = next_boundary(hay, end);
            key.clear();
            push_key(&hay[end..next], how, &mut key);
            if !needle[consumed..].starts_with(key.as_str()) {
                break;
            }
            consumed += key.len();
            end = next;
        }
        if consumed == needle.len() {
            return Some(start..end);
        }
        start = next_boundary(hay, start);
    }
    None
}

fn find_ascii(hay: &str, needle: &str, from: usize, how: Compare) -> Option<Range<usize>> {
    let (hay_bytes, needle_bytes) = (hay.as_bytes(), needle.as_bytes());
    let last = hay_bytes.len().checked_sub(needle_bytes.len())?;
    (from..=last)
        .filter(|&start| {
            let window = &hay_bytes[start..start + needle_bytes.len()];
            if how == Compare::Exact {
                window == needle_bytes
            } else {
                window.eq_ignore_ascii_case(needle_bytes)
            }
        })
        .find(|&start| is_boundary(hay, start) && is_boundary(hay, start + needle_bytes.len()))
        .map(|start| start..start + needle_bytes.len())
}

/// What one character compares as.
fn push_key(character: &str, how: Compare, out: &mut String) {
    match how {
        Compare::Exact => out.extend(character.nfc()),
        Compare::Case => {
            let folded: String = character.nfd().map(fold_case).collect();
            out.extend(folded.nfc());
        }
        Compare::CaseAndDiacritics => {
            let stripped = character.nfd().filter(|&c| !is_stripped_diacritic(c));
            let folded: String = stripped.map(fold_case).collect();
            out.extend(folded.nfd().filter(|&c| !is_stripped_diacritic(c)).nfc());
        }
    }
}

fn fold_case(c: char) -> String {
    let mut buf = [0u8; 4];
    caseless::default_case_fold_str(c.encode_utf8(&mut buf))
}

/// The marks Foundation's diacritic folding drops, as in `fold.rs`.
fn is_stripped_diacritic(c: char) -> bool {
    matches!(c,
        '\u{0300}'..='\u{036F}'
        | '\u{1AB0}'..='\u{1AFF}'
        | '\u{1DC0}'..='\u{1DFF}'
        | '\u{20D0}'..='\u{20FF}'
        | '\u{FE20}'..='\u{FE2F}')
}

/// Whether `needle` occurs in `hay` on character boundaries.
pub(super) fn contains(hay: &str, needle: &str, how: Compare) -> bool {
    find(hay, needle, 0, how).is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_match_cannot_end_inside_a_character() {
        assert_eq!(find("a & \u{301}b", " & ", 0, Compare::Exact), None);
    }

    #[test]
    fn diacritic_insensitive_search_takes_the_whole_accented_character() {
        assert_eq!(
            find(
                "Simo\u{301}n & Garfunkel",
                "simon",
                0,
                Compare::CaseAndDiacritics
            ),
            Some(0..7)
        );
    }

    #[test]
    fn case_insensitive_search_reads_the_kelvin_sign_as_k() {
        assert_eq!(find("Ma\u{212A}e it", "mak", 0, Compare::Case), Some(0..5));
    }

    #[test]
    fn cr_lf_is_one_character() {
        assert!(!is_boundary("a\r\nb", 2));
    }
}
