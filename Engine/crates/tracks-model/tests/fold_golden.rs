//! Golden vectors produced by Foundation's own folding (see the file header in `fold.rs`).

use unicode_normalization::UnicodeNormalization;

fn decode(hex: &str) -> String {
    hex.split(' ')
        .filter(|s| !s.is_empty())
        .map(|h| char::from_u32(u32::from_str_radix(h, 16).expect("hex")).expect("scalar"))
        .collect()
}

#[test]
fn folding_matches_foundation_on_every_golden_vector() {
    let mut failures = Vec::new();
    for line in include_str!("fold_golden.tsv").lines() {
        let (input, expected) = line.split_once('\t').expect("two columns");
        let (input, expected) = (decode(input), decode(expected));
        let got = tracks_model::folded(&input);
        // Swift compares strings by canonical equivalence, so compare in NFC.
        if got != expected.nfc().collect::<String>() {
            failures.push(format!("{input:?}: expected {expected:?}, got {got:?}"));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}
