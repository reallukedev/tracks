//! Who a song credits, read from its artist and title ("A feat. B", "A & B").
//!
//! Ported from the Swift app's `ArtistCredits` and `ArtistCreditNames`, and checked against
//! them on the golden vectors in `tests/credits_golden.rs`. Charts group plays on these
//! identities, so a drift here would split one artist into two rows.
//!
//! Apple Music writes collaborations as "A & B" or "A, B & C" and puts features in the title:
//! "Song (feat. B)". Last.fm and file tags add "A feat. B", "A x B" and "A; B". Bands whose
//! names hold a separator ("Simon & Garfunkel", "Earth, Wind & Fire") stay whole, from a short
//! list and from the rule that "& the …", "and His Orchestra" and "& Sons" belong to the name
//! before them. When Apple Music's own list of the song's artists is known, it settles what
//! the name alone can't.

mod names;
mod text;

use std::collections::HashSet;
use std::ops::Range;

use names::{BAND_WORDS, BANDS, THE_ARTISTS};
use text::{
    Compare, characters, contains, find, first_scalar_before, has_prefix, is_letter_or_number,
    lowercased, next_boundary, trim_whitespace, trim_whitespace_and_newlines,
};

/// One credited artist.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ArtistCredit {
    /// The name as written, trimmed.
    pub name: String,
    /// The folded name, which charts group on.
    pub identity: String,
}

impl ArtistCredit {
    fn new(name: &str) -> Self {
        Self {
            name: name.to_owned(),
            identity: crate::folded(name),
        }
    }
}

/// How a song credits an artist.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CreditRole {
    /// Named in the artist, alone or beside others: "A", "A & B", "A x B".
    Primary,
    /// After "feat.", "ft.", "featuring" or "with", in the artist or the title.
    Featured,
}

/// Whether the artist or title could credit more than one artist. Cheap, and true for some
/// that credit only one ("Featherweight"), which parsing then settles.
pub fn may_credit_several(artist: &str, title: &str) -> bool {
    if might_hold(artist, b"&,+/;([", b"xvfwa", true) {
        let lowered = lowercased(artist);
        if ARTIST_NEEDLES
            .iter()
            .any(|needle| contains_bytes(lowered.as_bytes(), needle.as_bytes()))
        {
            return true;
        }
    }
    might_hold(title, b"([", b"f", false) && feature_hint(&lowercased(title))
}

/// Everyone the song credits from its artist and title alone, main artists first.
pub fn credits_by_name(artist: &str, title: &str) -> Vec<ArtistCredit> {
    strip_roles(credits_by_name_with_roles(artist, title))
}

/// [`credits_by_name`] with each credit's role, as the Swift app's `byName`.
pub fn credits_by_name_with_roles(artist: &str, title: &str) -> Vec<(ArtistCredit, CreditRole)> {
    if may_credit_several(artist, title) {
        credits_with_roles(artist, title, &[])
    } else {
        single(artist)
    }
}

/// Everyone the song credits, using Apple Music's list of its artists when every one of them
/// appears as a whole word in the artist or title, so a different spelling or a wrong match
/// never renames anyone. An empty list means none is known.
pub fn credits_with_catalog(
    artist: &str,
    title: &str,
    catalog_artists: &[String],
) -> Vec<ArtistCredit> {
    strip_roles(credits_with_roles(artist, title, catalog_artists))
}

