//! The `api_sig` signature and the form body, the two places Last.fm rejects a request
//! without saying which part was wrong.

use md5::{Digest, Md5};
use std::fmt::Write as _;

/// Parameters that are sent but never signed.
pub const UNSIGNED_PARAMETERS: [&str; 3] = ["format", "callback", "api_sig"];

/// Last.fm's `api_sig`: MD5 of every signed parameter's name and value, sorted by name and
/// joined with no separators, with the shared secret appended. Lowercase hex.
///
/// ```
/// let signature = tracks_lastfm::sign(
///     [("method", "auth.getSession"), ("api_key", "KEY"), ("token", "TOKEN")],
///     "SECRET",
/// );
/// assert_eq!(signature, tracks_lastfm::md5_hex("api_keyKEYmethodauth.getSessiontokenTOKENSECRET"));
/// ```
pub fn sign<'a>(parameters: impl IntoIterator<Item = (&'a str, &'a str)>, secret: &str) -> String {
    let mut signable: Vec<(&str, &str)> = parameters
        .into_iter()
        .filter(|(name, _)| !UNSIGNED_PARAMETERS.contains(name))
        .collect();
    signable.sort_unstable();
    let mut hasher = Md5::new();
    for (name, value) in signable {
        hasher.update(name.as_bytes());
        hasher.update(value.as_bytes());
    }
    hasher.update(secret.as_bytes());
    hex(&hasher.finalize())
}

/// MD5 of the UTF-8 bytes, as lowercase hex.
pub fn md5_hex(value: &str) -> String {
    hex(&Md5::digest(value.as_bytes()))
}

fn hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(out, "{byte:02x}");
    }
    out
}

/// Whether a byte goes into the form body as itself.
///
/// The set `URLComponents` leaves alone in a query item, which is what the Swift client sent
/// and Last.fm has always taken, less `+`: a form decodes `+` as a space, so
/// "C+C Music Factory" would scrobble as "C C Music Factory".
const fn is_left_alone(byte: u8) -> bool {
    matches!(byte,
        b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9'
        | b'-' | b'.' | b'_' | b'~'
        | b'!' | b'$' | b'\'' | b'(' | b')' | b'*' | b',' | b'/' | b':' | b';' | b'?' | b'@')
}

/// Percent-encodes a name or value for the form body, with uppercase hex.
///
/// ```
/// assert_eq!(tracks_lastfm::form_escape("C+C Me & You"), "C%2BC%20Me%20%26%20You");
/// ```
pub fn form_escape(value: &str) -> String {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut out = String::with_capacity(value.len());
    for &byte in value.as_bytes() {
        if is_left_alone(byte) {
            out.push(char::from(byte));
        } else {
            out.push('%');
            out.push(char::from(HEX[usize::from(byte >> 4)]));
            out.push(char::from(HEX[usize::from(byte & 0x0F)]));
        }
    }
    out
}

/// An `application/x-www-form-urlencoded` body, the fields in name order.
pub fn form_body<'a>(parameters: impl IntoIterator<Item = (&'a str, &'a str)>) -> String {
    let mut fields: Vec<(&str, &str)> = parameters.into_iter().collect();
    fields.sort_unstable();
    let mut body = String::new();
    for (index, (name, value)) in fields.into_iter().enumerate() {
        if index > 0 {
            body.push('&');
        }
        body.push_str(&form_escape(name));
        body.push('=');
        body.push_str(&form_escape(value));
    }
    body
}
