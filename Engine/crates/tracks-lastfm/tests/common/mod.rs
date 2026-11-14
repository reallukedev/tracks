#![allow(dead_code, clippy::unwrap_used)]

use std::collections::BTreeMap;

use tracks_lastfm::{Client, HttpRequest, HttpResponse, Session};

pub fn client() -> Client {
    Client::new("KEY", "SECRET", "Tracks/1.0 (test)")
}

pub fn session() -> Session {
    Session::new("listener", "sk-1")
}

pub fn ok(body: &str) -> HttpResponse {
    HttpResponse::new(200, body)
}

/// Decodes a form body the way a server does: `+` is a space and `%XX` a byte.
pub fn decode_component(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'+' => out.push(b' '),
            b'%' => {
                let hex = std::str::from_utf8(&bytes[index + 1..index + 3]).unwrap();
                out.push(u8::from_str_radix(hex, 16).unwrap());
                index += 2;
            }
            byte => out.push(byte),
        }
        index += 1;
    }
    String::from_utf8(out).unwrap()
}

/// Every field of a form body, decoded.
pub fn decode_form(body: &str) -> BTreeMap<String, String> {
    body.split('&')
        .filter(|pair| !pair.is_empty())
        .map(|pair| {
            let (name, value) = pair.split_once('=').unwrap_or((pair, ""));
            (decode_component(name), decode_component(value))
        })
        .collect()
}

/// The decoded fields of a request's body.
pub fn fields(request: &HttpRequest) -> BTreeMap<String, String> {
    decode_form(std::str::from_utf8(&request.body).unwrap())
}
