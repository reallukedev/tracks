//! Reading the account's scrobbles back, and bringing them into the history without
//! writing a play twice.

use std::collections::{HashMap, HashSet};
use std::hash::BuildHasher;

use tracks_model::{PlayKind, song_key};

use crate::error::{LastFmError, Result};
use crate::http::HttpResponse;
use crate::json::{self, Object};

/// The file name of Last.fm's grey-star placeholder cover.
pub const MISSING_ARTWORK_ID: &str = "2a96cbd8b46e442fc41c2b86b821562f";

/// How many times one history page is tried when Last.fm is busy or the network drops.
pub const HISTORY_PAGE_ATTEMPTS: u32 = 4;

/// One scrobble read back from Last.fm.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScrobbledTrack {
    /// The track's title, trimmed.
    pub title: String,
    /// The artist's name, trimmed.
    pub artist_name: String,
    /// The album's title, or `None` for a blank one.
    pub album_title: Option<String>,
    /// The largest real cover Last.fm lists.
    pub artwork_url: Option<String>,
    /// When it played, in Unix seconds.
    pub played_at: i64,
}

impl ScrobbledTrack {
    /// A scrobble with no album or cover.
    pub fn new(title: impl Into<String>, artist_name: impl Into<String>, played_at: i64) -> Self {
        Self {
            title: title.into(),
            artist_name: artist_name.into(),
            album_title: None,
            artwork_url: None,
            played_at,
        }
    }

    /// The song's identity, as the history groups on it.
    pub fn key(&self) -> String {
        song_key(&self.title, &self.artist_name)
    }
}

/// One page of `user.getRecentTracks`, newest first.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ScrobbleHistoryPage {
    /// The scrobbles on this page, leaving out the song playing now.
    pub scrobbles: Vec<ScrobbledTrack>,
    /// Scrobbles in the whole range asked for, not just this page.
    pub total: i64,
    /// Pages in the whole range.
    pub total_pages: i64,
}

/// Reads a `user.getRecentTracks` response.
///
/// `track` is an array, a lone object, or missing. The song playing now comes first with
/// `@attr.nowplaying` and no date; it isn't a scrobble yet, so it's left out. Names are
/// under `#text`, dates under `uts`, and numbers arrive as strings.
pub fn parse_recent_tracks(response: &HttpResponse) -> Result<ScrobbleHistoryPage> {
    let json = json::object(response)?;
    let recent = json::child(&json, "recenttracks").ok_or(LastFmError::MalformedResponse)?;
    let attributes = json::child(recent, "@attr");
    let count = |key| json::integer(attributes.and_then(|attributes| attributes.get(key)));
    Ok(ScrobbleHistoryPage {
        scrobbles: json::objects(recent.get("track"))
            .into_iter()
            .filter_map(scrobbled_track)
            .collect(),
        total: count("total").unwrap_or(0),
        total_pages: count("totalPages").unwrap_or(0),
    })
}

fn scrobbled_track(entry: &Object) -> Option<ScrobbledTrack> {
    let played_at = json::integer(json::child(entry, "date")?.get("uts"))?;
    let title = json::trimmed(json::string(entry, "name")?);
    let artist = json::trimmed(json::text(entry.get("artist"))?);
    if title.is_empty() || artist.is_empty() {
        return None;
    }
    let album = json::text(entry.get("album"))
        .map(json::trimmed)
        .filter(|album| !album.is_empty());
    Some(ScrobbledTrack {
        title: title.to_owned(),
        artist_name: artist.to_owned(),
        album_title: album.map(str::to_owned),
        artwork_url: artwork_url(entry.get("image")),
        played_at,
    })
}

/// The largest cover Last.fm lists, unless it's the grey star it uses for a missing one.
fn artwork_url(value: Option<&serde_json::Value>) -> Option<String> {
    let images = value?.as_array()?;
    if !images.iter().all(serde_json::Value::is_object) {
        return None;
    }
    let url = images
        .iter()
        .rev()
        .filter_map(|image| image.get("#text")?.as_str())
        .find(|url| !url.is_empty())?;
    (!url.contains(MISSING_ARTWORK_ID) && json::is_loadable_url(url)).then(|| url.to_owned())
}

/// How far apart two rows of the same song can be and still be one play: the windows the
/// store's duplicate merge uses.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MergeWindows {
    /// Seconds, for a later row whose time is when it played.
    pub window: f64,
    /// Seconds, for a later row that is an import, dated when it was found.
    pub import_window: f64,
}

impl Default for MergeWindows {
    fn default() -> Self {
        Self {
            window: 10.0 * 60.0,
            import_window: 24.0 * 60.0 * 60.0,
        }
    }
}

impl MergeWindows {
    /// The window for a pair whose later row is of kind `later`.
    ///
    /// What decides it is whether the later row is an import, since an import is dated at
    /// or after the play itself.
    pub fn merge_window(&self, later: PlayKind) -> f64 {
        if later.time_is_known() {
            self.window
        } else {
            self.import_window
        }
    }
}

/// A row already in the history, as the duplicate check sees it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KnownPlay {
    /// The song's identity ([`tracks_model::song_key`]).
    pub key: String,
    /// The row's time, in Unix seconds.
    pub played_at: i64,
    /// How the row came to be.
    pub kind: PlayKind,
}

