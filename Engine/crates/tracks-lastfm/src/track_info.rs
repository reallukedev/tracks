//! What Last.fm knows about a song: how widely it's heard, its tags, its wiki summary, and
//! the songs its listeners also play.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};

use crate::error::{LastFmError, Result};
use crate::http::HttpResponse;
use crate::json::{self, Object};

/// Tags kept at most; Last.fm's list runs on into noise.
pub const TAG_LIMIT: usize = 5;

/// Last.fm's code for a track it doesn't know.
const TRACK_NOT_FOUND: i64 = 6;

/// A song Last.fm's listeners also play.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SimilarTrack {
    /// The track's title.
    pub title: String,
    /// The artist's name.
    pub artist_name: String,
}

impl SimilarTrack {
    /// Artist and title joined by the unit separator, as the Swift app identifies it.
    pub fn id(&self) -> String {
        format!("{}\u{1F}{}", self.artist_name, self.title)
    }
}

/// What Last.fm knows about a song. Serialises with the Swift app's cache keys.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrackInfo {
    /// Distinct listeners.
    pub listeners: Option<i64>,
    /// Scrobbles by everyone.
    pub scrobbles: Option<i64>,
    /// The connected account's own scrobbles of it.
    pub your_scrobbles: Option<i64>,
    /// Useful tags, at most [`TAG_LIMIT`].
    pub tags: Vec<String>,
    /// Plain text, without Last.fm's trailing "Read more" link.
    pub summary: Option<String>,
    /// The song's page on Last.fm.
    pub url: Option<String>,
    /// Songs its listeners also play.
    pub similar: Vec<SimilarTrack>,
}

impl TrackInfo {
    /// Nothing worth showing.
    pub fn is_empty(&self) -> bool {
        self.listeners.unwrap_or(0) == 0
            && self.scrobbles.unwrap_or(0) == 0
            && self.tags.is_empty()
            && self.summary.is_none()
            && self.similar.is_empty()
    }
}

/// Reads a `track.getInfo` response for the song asked about. `None` when Last.fm doesn't
/// know the song.
///
/// Tags that only repeat the artist's or song's name are dropped.
pub fn parse_track_info(
    response: &HttpResponse,
    title: &str,
    artist: &str,
) -> Result<Option<TrackInfo>> {
    let json = match json::object(response) {
        Err(LastFmError::Service {
            code: TRACK_NOT_FOUND,
            ..
        }) => return Ok(None),
        other => other?,
    };
    let Some(track) = json::child(&json, "track") else {
        return Ok(None);
    };
    let tag_names: Vec<&str> =
        json::objects(json::child(track, "toptags").and_then(|tags| tags.get("tag")))
            .into_iter()
            .filter_map(|tag| json::string(tag, "name"))
            .collect();
    Ok(Some(TrackInfo {
        listeners: json::integer(track.get("listeners")),
        scrobbles: json::integer(track.get("playcount")),
        your_scrobbles: json::integer(track.get("userplaycount")),
        tags: useful_tags(&tag_names, artist, title),
        summary: json::child(track, "wiki")
            .and_then(|wiki| json::string(wiki, "summary"))
            .and_then(plain_summary),
        url: json::string(track, "url")
            .filter(|url| json::is_parseable_url(url))
            .map(str::to_owned),
        similar: Vec::new(),
    }))
}

/// Reads a `track.getSimilar` response, most alike first, each song once however it's
/// cased. Empty when Last.fm doesn't know the song.
pub fn parse_similar_tracks(response: &HttpResponse) -> Result<Vec<SimilarTrack>> {
    let json = match json::object(response) {
        Err(LastFmError::Service {
            code: TRACK_NOT_FOUND,
            ..
        }) => return Ok(Vec::new()),
        other => other?,
    };
    Ok(similar_tracks(&json))
}

fn similar_tracks(json: &Object) -> Vec<SimilarTrack> {
    let entries =
        json::objects(json::child(json, "similartracks").and_then(|similar| similar.get("track")));
    let mut seen = HashSet::new();
    entries
        .into_iter()
        .filter_map(|entry| {
            let title = json::string(entry, "name").filter(|title| !title.is_empty())?;
            let artist = json::child(entry, "artist")
                .and_then(|artist| json::string(artist, "name"))
                .filter(|artist| !artist.is_empty())?;
            let track = SimilarTrack {
                title: title.to_owned(),
                artist_name: artist.to_owned(),
            };
            seen.insert(track.id().to_lowercase()).then_some(track)
        })
        .collect()
}

/// The tags that say something: not the artist's or the song's own name, each once however
/// it's spelt ("Hip-Hop", "hip hop"), with capitals where it was all lowercase.
pub fn useful_tags(tags: &[&str], artist: &str, title: &str) -> Vec<String> {
    let key = |text: &str| -> String {
        text.to_lowercase()
            .chars()
            .filter(|c| c.is_alphabetic() || c.is_numeric())
            .collect()
    };
    let mut seen: HashSet<String> = [key(artist), key(title)].into_iter().collect();
    let mut useful = Vec::new();
    for tag in tags {
        let trimmed = tag.trim_matches(json::is_horizontal_whitespace);
        if trimmed.is_empty() || !seen.insert(key(trimmed)) {
            continue;
        }
        useful.push(if trimmed == trimmed.to_lowercase() {
            capitalized(trimmed)
        } else {
            trimmed.to_owned()
        });
        if useful.len() == TAG_LIMIT {
            break;
        }
    }
    useful
}

/// Foundation's `capitalized`: a letter that follows anything but a letter or an apostrophe
/// starts a word ("80s pop" becomes "80S Pop", "rock'n'roll" stays one word).
fn capitalized(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut in_word = false;
    for c in text.chars() {
        if c.is_alphabetic() {
            if in_word {
                out.extend(c.to_lowercase());
            } else {
                out.extend(c.to_uppercase());
            }
            in_word = true;
        } else {
            out.push(c);
            in_word = matches!(c, '\'' | '\u{2019}') && in_word;
        }
    }
    out
}

/// Last.fm's wiki summary as plain text: its tags, its entities and its "Read more on
/// Last.fm" link gone. `None` when nothing's left.
pub fn plain_summary(html: &str) -> Option<String> {
    let before_link = html.rfind("<a href=").map_or(html, |link| &html[..link]);
    let mut text = strip_tags(before_link);
    for (entity, character) in [
        ("&amp;", "&"),
        ("&quot;", "\""),
        ("&#39;", "'"),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&nbsp;", " "),
    ] {
        text = text.replace(entity, character);
    }
    let text = json::trimmed(&text);
    (!text.is_empty()).then(|| text.to_owned())
}

/// Removes every `<...>` with at least one character inside, as the regex `<[^>]+>` does.
fn strip_tags(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut rest = html;
    while let Some(open) = rest.find('<') {
        out.push_str(&rest[..open]);
        let after = &rest[open + 1..];
        match after.find('>') {
            Some(close) if close > 0 => rest = &after[close + 1..],
            _ => {
                out.push('<');
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}
