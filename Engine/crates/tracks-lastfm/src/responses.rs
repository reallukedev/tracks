//! Reading the answers to authentication and scrobbling calls.

use crate::client::Session;
use crate::error::{LastFmError, Result};
use crate::http::HttpResponse;
use crate::json::{self, Object};

/// What Last.fm did with one scrobble from a batch.
///
/// A batch Last.fm takes still answers 200 when it ignored some of the entries, and says so
/// per entry in `ignoredMessage`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ScrobbleOutcome {
    /// Taken.
    Accepted,
    /// Ignored, with Last.fm's `ignoredMessage` code and text (usually empty).
    Ignored {
        /// Last.fm's ignored code.
        code: i64,
        /// Last.fm's text for it.
        message: String,
    },
}

impl ScrobbleOutcome {
    /// Whether Last.fm took it.
    pub fn is_accepted(&self) -> bool {
        matches!(self, Self::Accepted)
    }

    /// Whether sending the same entry later could succeed.
    ///
    /// 4 (timestamp in the future) passes once the clock catches up with it, and 5 (daily
    /// scrobble limit) the next day. 1 and 2 (artist or track ignored) and 3 (timestamp too
    /// old) are about the entry itself and never pass.
    pub fn is_retryable(&self) -> bool {
        matches!(self, Self::Ignored { code: 4 | 5, .. })
    }
}

/// Reads the token from an `auth.getToken` response.
pub fn parse_token(response: &HttpResponse) -> Result<String> {
    let json = json::object(response)?;
    json::string(&json, "token")
        .map(str::to_owned)
        .ok_or(LastFmError::MalformedResponse)
}

/// Reads the session from an `auth.getSession` response.
///
/// [`LastFmError::NotAuthorised`] until the user approves the token in the browser; the
/// caller keeps polling.
pub fn parse_session(response: &HttpResponse) -> Result<Session> {
    let json = match json::object(response) {
        // 14 is "unauthorized token".
        Err(LastFmError::Service { code: 14, .. }) => return Err(LastFmError::NotAuthorised),
        other => other?,
    };
    let session = json::child(&json, "session").ok_or(LastFmError::MalformedResponse)?;
    match (json::string(session, "name"), json::string(session, "key")) {
        (Some(name), Some(key)) => Ok(Session::new(name, key)),
        _ => Err(LastFmError::MalformedResponse),
    }
}

/// Reads a `track.updateNowPlaying` response, which matters only when it failed.
pub fn parse_now_playing(response: &HttpResponse) -> Result<()> {
    json::object(response).map(|_| ())
}

/// Reads what became of each scrobble from a `track.scrobble` response, in the order sent.
///
/// `sent` is how many the request carried (see
/// [`ScrobbleSubmission::sent`](crate::ScrobbleSubmission::sent)).
pub fn parse_scrobbles(response: &HttpResponse, sent: usize) -> Result<Vec<ScrobbleOutcome>> {
    scrobble_outcomes(&json::object(response)?, sent)
}

/// `scrobbles.scrobble` is an array for a batch but a lone object for one, and codes come
/// back as strings as often as numbers.
fn scrobble_outcomes(json: &Object, sent: usize) -> Result<Vec<ScrobbleOutcome>> {
    // Without the report there's no telling the batch arrived, so the rows stay owed.
    let report = json::child(json, "scrobbles").ok_or(LastFmError::MalformedResponse)?;
    let entries = json::objects(report.get("scrobble"));
    if entries.len() == sent {
        return Ok(entries.into_iter().map(outcome).collect());
    }
    // Can't line the entries up with what was sent, but Last.fm took the batch. Sending it
    // again would scrobble every accepted entry twice.
    Ok(vec![ScrobbleOutcome::Accepted; sent])
}

fn outcome(entry: &Object) -> ScrobbleOutcome {
    let Some(ignored) = json::child(entry, "ignoredMessage") else {
        return ScrobbleOutcome::Accepted;
    };
    match json::integer(ignored.get("code")) {
        Some(code) if code != 0 => ScrobbleOutcome::Ignored {
            code,
            message: json::string(ignored, "#text")
                .unwrap_or_default()
                .to_owned(),
        },
        _ => ScrobbleOutcome::Accepted,
    }
}