/// The scrobbles worth writing, oldest first.
///
/// A scrobble is the same play as a row of the same song close enough to it by the merge
/// windows, so an import never writes a row the next merge would delete. Scrobbles already
/// taken count too, so one song scrobbled twice within the window is kept once. Songs in
/// `forgotten` stay out.
pub fn new_plays<S: BuildHasher>(
    scrobbles: &[ScrobbledTrack],
    known: &[KnownPlay],
    forgotten: &HashSet<String, S>,
    windows: MergeWindows,
) -> Vec<ScrobbledTrack> {
    let mut plays: HashMap<String, Vec<(i64, PlayKind)>> = HashMap::new();
    for play in known {
        plays
            .entry(play.key.clone())
            .or_default()
            .push((play.played_at, play.kind));
    }

    let mut ordered: Vec<&ScrobbledTrack> = scrobbles.iter().collect();
    ordered.sort_by_key(|scrobble| scrobble.played_at);

    let mut result = Vec::new();
    for scrobble in ordered {
        let key = scrobble.key();
        if forgotten.contains(&key) {
            continue;
        }
        let rows = plays.entry(key).or_default();
        let is_known = rows.iter().any(|&(at, kind)| {
            if at <= scrobble.played_at {
                ((scrobble.played_at - at) as f64) < windows.merge_window(PlayKind::LastFm)
            } else {
                ((at - scrobble.played_at) as f64) < windows.merge_window(kind)
            }
        });
        if !is_known {
            rows.push((scrobble.played_at, PlayKind::LastFm));
            result.push(scrobble.clone());
        }
    }
    result
}

/// How far an import of the account's history has got, kept between runs so one that stops
/// part way picks up where it left off, and a later sync only reads what's new.
///
/// Last.fm lists newest first, so a run reads down from the top. Everything up to
/// `imported_through` is in; an unfinished run has read from `run_newest` down to
/// `run_before`, and the gap between that and `imported_through` is what's left.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryProgress {
    /// The account this is about. Another account starts from nothing.
    pub username: String,
    /// Every scrobble at or before this is in. `None` until a first import finishes.
    pub imported_through: Option<i64>,
    /// The newest scrobble of an unfinished run.
    pub run_newest: Option<i64>,
    /// The oldest scrobble an unfinished run has reached.
    pub run_before: Option<i64>,
    /// When the last run finished.
    pub last_finished: Option<i64>,
    /// How many plays imports have added in all.
    pub imported: u64,
}

/// The range one page of a walk asks for, in Unix seconds, both ends inclusive.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HistoryRange {
    /// Last.fm's `from`.
    pub after: Option<i64>,
    /// Last.fm's `to`.
    pub before: i64,
}

/// What to do after a page of a walk.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PageStep {
    /// Ask for the next page, ending here.
    Next {
        /// The next page's `to`.
        before: i64,
    },
    /// The walk has read everything; call [`HistoryProgress::finish_walk`].
    Done,
}

impl HistoryProgress {
    /// Progress for an account that has imported nothing.
    pub fn new(username: impl Into<String>) -> Self {
        Self {
            username: username.into(),
            imported_through: None,
            run_newest: None,
            run_before: None,
            last_finished: None,
            imported: 0,
        }
    }

    /// The stored progress if it is this account's, otherwise a fresh start.
    pub fn for_account(stored: Option<Self>, username: &str) -> Self {
        stored
            .filter(|progress| progress.username == username)
            .unwrap_or_else(|| Self::new(username))
    }

    /// Whether a run stopped part way through. Such a run is finished first, then walked
    /// again for what was scrobbled since it started.
    pub fn is_unfinished(&self) -> bool {
        self.run_before.is_some()
    }

    /// The first page of a walk. A fresh walk reads up to `now`, so pages further down don't
    /// move as new scrobbles arrive.
    pub fn walk_start(&self, now: i64) -> HistoryRange {
        HistoryRange {
            after: self.imported_through,
            before: self.run_before.unwrap_or(now),
        }
    }

    /// Records a page read with `to = before`, of which `added` plays were new.
    pub fn record_page(&mut self, page: &ScrobbleHistoryPage, before: i64, added: u64) -> PageStep {
        let times = page.scrobbles.iter().map(|scrobble| scrobble.played_at);
        let (Some(oldest), Some(newest)) = (times.clone().min(), times.max()) else {
            return PageStep::Done;
        };
        // Last.fm's range includes its ends, so the next page reads this one's oldest again
        // and the duplicate check skips it. A page all in one second would otherwise repeat.
        let next = if oldest < before { oldest } else { before - 1 };
        self.run_newest = Some(self.run_newest.map_or(newest, |run| run.max(newest)));
        self.run_before = Some(next);
        self.imported += added;
        if page.total_pages <= 1 {
            PageStep::Done
        } else {
            PageStep::Next { before: next }
        }
    }

    /// Closes a walk: everything it read is in.
    pub fn finish_walk(&mut self) {
        if let Some(newest) = self.run_newest {
            self.imported_through = Some(
                self.imported_through
                    .map_or(newest, |through| through.max(newest)),
            );
        }
        self.run_newest = None;
        self.run_before = None;
    }

    /// Closes a run of one or two walks.
    pub fn finish_run(&mut self, now: i64) {
        self.last_finished = Some(now);
    }
}

/// How long to wait before trying a history page again after `attempt` (counting from one)
/// failed in a way worth retrying, or `None` once the attempts are used up.
pub fn history_retry_delay(attempt: u32) -> Option<f64> {
    (1..HISTORY_PAGE_ATTEMPTS)
        .contains(&attempt)
        .then(|| f64::from(1_u32 << attempt))
}