/// [`credits_with_catalog`] with each credit's role, as the Swift app's `parse`: the main
/// artists first, in order, then the featured ones. Each artist is credited once, as a main
/// artist if they're one.
pub fn credits_with_roles(
    artist: &str,
    title: &str,
    catalog_artists: &[String],
) -> Vec<(ArtistCredit, CreditRole)> {
    let artist = trim_whitespace_and_newlines(artist);
    if artist.is_empty() {
        return Vec::new();
    }
    if catalog_artists.is_empty() && !may_credit_several(artist, title) {
        return single(artist);
    }
    let (mut primary, mut featured) = split(artist);
    featured.extend(title_features(title));

    if let Some(catalog) = usable(catalog_artists, artist, title) {
        let featured_identities: HashSet<String> =
            featured.iter().map(|name| crate::folded(name)).collect();
        let catalog_identities: HashSet<String> =
            catalog.iter().map(|name| crate::folded(name)).collect();
        let (catalog_featured, catalog_primary): (Vec<&str>, Vec<&str>) = catalog
            .iter()
            .partition(|name| featured_identities.contains(&crate::folded(name)));
        // A catalog that lists only featured artists still leaves the credit a main one.
        if !catalog_primary.is_empty() {
            primary = catalog_primary.into_iter().map(str::to_owned).collect();
        }
        let uncatalogued = featured
            .into_iter()
            .filter(|name| !catalog_identities.contains(&crate::folded(name)));
        featured = catalog_featured
            .into_iter()
            .map(str::to_owned)
            .chain(uncatalogued)
            .collect();
    }

    let mut seen = HashSet::new();
    let primary = primary.into_iter().map(|name| (name, CreditRole::Primary));
    let featured = featured
        .into_iter()
        .map(|name| (name, CreditRole::Featured));
    primary
        .chain(featured)
        .map(|(name, role)| (ArtistCredit::new(&name), role))
        .filter(|(credit, _)| !credit.identity.is_empty() && seen.insert(credit.identity.clone()))
        .collect()
}

/// The first main artist: "Beyoncé" for "Beyoncé & JAY-Z feat. Mara Solís".
pub fn lead(artist: &str) -> String {
    credits_with_roles(artist, "", &[])
        .into_iter()
        .next()
        .map_or_else(
            || trim_whitespace_and_newlines(artist).to_owned(),
            |(credit, _)| credit.name,
        )
}

fn strip_roles(credits: Vec<(ArtistCredit, CreditRole)>) -> Vec<ArtistCredit> {
    credits.into_iter().map(|(credit, _)| credit).collect()
}

/// The credit of a name that can't hold more than one artist, without parsing it.
fn single(artist: &str) -> Vec<(ArtistCredit, CreditRole)> {
    let name = trim_whitespace_and_newlines(artist);
    if name.is_empty() {
        Vec::new()
    } else {
        vec![(ArtistCredit::new(name), CreditRole::Primary)]
    }
}

/// A quick look at the bytes, since most names hold no separator: any of `punctuation`, a
/// word starting with one of `word_starts`, or (for "×") any non-ASCII byte.
fn might_hold(text: &str, punctuation: &[u8], word_starts: &[u8], non_ascii: bool) -> bool {
    let mut previous = b' ';
    for &byte in text.as_bytes() {
        if punctuation.contains(&byte) || (non_ascii && byte >= 0x80) {
            return true;
        }
        if previous == b' ' && word_starts.contains(&(byte | 0x20)) {
            return true;
        }
        previous = byte;
    }
    false
}

/// Whether a lowercased title might name a featured artist.
fn feature_hint(title: &str) -> bool {
    TITLE_HINTS
        .iter()
        .any(|needle| contains_bytes(title.as_bytes(), needle.as_bytes()))
}

fn contains_bytes(bytes: &[u8], needle: &[u8]) -> bool {
    bytes.windows(needle.len()).any(|window| window == needle)
}

// Splitting

fn split(artist: &str) -> (Vec<String>, Vec<String>) {
    let (mut rest, mut featured) = bracket_features(artist, true);
    // Searched in the name itself: folding can change its length ("İ"), so an offset into a
    // folded copy can land elsewhere in the original.
    let padded = format!("{rest} ");
    let lowered = lowercased(&padded);
    let mut cut: Option<Range<usize>> = None;
    for &marker in BARE_MARKERS {
        if !contains(&lowered, marker, Compare::Exact) {
            continue;
        }
        let mut search_start = 0;
        while let Some(found) = find(&padded, marker, search_start, Compare::Case) {
            search_start = found.end;
            let after = &padded[found.end..];
            // "Little Feat" is a band: an undotted marker needs a name after it.
            if trim_whitespace(after).is_empty() && !marker.contains('.') {
                continue;
            }
            if marker == " with " && starts_with_band_word(after) {
                continue;
            }
            if cut.as_ref().is_none_or(|cut| found.start < cut.start) {
                cut = Some(found);
            }
            break;
        }
    }
    if let Some(cut) = cut {
        featured.extend(split_list(&padded[cut.end..]));
        padded[..cut.start].clone_into(&mut rest);
    }
    let primary = split_list(&rest);
    if primary.is_empty() {
        (vec![artist.to_owned()], featured)
    } else {
        (primary, featured)
    }
}

