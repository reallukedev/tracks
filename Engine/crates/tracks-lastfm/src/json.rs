//! Reading Last.fm's JSON, which is converted from XML and carries the scars.

use serde_json::{Map, Value};

use crate::error::{LastFmError, Result};
use crate::http::HttpResponse;

pub(crate) type Object = Map<String, Value>;

/// The body as a JSON object, or the error the response stands for.
///
/// The body is checked first: Last.fm's errors usually come with a plain 400, and sometimes
/// with a 200.
pub(crate) fn object(response: &HttpResponse) -> Result<Object> {
    let json = match serde_json::from_slice::<Value>(&response.body) {
        Ok(Value::Object(object)) => Some(object),
        _ => None,
    };
    if let Some(code) = json
        .as_ref()
        .and_then(|json| whole_number(json.get("error")?))
    {
        let message = json
            .as_ref()
            .and_then(|json| json.get("message")?.as_str())
            .unwrap_or_default()
            .to_owned();
        return Err(LastFmError::Service { code, message });
    }
    if !(200..300).contains(&response.status) {
        return Err(LastFmError::Http {
            status: response.status,
        });
    }
    // A captive portal or a proxy can answer 200 with a page of HTML. That isn't Last.fm.
    json.ok_or(LastFmError::MalformedResponse)
}

/// A JSON number that is a whole number.
fn whole_number(value: &Value) -> Option<i64> {
    let Value::Number(number) = value else {
        return None;
    };
    if let Some(whole) = number.as_i64() {
        return Some(whole);
    }
    let float = number.as_f64()?;
    (float.fract() == 0.0 && float >= i64::MIN as f64 && float <= i64::MAX as f64)
        .then_some(float as i64)
}

/// A number that can arrive as a JSON number or as a string of digits.
pub(crate) fn integer(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::String(text) => text.parse().ok(),
        other => whole_number(other),
    }
}

/// A string field.
pub(crate) fn string<'a>(object: &'a Object, key: &str) -> Option<&'a str> {
    object.get(key)?.as_str()
}

/// An object field.
pub(crate) fn child<'a>(object: &'a Object, key: &str) -> Option<&'a Object> {
    object.get(key)?.as_object()
}

/// A name that is either a plain string, `{"#text": "Name"}`, or `{"name": "Name"}` when
/// extended data was asked for.
pub(crate) fn text(value: Option<&Value>) -> Option<&str> {
    match value? {
        Value::String(text) => Some(text),
        Value::Object(object) => string(object, "#text").or_else(|| string(object, "name")),
        _ => None,
    }
}

/// A list that is an array for several, a lone object for one, and missing for none.
///
/// An array holding anything other than objects reads as empty, as the Swift cast did.
pub(crate) fn objects(value: Option<&Value>) -> Vec<&Object> {
    match value {
        Some(Value::Array(items)) => items
            .iter()
            .map(Value::as_object)
            .collect::<Option<Vec<_>>>()
            .unwrap_or_default(),
        Some(Value::Object(one)) => vec![one],
        _ => Vec::new(),
    }
}

/// Whether Foundation's `.whitespacesAndNewlines` contains this character.
pub(crate) fn is_whitespace_or_newline(c: char) -> bool {
    c.is_whitespace() || matches!(c, '\u{180E}' | '\u{200B}' | '\u{FEFF}')
}

/// Foundation's `.whitespaces`: horizontal space only, no line breaks.
pub(crate) fn is_horizontal_whitespace(c: char) -> bool {
    is_whitespace_or_newline(c)
        && !matches!(
            c,
            '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}'
        )
}

/// Trims `.whitespacesAndNewlines`.
pub(crate) fn trimmed(text: &str) -> &str {
    text.trim_matches(is_whitespace_or_newline)
}

/// Whether Foundation's `URL(string:)` would take this and its scheme is http or https.
///
/// Foundation rejects spaces and control characters outright, which is the part that
/// matters for a cover from Last.fm.
pub(crate) fn is_loadable_url(url: &str) -> bool {
    let Some((scheme, rest)) = url.split_once(':') else {
        return false;
    };
    !rest.is_empty()
        && (scheme.eq_ignore_ascii_case("https") || scheme.eq_ignore_ascii_case("http"))
        && is_parseable_url(url)
}

/// Whether `URL(string:)` would parse this at all.
pub(crate) fn is_parseable_url(url: &str) -> bool {
    !url.is_empty() && !url.chars().any(|c| c.is_whitespace() || c.is_control())
}
