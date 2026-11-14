//! Golden vectors produced by the Swift app's own `ArtistCredits`, run under Foundation.
//!
//! Columns: artist, title, catalog (`-` for none, `[]` for an empty list, else names joined by
//! `|`), `mayCreditSeveral`, `byName`, `parse`, `lead`. Credits are `P` or `F` (primary or
//! featured), the name, `~`, the identity, joined by `|`. Any scalar outside printable ASCII,
//! and `\`, `|` and `~`, is written `\u{HEX}`.

use tracks_model::credits::{CreditRole, credits_by_name_with_roles, credits_with_roles, lead};
use tracks_model::{ArtistCredit, credits_by_name, may_credit_several};
use unicode_normalization::UnicodeNormalization;

fn unescape(text: &str) -> String {
    let mut out = String::new();
    let mut rest = text;
    while let Some(at) = rest.find("\\u{") {
        out.push_str(&rest[..at]);
        let end = rest[at..].find('}').expect("closing brace") + at;
        let scalar = u32::from_str_radix(&rest[at + 3..end], 16).expect("hex");
        out.push(char::from_u32(scalar).expect("scalar"));
        rest = &rest[end + 1..];
    }
    out.push_str(rest);
    out
}

fn decode_credits(column: &str) -> Vec<(String, String, CreditRole)> {
    if column.is_empty() {
        return Vec::new();
    }
    column
        .split('|')
        .map(|credit| {
            let role = if credit.starts_with('P') {
                CreditRole::Primary
            } else {
                CreditRole::Featured
            };
            let (name, identity) = credit[1..].split_once('~').expect("name~identity");
            (nfc(&unescape(name)), nfc(&unescape(identity)), role)
        })
        .collect()
}

// Swift compares strings by canonical equivalence (and `byName` memoises on it), so compare
// in NFC.
fn nfc(text: &str) -> String {
    text.nfc().collect()
}

fn described(credits: &[(ArtistCredit, CreditRole)]) -> Vec<(String, String, CreditRole)> {
    credits
        .iter()
        .map(|(credit, role)| (nfc(&credit.name), nfc(&credit.identity), *role))
        .collect()
}

#[test]
fn credits_match_the_swift_app_on_every_golden_vector() {
    let mut failures = Vec::new();
    let mut vectors = 0;
    for line in include_str!("credits_golden.tsv")
        .lines()
        .filter(|line| !line.starts_with('#'))
    {
        let columns: Vec<&str> = line.split('\t').collect();
        let [artist, title, catalog, may, by_name, parsed, expected_lead] = columns[..] else {
            panic!("seven columns in {line:?}");
        };
        vectors += 1;
        let (artist, title) = (unescape(artist), unescape(title));
        let catalog: Vec<String> = match catalog {
            "-" | "[]" => Vec::new(),
            names => names.split('|').map(unescape).collect(),
        };
        let case = format!("{artist:?} / {title:?} / {catalog:?}");

        let got_may = may_credit_several(&artist, &title);
        if got_may != (may == "1") {
            failures.push(format!(
                "{case}: may_credit_several expected {may}, got {got_may}"
            ));
        }
        let got = described(&credits_by_name_with_roles(&artist, &title));
        if got != decode_credits(by_name) {
            failures.push(format!(
                "{case}: by name expected {:?}, got {got:?}",
                decode_credits(by_name)
            ));
        }
        let plain: Vec<ArtistCredit> = credits_by_name(&artist, &title);
        if plain
            .iter()
            .map(|c| &c.identity)
            .ne(got.iter().map(|(_, identity, _)| identity))
        {
            failures.push(format!(
                "{case}: credits_by_name disagrees with its roled form"
            ));
        }
        let got = described(&credits_with_roles(&artist, &title, &catalog));
        if got != decode_credits(parsed) {
            failures.push(format!(
                "{case}: parse expected {:?}, got {got:?}",
                decode_credits(parsed)
            ));
        }
        let got_lead = lead(&artist);
        if nfc(&got_lead) != nfc(&unescape(expected_lead)) {
            failures.push(format!(
                "{case}: lead expected {:?}, got {got_lead:?}",
                unescape(expected_lead)
            ));
        }
    }
    assert!(vectors > 500, "only {vectors} vectors");
    assert!(
        failures.is_empty(),
        "{} of {vectors} vectors failed:\n{}",
        failures.len(),
        failures.join("\n")
    );
}