/// Featured artists named in the title: "(feat. B)", "[ft. B]", "(with B)", "Song feat. B".
fn title_features(title: &str) -> Vec<String> {
    if !feature_hint(&crate::folded(title)) {
        return Vec::new();
    }
    // "(With Strings)" is part of a title; Spotify-style credits use a lowercase "with".
    let (mut rest, mut featured) = bracket_features(title, false);
    for marker in [" feat. ", " ft. ", " featuring "] {
        let Some(found) = find(&rest, marker, 0, Compare::Case) else {
            continue;
        };
        let mut tail = &rest[found.end..];
        if let Some((end, _)) = characters(tail).find(|&(_, c)| c == "(" || c == "[") {
            tail = &tail[..end];
        }
        if let Some(dash) = find(tail, " - ", 0, Compare::Exact) {
            tail = &tail[..dash.start];
        }
        featured.extend(split_list(tail));
        rest.truncate(found.start);
    }
    featured
}

/// Takes "(feat. B)" and "[with B]" out of `text`, returning what's left and the names.
fn bracket_features(text: &str, with_any_case: bool) -> (String, Vec<String>) {
    if !characters(text).any(|(_, c)| c == "(" || c == "[") {
        return (text.to_owned(), Vec::new());
    }
    let mut rest = String::with_capacity(text.len());
    let mut featured = Vec::new();
    let mut index = 0;
    while index < text.len() {
        let after_open = next_boundary(text, index);
        let character = &text[index..after_open];
        let close = match character {
            "(" => ")",
            "[" => "]",
            _ => {
                rest.push_str(character);
                index = after_open;
                continue;
            }
        };
        let body = after_open
            + characters(&text[after_open..])
                .take_while(|&(_, c)| c == " ")
                .map(|(_, c)| c.len())
                .sum::<usize>();
        let marker = BRACKET_MARKERS.iter().find(|&&marker| {
            let start: String = characters(&text[body..])
                .take(marker.len())
                .map(|(_, c)| c)
                .collect();
            if marker == "with " && !with_any_case {
                start == marker
            } else {
                lowercased(&start) == marker
            }
        });
        let end = characters(&text[after_open..])
            .find(|&(_, c)| c == close)
            .map(|(at, _)| after_open + at);
        let (Some(marker), Some(end)) = (marker, end) else {
            rest.push_str(character);
            index = after_open;
            continue;
        };
        // The marker matched as ASCII, one byte per character.
        let names_start = body + marker.len();
        if names_start < end {
            featured.extend(split_list(&text[names_start..end]));
        }
        index = next_boundary(text, end);
    }
    (trim_whitespace(&rest).to_owned(), featured)
}

