//! The names `ArtistCredits` can't work out by rule, from the Swift app's `ArtistCreditNames`. All folded.

/// Bands and duos whose names hold a separator. Sorted, for binary search.
pub(super) const BANDS: &[&str] = &[
    "above & beyond",
    "aly & aj",
    "angus & julia stone",
    "ashford & simpson",
    "belle & sebastian",
    "belle and sebastian",
    "big & rich",
    "blood, sweat & tears",
    "brooks & dunn",
    "brooks and dunn",
    "captain & tennille",
    "chad & jeremy",
    "chase & status",
    "chloe x halle",
    "coheed and cambria",
    "crosby, stills & nash",
    "crosby, stills, nash & young",
    "dan + shay",
    "daryl hall & john oates",
    "earth wind & fire",
    "earth, wind & fire",
    "emerson, lake & palmer",
    "eric b. & rakim",
    "hall & oates",
    "ike & tina turner",
    "iron & wine",
    "jan & dean",
    "joey + rory",
    "lily & madeleine",
    "loggins & messina",
    "love & theft",
    "love and rockets",
    "love and theft",
    "macklemore & ryan lewis",
    "maddie & tae",
    "matt & kim",
    "matt and kim",
    "mel & kim",
    "now, now",
    "of monsters and men",
    "peaches & herb",
    "pete rock & cl smooth",
    "peter bjorn and john",
    "peter, bjorn and john",
    "peter, paul & mary",
    "peter, paul and mary",
    "sam & dave",
    "seals & crofts",
    "she & him",
    "shovels & rope",
    "simon & garfunkel",
    "simon and garfunkel",
    "sly & robbie",
    "sonny & cher",
    "tegan & sara",
    "tegan and sara",
    "tyler, the creator",
    "years & years",
    "zager & evans",
];

/// Words that, after "&", "and" or "+", carry on the name before: "Florence + the Machine".
pub(super) const BAND_WORDS: &[&str] = &[
    "the ",
    "his ",
    "her ",
    "their ",
    "friends",
    "sons",
    "daughters",
    "co.",
    "company",
];

/// Artists whose own name starts with "The", so "Ariana Grande & The Weeknd" is two.
pub(super) const THE_ARTISTS: &[&str] = &[
    "the 1975",
    "the beatles",
    "the black keys",
    "the chainsmokers",
    "the cure",
    "the dream",
    "the emotions",
    "the game",
    "the kid laroi",
    "the killers",
    "the lumineers",
    "the national",
    "the neighbourhood",
    "the notorious b.i.g.",
    "the rolling stones",
    "the roots",
    "the script",
    "the smiths",
    "the strokes",
    "the weeknd",
    "the white stripes",
    "the xx",
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bands_are_sorted_for_binary_search() {
        assert!(BANDS.is_sorted());
    }
}
