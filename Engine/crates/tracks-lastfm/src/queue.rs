//! The scrobble queue's decisions, over plain values. The host owns the rows, their storage
//! and the drain loop; these say what each answer means for them.
//!
//! One drain pass: fetch up to [`BATCH_LIMIT`](crate::BATCH_LIMIT) owed rows oldest first;
//! check any imports against the account's history ([`import_check_from`],
//! [`already_scrobbled`]) and mark those found as sent; submit the rest; then apply
//! [`settle_batch`] or, if the request failed, [`failure_action`].

use std::collections::HashMap;

use tracks_model::song_key;

use crate::error::LastFmError;
use crate::history::ScrobbledTrack;
use crate::responses::ScrobbleOutcome;

/// Attempts after which a row is given up on.
pub const MAX_SCROBBLE_ATTEMPTS: u32 = 3;

/// An import waiting to be sent, as the history check sees it.
///
/// Apple's recently-played list covers the whole account, so an import can be a play
/// another device already scrobbled. Only Last.fm's own history knows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImportedPlay<Id> {
    /// The host's identity for the row.
    pub id: Id,
    /// The song's identity ([`tracks_model::song_key`]).
    pub key: String,
    /// When the import found it, in Unix seconds.
    pub found_at: i64,
}

impl<Id> ImportedPlay<Id> {
    /// An import of this song, found at `found_at`.
    pub fn new(id: Id, title: &str, artist: &str, found_at: i64) -> Self {
        Self {
            id,
            key: song_key(title, artist),
            found_at,
        }
    }
}

/// Where to start reading the history to check `imports`: `window` seconds before the
/// earliest was found. `None` when there are no imports to check.
pub fn import_check_from<Id>(imports: &[ImportedPlay<Id>], window: f64) -> Option<i64> {
    let earliest = imports.iter().map(|play| play.found_at).min()?;
    Some((earliest as f64 - window) as i64)
}

/// The imports Last.fm already has: the same song scrobbled within `window` seconds before
/// the import found it. Each scrobble accounts for one import at most. In import order.
pub fn already_scrobbled<Id: Clone>(
    imports: &[ImportedPlay<Id>],
    history: &[ScrobbledTrack],
    window: f64,
) -> Vec<Id> {
    let mut scrobbled: HashMap<String, Vec<i64>> = HashMap::new();
    for track in history {
        scrobbled
            .entry(track.key())
            .or_default()
            .push(track.played_at);
    }
    let mut found = Vec::new();
    for play in imports {
        let Some(times) = scrobbled.get_mut(&play.key) else {
            continue;
        };
        let matching = times
            .iter()
            .position(|&at| at <= play.found_at && ((play.found_at - at) as f64) <= window);
        if let Some(index) = matching {
            times.remove(index);
            found.push(play.id.clone());
        }
    }
    found
}

/// An entry Last.fm ignored, with its code and text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IgnoredScrobble {
    /// Last.fm's ignored code.
    pub code: i64,
    /// Last.fm's text for it, usually empty.
    pub message: String,
}

/// What the drain does once a batch is settled.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AfterBatch {
    /// Record a failure on the backoff and stop: something was held back.
    BackOff,
    /// Reset the backoff and fetch the next batch: this one was full.
    NextBatch,
    /// Reset the backoff and stop: the queue is empty.
    Done,
}

/// What to do with each row of a batch Last.fm answered.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BatchSettlement<Id> {
    /// Rows to mark sent, clearing their error.
    pub accepted: Vec<Id>,
    /// Rows Last.fm will never take: set their attempts to at least
    /// [`MAX_SCROBBLE_ATTEMPTS`] and keep the reason. Marking them sent would claim a play
    /// Last.fm doesn't have.
    pub given_up: Vec<(Id, IgnoredScrobble)>,
    /// The last entry held back for the daily limit or a future timestamp. Its rows stay
    /// owed and untouched; this is the error to show.
    pub held_back: Option<IgnoredScrobble>,
    /// What the drain does next.
    pub next: AfterBatch,
}

impl<Id> BatchSettlement<Id> {
    /// How many Last.fm accepted.
    pub fn accepted_count(&self) -> usize {
        self.accepted.len()
    }
}

/// Settles a batch: `ids` are the rows sent, in order, and `outcomes` what Last.fm did with
/// each.
///
/// A held-back entry backs off without resetting first, so a daily limit still in force
/// keeps lengthening the wait instead of being asked about every thirty seconds.
pub fn settle_batch<Id: Clone>(ids: &[Id], outcomes: &[ScrobbleOutcome]) -> BatchSettlement<Id> {
    let mut accepted = Vec::new();
    let mut given_up = Vec::new();
    let mut held_back = None;
    for (id, outcome) in ids.iter().zip(outcomes) {
        match outcome {
            ScrobbleOutcome::Accepted => accepted.push(id.clone()),
            ScrobbleOutcome::Ignored { code, message } => {
                let ignored = IgnoredScrobble {
                    code: *code,
                    message: message.clone(),
                };
                if outcome.is_retryable() {
                    held_back = Some(ignored);
                } else {
                    given_up.push((id.clone(), ignored));
                }
            }
        }
    }
    let next = if held_back.is_some() {
        AfterBatch::BackOff
    } else if ids.len() < crate::BATCH_LIMIT {
        AfterBatch::Done
    } else {
        AfterBatch::NextBatch
    };
    BatchSettlement {
        accepted,
        given_up,
        held_back,
        next,
    }
}

/// What a failed scrobble request costs. The drain stops either way: the next batch would
/// fail the same way.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureAction {
    /// Last.fm rejected the request itself: charge each row an attempt and keep the error.
    ChargeRows,
    /// Offline, Last.fm down or rate limiting, or an account problem: leave the rows alone
    /// and record a failure on the backoff.
    BackOff,
}

/// What a failed `track.scrobble` costs. `None` is a transport failure the host saw before
/// any response, such as being offline.
///
/// A failed history check before sending imports always backs off instead: sending without
/// knowing could scrobble a play twice.
pub fn failure_action(error: Option<&LastFmError>) -> FailureAction {
    if error.is_some_and(LastFmError::is_the_scrobbles_fault) {
        FailureAction::ChargeRows
    } else {
        FailureAction::BackOff
    }
}