/// Splits a list of names at its separators, keeping bands whole.
fn split_list(text: &str) -> Vec<String> {
    let text = trim_whitespace_and_newlines(text);
    if text.is_empty() {
        return Vec::new();
    }
    let folded = crate::folded(text);
    if BANDS.binary_search(&folded.as_str()).is_ok() {
        return vec![text.to_owned()];
    }
    let separated = LIST_SEPARATORS
        .iter()
        .any(|separator| contains(&folded, separator, Compare::Exact));
    if !separated && !contains(text, " x ", Compare::Exact) {
        return vec![text.to_owned()];
    }

    let protected = band_ranges(text, &folded);
    let mut cuts: Vec<Range<usize>> = Vec::new();
    for &separator in LIST_SEPARATORS.iter().chain([" x "].iter()) {
        if !contains(&folded, separator, Compare::Exact) {
            continue;
        }
        // " x " only in lowercase, so "Lil Nas X & Jack Harlow" isn't cut after "Lil Nas".
        let how = if separator == " x " {
            Compare::Exact
        } else {
            Compare::Case
        };
        let mut search_start = 0;
        while let Some(found) = find(text, separator, search_start, how) {
            search_start = found.end;
            if protected.iter().any(|band| overlaps(band, &found)) {
                continue;
            }
            if JOINERS.contains(&separator)
                && starts_with_band_word(&text[found.end..])
                // Earth, Wind & Fire & The Emotions: the band before is already whole.
                && !protected.iter().any(|band| band.end == found.start)
            {
                continue;
            }
            cuts.push(found);
        }
    }
    // Where two overlap, as ", & " and " & " do, the earlier and longer one wins.
    cuts.sort_by(|a, b| a.start.cmp(&b.start).then(b.len().cmp(&a.len())));
    let mut pieces = Vec::with_capacity(cuts.len() + 1);
    let mut start = 0;
    for cut in cuts {
        if cut.start >= start {
            pieces.push(&text[start..cut.start]);
            start = cut.end;
        }
    }
    pieces.push(&text[start..]);
    pieces
        .into_iter()
        .map(|piece| piece.trim_matches([' ', ',', ';']))
        .filter(|piece| !piece.is_empty())
        .map(str::to_owned)
        .collect()
}

fn overlaps(a: &Range<usize>, b: &Range<usize>) -> bool {
    a.start < b.end && b.start < a.end
}

/// Where the known bands sit in `text`, matched whole.
fn band_ranges(text: &str, folded: &str) -> Vec<Range<usize>> {
    let mut ranges = Vec::new();
    for band in BANDS
        .iter()
        .filter(|band| contains(folded, band, Compare::Exact))
    {
        let mut search_start = 0;
        while let Some(found) = find(text, band, search_start, Compare::CaseAndDiacritics) {
            search_start = found.end;
            if stands_alone(text, &found) {
                ranges.push(found);
            }
        }
    }
    ranges
}

/// Whether the match has no letter or digit right before or after it.
fn stands_alone(text: &str, found: &Range<usize>) -> bool {
    let before = first_scalar_before(text, found.start).unwrap_or(' ');
    let after = text[found.end..].chars().next().unwrap_or(' ');
    !is_letter_or_number(before) && !is_letter_or_number(after)
}

/// Whether what follows a joiner belongs to the name before it: "& the Machine", "and His
/// Orchestra", "& Sons". Not when it's an artist of their own, like The Weeknd.
fn starts_with_band_word(text: &str) -> bool {
    let folded = crate::folded(text);
    let Some(&word) = BAND_WORDS.iter().find(|word| has_prefix(&folded, word)) else {
        return false;
    };
    if word != "the " {
        return true;
    }
    !THE_ARTISTS.iter().any(|name| {
        has_prefix(&folded, name)
            && folded[name.len()..]
                .chars()
                .next()
                .is_none_or(|next| !next.is_alphabetic())
    })
}

/// The catalog's names, trimmed, when each of them is named whole in the artist or title.
fn usable<'a>(catalog_artists: &'a [String], artist: &str, title: &str) -> Option<Vec<&'a str>> {
    let names: Vec<&str> = catalog_artists
        .iter()
        .map(|name| trim_whitespace_and_newlines(name))
        .filter(|name| !name.is_empty())
        .collect();
    if names.is_empty() {
        return None;
    }
    let haystack = crate::folded(&format!("{artist} {title}"));
    names
        .iter()
        .all(|name| contains_whole(&crate::folded(name), &haystack))
        .then_some(names)
}

fn contains_whole(needle: &str, haystack: &str) -> bool {
    let mut search_start = 0;
    while let Some(found) = find(haystack, needle, search_start, Compare::Exact) {
        if stands_alone(haystack, &found) {
            return true;
        }
        search_start = next_boundary(haystack, found.start);
    }
    false
}

// Separators

