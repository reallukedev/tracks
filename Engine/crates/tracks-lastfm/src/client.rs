//! Building signed Last.fm requests.

use std::collections::BTreeMap;
use std::fmt;

use crate::encoding::{form_body, form_escape, sign};
use crate::error::Result;
use crate::http::{HttpRequest, HttpResponse, Method};
use crate::responses::{ScrobbleOutcome, parse_scrobbles};

/// Last.fm's API endpoint. Every call is a form-encoded POST here.
pub const ENDPOINT: &str = "https://ws.audioscrobbler.com/2.0/";

/// Where the user approves a token.
pub const AUTHORISATION_PAGE: &str = "https://www.last.fm/api/auth/";

/// The most scrobbles Last.fm takes in one call.
pub const BATCH_LIMIT: usize = 50;

/// The most scrobbles `user.getRecentTracks` returns in one page.
pub const HISTORY_PAGE_LIMIT: u32 = 200;

/// How many similar songs are asked for unless the caller says otherwise.
pub const DEFAULT_SIMILAR_LIMIT: u32 = 6;

/// The connected account: its name, and a session key that never expires.
#[derive(Clone, PartialEq, Eq)]
pub struct Session {
    /// The Last.fm username.
    pub username: String,
    /// The session key, enough to scrobble as the user.
    pub session_key: String,
}

impl Session {
    /// A session for this user and key.
    pub fn new(username: impl Into<String>, session_key: impl Into<String>) -> Self {
        Self {
            username: username.into(),
            session_key: session_key.into(),
        }
    }
}

// The key never goes into a log.
impl fmt::Debug for Session {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Session")
            .field("username", &self.username)
            .field("session_key", &"<redacted>")
            .finish()
    }
}

/// One play to scrobble.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Scrobble {
    /// The artist's name.
    pub artist: String,
    /// The track's title.
    pub track: String,
    /// The album's title; an empty one is not sent.
    pub album: Option<String>,
    /// When it played, in Unix seconds.
    pub played_at: i64,
}

impl Scrobble {
    /// A scrobble with no album.
    pub fn new(artist: impl Into<String>, track: impl Into<String>, played_at: i64) -> Self {
        Self {
            artist: artist.into(),
            track: track.into(),
            album: None,
            played_at,
        }
    }

    /// The same scrobble with an album.
    #[must_use]
    pub fn with_album(mut self, album: impl Into<String>) -> Self {
        self.album = Some(album.into());
        self
    }
}

/// A `track.scrobble` request and how many scrobbles went into it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScrobbleSubmission {
    /// The request to send.
    pub request: HttpRequest,
    /// How many scrobbles it carries: the first [`BATCH_LIMIT`] of those given.
    pub sent: usize,
}

impl ScrobbleSubmission {
    /// What Last.fm did with each scrobble sent, in the order sent.
    pub fn parse(&self, response: &HttpResponse) -> Result<Vec<ScrobbleOutcome>> {
        parse_scrobbles(response, self.sent)
    }
}

/// Builds Last.fm requests signed for this application.
///
/// It never touches the network: the host sends each [`HttpRequest`] with its own stack and
/// hands the [`HttpResponse`] to the matching `parse_` function.
#[derive(Clone)]
pub struct Client {
    api_key: String,
    secret: String,
    user_agent: String,
}

// The secret never goes into a log.
impl fmt::Debug for Client {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Client")
            .field("api_key", &self.api_key)
            .field("secret", &"<redacted>")
            .field("user_agent", &self.user_agent)
            .finish()
    }
}

type Parameters = BTreeMap<String, String>;

fn parameters<const N: usize>(pairs: [(&str, &str); N]) -> Parameters {
    pairs
        .into_iter()
        .map(|(name, value)| (name.to_owned(), value.to_owned()))
        .collect()
}

impl Client {
    /// A client for this application's API key and shared secret.
    pub fn new(
        api_key: impl Into<String>,
        secret: impl Into<String>,
        user_agent: impl Into<String>,
    ) -> Self {
        Self {
            api_key: api_key.into(),
            secret: secret.into(),
            user_agent: user_agent.into(),
        }
    }

    /// The application's API key.
    pub fn api_key(&self) -> &str {
        &self.api_key
    }

    /// Step one of the desktop flow: `auth.getToken`. Read with [`crate::parse_token`].
    pub fn auth_get_token(&self) -> HttpRequest {
        self.call(parameters([("method", "auth.getToken")]))
    }

    /// Where to send the user to approve `token`, with both parts encoded.
    pub fn authorisation_url(&self, token: &str) -> String {
        format!(
            "{AUTHORISATION_PAGE}?api_key={}&token={}",
            form_escape(&self.api_key),
            form_escape(token)
        )
    }

    /// Step two: `auth.getSession`, exchanging an approved token for a session key. Read
    /// with [`crate::parse_session`].
    pub fn auth_get_session(&self, token: &str) -> HttpRequest {
        self.call(parameters([
            ("method", "auth.getSession"),
            ("token", token),
        ]))
    }

