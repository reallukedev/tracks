//! The signature and the form body. Last.fm answers any mistake in either with "Invalid
//! method signature supplied" and doesn't say which part was wrong. The goldens were
//! produced by the Swift client's own code running on Foundation.

mod common;

use proptest::prelude::*;
use tracks_lastfm::{form_body, form_escape, md5_hex, sign};

#[test]
fn md5_is_lowercase_hex() {
    assert_eq!(md5_hex("abc"), "900150983cd24fb0d6963f7d28e17f72");
}

#[test]
fn signature_matches_last_fm_documented_example_from_swift() {
    let signature = sign(
        [
            ("method", "auth.getSession"),
            ("api_key", "KEY"),
            ("token", "TOKEN"),
        ],
        "SECRET",
    );
    assert_eq!(signature, "5479efdba54a79385144dca24a423b8a");
}

#[test]
fn signature_of_a_history_request_matches_swift() {
    let signature = sign(
        [
            ("method", "user.getRecentTracks"),
            ("user", "listener"),
            ("sk", "sk-1"),
            ("limit", "200"),
            ("page", "1"),
            ("from", "1700000000"),
            ("to", "1700003600"),
            ("api_key", "KEY"),
        ],
        "SECRET",
    );
    assert_eq!(signature, "11c0167008bb91b95c2bb8dda435be04");
}

#[test]
fn format_callback_and_an_existing_signature_are_not_signed() {
    let base = [("method", "track.scrobble"), ("api_key", "KEY")];
    let with_unsigned = [
        ("method", "track.scrobble"),
        ("api_key", "KEY"),
        ("format", "json"),
        ("callback", "cb"),
        ("api_sig", "whatever"),
    ];
    assert_eq!(sign(base, "S"), sign(with_unsigned, "S"));
}

#[test]
fn form_body_leaves_alone_exactly_what_foundation_does_and_escapes_plus() {
    let ascii: String = (0x20_u8..=0x7E).map(char::from).collect();
    assert_eq!(
        form_body([("v", ascii.as_str())]),
        "v=%20!%22%23$%25%26'()*%2B,-./0123456789:;%3C%3D%3E?@ABCDEFGHIJKLMNOPQRSTUVWXYZ%5B%5C%5D%5E_%60abcdefghijklmnopqrstuvwxyz%7B%7C%7D~"
    );
}

#[test]
fn form_body_encodes_controls_and_non_ascii_as_utf8_bytes() {
    assert_eq!(
        form_escape("\u{0}\t\n\u{7F}\u{E9}\u{1F600}%"),
        "%00%09%0A%7F%C3%A9%F0%9F%98%80%25"
    );
}

#[test]
fn a_plus_in_a_name_survives_as_percent_2b() {
    let body = form_body([("artist", "C+C Music Factory")]);
    assert_eq!(body, "artist=C%2BC%20Music%20Factory");
}

#[test]
fn form_body_sorts_fields_by_name() {
    assert_eq!(form_body([("b", "2"), ("a", "1"), ("c", "")]), "a=1&b=2&c=");
}

fn parameters() -> impl Strategy<Value = Vec<(String, String)>> {
    prop::collection::btree_map("[a-z_\\[\\]0-9]{1,12}", any::<String>(), 0..12)
        .prop_map(|map| map.into_iter().collect())
}

proptest! {
    #[test]
    fn signature_does_not_depend_on_the_order_parameters_are_given(
        (pairs, shuffled) in parameters().prop_flat_map(|pairs| {
            let shuffled = Just(pairs.clone()).prop_shuffle();
            (Just(pairs), shuffled)
        }),
        secret in any::<String>(),
    ) {
        let in_order = sign(pairs.iter().map(|(k, v)| (k.as_str(), v.as_str())), &secret);
        let reordered = sign(shuffled.iter().map(|(k, v)| (k.as_str(), v.as_str())), &secret);
        prop_assert_eq!(in_order, reordered);
    }

    #[test]
    fn any_value_survives_form_encoding_and_server_side_decoding(value in any::<String>()) {
        prop_assert_eq!(common::decode_component(&form_escape(&value)), value);
    }

    #[test]
    fn a_form_body_decodes_back_to_its_fields(pairs in parameters()) {
        let body = form_body(pairs.iter().map(|(k, v)| (k.as_str(), v.as_str())));
        let decoded: Vec<(String, String)> = common::decode_form(&body).into_iter().collect();
        prop_assert_eq!(decoded, pairs);
    }

    #[test]
    fn escaped_text_has_no_byte_a_form_would_misread(value in any::<String>()) {
        let escaped = form_escape(&value);
        prop_assert!(!escaped.contains(['+', '&', '=', ' ', '#']));
    }
}