/// Between names in a list. " x " is matched separately, lowercase only.
const LIST_SEPARATORS: &[&str] = &[
    ", and ", ", & ", " and ", " & ", " + ", " × ", " vs. ", " vs ", " / ", "; ", ", ",
];
/// Separators a band's name can carry, which `starts_with_band_word` may overrule.
const JOINERS: &[&str] = &[", and ", ", & ", " and ", " & ", " + "];
const BARE_MARKERS: &[&str] = &[
    " featuring ",
    " feat. ",
    " feat ",
    " ft. ",
    " ft ",
    " with ",
];
const BRACKET_MARKERS: &[&str] = &["featuring ", "feat. ", "feat ", "ft. ", "ft ", "with "];
const TITLE_HINTS: &[&str] = &[
    "feat", " ft.", "(ft", "[ft", "(with ", "[with ", "( with ", "( feat",
];
/// Byte needles for the artist: the separators, " x " and the feature markers.
const ARTIST_NEEDLES: &[&str] = &[
    ", and ", ", & ", " and ", " & ", " + ", " × ", " vs. ", " vs ", " / ", "; ", ", ", " x ",
    "feat", " ft", "(ft", "[ft", " with ", "(with", "[with",
];

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    /// Names in credit order, featured ones prefixed "+".
    fn credits(artist: &str, title: &str, catalog: &[&str]) -> Vec<String> {
        let catalog: Vec<String> = catalog.iter().map(|&name| name.to_owned()).collect();
        credits_with_roles(artist, title, &catalog)
            .into_iter()
            .map(|(credit, role)| match role {
                CreditRole::Primary => credit.name,
                CreditRole::Featured => format!("+{}", credit.name),
            })
            .collect()
    }

    fn by_artist(artist: &str) -> Vec<String> {
        credits(artist, "", &[])
    }

    #[test]
    fn one_artist_is_one_trimmed_credit_and_a_blank_one_is_none() {
        assert_eq!(by_artist("  Adele "), ["Adele"]);
        assert_eq!(by_artist(""), Vec::<String>::new());
        assert_eq!(by_artist("\n\t "), Vec::<String>::new());
    }

    #[test]
    fn separators_inside_a_word_or_without_spaces_do_not_split() {
        for artist in [
            "AC/DC",
            "Lil Nas X",
            "Rag'n'Bone Man",
            "Saxon",
            "Andromeda",
            "Featherweight",
            "BTS (방탄소년단)",
        ] {
            assert_eq!(by_artist(artist), [artist], "{artist}");
        }
    }

    #[test]
    fn an_undotted_marker_at_the_end_is_part_of_the_name() {
        assert_eq!(by_artist("Little Feat"), ["Little Feat"]);
    }

    #[test]
    fn a_dotted_marker_with_no_one_after_it_credits_no_one() {
        assert_eq!(by_artist("Drake feat."), ["Drake"]);
    }

    #[test]
    fn every_list_separator_splits_two_main_artists() {
        for separator in [
            ", ", " & ", " and ", " AND ", " + ", " x ", " × ", " vs. ", " vs ", " / ", "; ",
            ", & ", ", and ",
        ] {
            assert_eq!(
                by_artist(&format!("Umbra{separator}Mara Solis")),
                ["Umbra", "Mara Solis"],
                "{separator:?}"
            );
        }
    }

    #[test]
    fn an_uppercase_x_is_not_a_separator() {
        assert_eq!(by_artist("Umbra X Mara Solis"), ["Umbra X Mara Solis"]);
        assert_eq!(
            by_artist("Lil Nas X & Jack Harlow"),
            ["Lil Nas X", "Jack Harlow"]
        );
    }

    #[test]
    fn a_long_list_splits_in_written_order() {
        assert_eq!(
            by_artist("Mark Ronson, Bruno Mars, Lil Nas X & Cardi B"),
            ["Mark Ronson", "Bruno Mars", "Lil Nas X", "Cardi B"]
        );
        assert_eq!(
            by_artist("Umbra, Mara Solis, & Yuki Tanabe"),
            ["Umbra", "Mara Solis", "Yuki Tanabe"]
        );
    }

    #[test]
    fn the_same_artist_twice_is_credited_once_as_written_first() {
        assert_eq!(by_artist("Umbra & umbra"), ["Umbra"]);
        assert_eq!(by_artist("Beyoncé & BEYONCE"), ["Beyoncé"]);
        assert_eq!(by_artist("Umbra feat. Umbra"), ["Umbra"]);
    }

    #[test]
    fn every_feature_marker_in_the_artist_credits_a_featured_artist() {
        for artist in [
            "Drake feat. Rihanna",
            "Drake FEAT. Rihanna",
            "Drake feat Rihanna",
            "Drake ft. Rihanna",
            "Drake ft Rihanna",
            "Drake featuring Rihanna",
            "Drake with Rihanna",
            "Drake With Rihanna",
            "Drake (feat. Rihanna)",
            "Drake [feat. Rihanna]",
            "Drake (with Rihanna)",
        ] {
            assert_eq!(by_artist(artist), ["Drake", "+Rihanna"], "{artist}");
        }
    }

    #[test]
    fn featured_artists_come_after_every_main_one_and_split_too() {
        assert_eq!(
            by_artist("Umbra & Mara Solis feat. Yuki Tanabe, Nova Harbor"),
            ["Umbra", "Mara Solis", "+Yuki Tanabe", "+Nova Harbor"]
        );
    }

    #[test]
    fn features_in_the_title_are_credited_however_apple_music_writes_them() {
        for title in [
            "Golden Moon (feat. Mara Solis)",
            "Golden Moon [ft. Mara Solis]",
            "Golden Moon (with Mara Solis)",
            "Golden Moon feat. Mara Solis - Radio Edit",
            "Golden Moon ft. Mara Solis (Remix)",
            "Golden Moon featuring Mara Solis [Live]",
        ] {
            assert_eq!(
                credits("Umbra", title, &[]),
                ["Umbra", "+Mara Solis"],
                "{title}"
            );
        }
    }

    #[test]
    fn title_words_in_brackets_are_not_features() {
        for title in [
            "Stand By Me (With Strings)",
            "Feather (Remix)",
            "Feat of Clay",
            "Golden Moon ()",
            "Señorita",
        ] {
            assert_eq!(credits("Umbra", title, &[]), ["Umbra"], "{title}");
        }
    }

    #[test]
    fn a_main_artist_featured_again_in_the_title_stays_a_main_artist() {
        assert_eq!(
            credits("Umbra & Mara Solis", "Golden Moon (feat. mara solis)", &[]),
            ["Umbra", "Mara Solis"]
        );
        assert_eq!(
            credits("Drake feat. Rihanna", "Work (feat. Drake)", &[]),
            ["Drake", "+Rihanna"]
        );
    }

    #[test]
    fn bands_with_a_separator_in_their_name_stay_whole() {
        for artist in [
            "Simon & Garfunkel",
            "EARTH, WIND & FIRE",
            "Tyler, The Creator",
            "Florence + the Machine",
            "Mumford & Sons",
            "Crosby, Stills, Nash & Young",
            "Kool & the Gang",
            "Duke Ellington and His Orchestra",
            "Willie Nelson & Friends",
            "Chloe x Halle",
            "Dan + Shay",
            "Peter Bjorn and John",
        ] {
            assert_eq!(by_artist(artist), [artist], "{artist}");
        }
    }

    #[test]
    fn a_known_band_inside_a_longer_credit_is_one_of_its_credits() {
        assert_eq!(
            by_artist("Earth, Wind & Fire & The Emotions"),
            ["Earth, Wind & Fire", "The Emotions"]
        );
        assert_eq!(
            by_artist("Mara Solis x Chloe x Halle"),
            ["Mara Solis", "Chloe x Halle"]
        );
        assert_eq!(
            by_artist("Umbra feat. Tyler, The Creator"),
            ["Umbra", "+Tyler, The Creator"]
        );
    }

    #[test]
    fn an_artist_whose_name_starts_with_the_is_not_taken_for_a_band() {
        assert_eq!(
            by_artist("Ariana Grande & The Weeknd"),
            ["Ariana Grande", "The Weeknd"]
        );
        assert_eq!(by_artist("Umbra & The Lanterns"), ["Umbra & The Lanterns"]);
    }

    #[test]
    fn a_catalog_that_names_everyone_in_the_credit_settles_it() {
        assert_eq!(
            credits("Fern & Fable", "", &["Fern & Fable"]),
            ["Fern & Fable"]
        );
        assert_eq!(
            credits("Umbra & The Lanterns", "", &["Umbra", "The Lanterns"]),
            ["Umbra", "The Lanterns"]
        );
        assert_eq!(
            credits("Umbra & Mara Solis", "", &["Mara Solis", "Umbra"]),
            ["Mara Solis", "Umbra"]
        );
    }

    #[test]
    fn a_catalog_keeps_featured_roles_and_unlisted_features() {
        assert_eq!(
            credits("Drake feat. Rihanna", "", &["Rihanna", "Drake"]),
            ["Drake", "+Rihanna"]
        );
        assert_eq!(
            credits(
                "Lil Nas X",
                "Old Town Road (feat. Billy Ray Cyrus)",
                &["Lil Nas X"]
            ),
            ["Lil Nas X", "+Billy Ray Cyrus"]
        );
    }

    #[test]
    fn a_catalog_naming_someone_not_in_the_credit_is_ignored() {
        assert_eq!(
            credits("Fern & Fable", "", &["Someone Else"]),
            ["Fern", "Fable"]
        );
        assert_eq!(
            credits("Fern & Fable", "", &["Fern & Fable", "Someone Else"]),
            ["Fern", "Fable"]
        );
        assert_eq!(
            credits("Fernando & Fable", "", &["Fern"]),
            ["Fernando", "Fable"]
        );
    }

    #[test]
    fn a_catalog_of_blank_names_still_lets_the_name_be_parsed() {
        assert_eq!(credits("Fern & Fable", "", &["  "]), ["Fern", "Fable"]);
    }

    #[test]
    fn identities_fold_case_and_accents_while_names_keep_their_spelling() {
        let parsed = credits_with_catalog("Beyoncé & JAY-Z feat. Mara Solís", "", &[]);
        let identities: Vec<&str> = parsed
            .iter()
            .map(|credit| credit.identity.as_str())
            .collect();
        assert_eq!(identities, ["beyonce", "jay-z", "mara solis"]);
        assert_eq!(parsed[0].name, "Beyoncé");
    }

    #[test]
    fn the_lead_is_the_first_main_artist_or_the_trimmed_name() {
        assert_eq!(lead("Beyoncé & JAY-Z feat. Mara Solís"), "Beyoncé");
        assert_eq!(lead("Simon & Garfunkel"), "Simon & Garfunkel");
        assert_eq!(lead("   "), "");
    }

    #[test]
    fn a_name_that_grows_when_folded_is_still_cut_at_its_own_separators() {
        assert_eq!(
            by_artist("İSMAİL YK feat. Nova Harbor"),
            ["İSMAİL YK", "+Nova Harbor"]
        );
        assert_eq!(by_artist("İİİİİİİİİİİİ & Ⱥ Ⱥ"), ["İİİİİİİİİİİİ", "Ⱥ Ⱥ"]);
    }

    #[test]
    fn a_separator_whose_space_carries_an_accent_is_not_a_separator() {
        assert_eq!(by_artist("Alpha & \u{301}Beta"), ["Alpha & \u{301}Beta"]);
    }

    #[test]
    fn credits_by_name_skips_parsing_a_name_that_cannot_hold_two() {
        assert!(!may_credit_several("Taylor Swift", "Love Story"));
        assert_eq!(
            credits_by_name("  Taylor Swift ", "Love Story")[0].name,
            "Taylor Swift"
        );
    }

    proptest! {
        // The cheap check gates parsing, so it must never be false for a name or title that
        // parses into more than one credit.
        #[test]
        fn the_quick_check_never_hides_a_second_credit(
            artist in r"(Alpha|Beta|Bé|İ|&| & | and |, | x | × | / |; | feat\. | ft | with |\(|\)|\[|the |Sons| |\u{301}|\u{A0})*",
            title in r"(Song|\(feat\. |\(with | ft\. | featuring |Beta|\)| |\[)*",
        ) {
            let trimmed = trim_whitespace_and_newlines(&artist);
            let (primary, featured) = split(trimmed);
            let named = primary.len() + featured.len() + title_features(&title).len();
            prop_assume!(!trimmed.is_empty() && named > 1);
            prop_assert!(may_credit_several(&artist, &title));
        }
    }
}