    /// `track.scrobble` for up to [`BATCH_LIMIT`] scrobbles, or `None` for an empty batch,
    /// which is not a request.
    ///
    /// Batch parameters are indexed (`artist[0]`, `track[0]`) and all of them are signed.
    pub fn scrobble(
        &self,
        scrobbles: &[Scrobble],
        session: &Session,
    ) -> Option<ScrobbleSubmission> {
        if scrobbles.is_empty() {
            return None;
        }
        let mut all = parameters([("method", "track.scrobble"), ("sk", &session.session_key)]);
        let batch = &scrobbles[..scrobbles.len().min(BATCH_LIMIT)];
        for (index, scrobble) in batch.iter().enumerate() {
            all.insert(format!("artist[{index}]"), scrobble.artist.clone());
            all.insert(format!("track[{index}]"), scrobble.track.clone());
            all.insert(
                format!("timestamp[{index}]"),
                scrobble.played_at.to_string(),
            );
            if let Some(album) = scrobble.album.as_deref().filter(|album| !album.is_empty()) {
                all.insert(format!("album[{index}]"), album.to_owned());
            }
        }
        Some(ScrobbleSubmission {
            request: self.call(all),
            sent: batch.len(),
        })
    }

    /// `track.updateNowPlaying`. It expires on its own, so a failure needn't be retried.
    /// Read with [`crate::parse_now_playing`].
    pub fn update_now_playing(
        &self,
        artist: &str,
        track: &str,
        album: Option<&str>,
        session: &Session,
    ) -> HttpRequest {
        let mut all = parameters([
            ("method", "track.updateNowPlaying"),
            ("artist", artist),
            ("track", track),
            ("sk", &session.session_key),
        ]);
        if let Some(album) = album.filter(|album| !album.is_empty()) {
            all.insert("album".to_owned(), album.to_owned());
        }
        self.call(all)
    }

    /// `user.getRecentTracks`: the first page of the account's scrobbles, newest first,
    /// at most [`HISTORY_PAGE_LIMIT`]. Read with [`crate::parse_recent_tracks`].
    ///
    /// Signed and sent with the session key, so it works for an account that hides its
    /// recent listening. `after` and `before` are Last.fm's inclusive `from` and `to`.
    pub fn recent_tracks(
        &self,
        session: &Session,
        after: Option<i64>,
        before: Option<i64>,
        limit: u32,
    ) -> HttpRequest {
        let limit = limit.min(HISTORY_PAGE_LIMIT).to_string();
        let mut all = parameters([
            ("method", "user.getRecentTracks"),
            ("user", &session.username),
            ("sk", &session.session_key),
            ("limit", &limit),
            ("page", "1"),
        ]);
        if let Some(after) = after {
            all.insert("from".to_owned(), after.to_string());
        }
        if let Some(before) = before {
            all.insert("to".to_owned(), before.to_string());
        }
        self.call(all)
    }

    /// `track.getInfo`, autocorrected. `username` adds that account's own play count. Read
    /// with [`crate::parse_track_info`].
    pub fn track_info(&self, title: &str, artist: &str, username: Option<&str>) -> HttpRequest {
        let mut all = parameters([
            ("method", "track.getInfo"),
            ("track", title),
            ("artist", artist),
            ("autocorrect", "1"),
        ]);
        if let Some(username) = username {
            all.insert("username".to_owned(), username.to_owned());
        }
        self.call(all)
    }

    /// `track.getSimilar`, autocorrected. Read with [`crate::parse_similar_tracks`].
    pub fn similar_tracks(&self, title: &str, artist: &str, limit: u32) -> HttpRequest {
        let limit = limit.to_string();
        self.call(parameters([
            ("method", "track.getSimilar"),
            ("track", title),
            ("artist", artist),
            ("autocorrect", "1"),
            ("limit", &limit),
        ]))
    }

    /// Adds the key and signature, then `format=json`, which must not be signed.
    fn call(&self, mut all: Parameters) -> HttpRequest {
        all.insert("api_key".to_owned(), self.api_key.clone());
        let signature = sign(
            all.iter().map(|(k, v)| (k.as_str(), v.as_str())),
            &self.secret,
        );
        all.insert("api_sig".to_owned(), signature);
        all.insert("format".to_owned(), "json".to_owned());

        let body = form_body(all.iter().map(|(k, v)| (k.as_str(), v.as_str())));
        HttpRequest {
            method: Method::Post,
            url: ENDPOINT.to_owned(),
            headers: vec![
                (
                    "Content-Type".to_owned(),
                    "application/x-www-form-urlencoded".to_owned(),
                ),
                ("User-Agent".to_owned(), self.user_agent.clone()),
            ],
            body: body.into_bytes(),
        }
    }
}
