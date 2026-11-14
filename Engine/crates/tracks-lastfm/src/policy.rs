//! When a play is worth reporting to a scrobbling service.
//!
//! Last.fm's rule, which also satisfies `ListenBrainz`: the track is longer than 30 seconds
//! and was played for half its length or 4 minutes, whichever comes first.

/// Tracks this long or shorter never scrobble, in seconds.
pub const MINIMUM_TRACK_DURATION: f64 = 30.0;

/// No track needs to play longer than this to scrobble, in seconds.
pub const MAXIMUM_REQUIRED_PLAYBACK: f64 = 240.0;

/// The length a track of unknown length is taken to have, in seconds.
pub const ASSUMED_SONG_LENGTH: f64 = 240.0;

/// Why a play too short for Last.fm isn't owed, as stored on the row.
pub const TOO_SHORT_REASON: &str = "Last.fm doesn\u{2019}t count tracks of 30 seconds or less.";

/// Why a play that stopped early isn't owed, as stored on the row.
pub const NOT_PLAYED_ENOUGH_REASON: &str =
    "Last.fm counts a song once half of it or four minutes has played.";

/// Whether a track of `duration` seconds, played for `played_for`, qualifies.
pub fn should_scrobble(duration: f64, played_for: f64) -> bool {
    required_playback(Some(duration)).is_some_and(|threshold| played_for >= threshold)
}

/// How long a track of `duration` seconds has to play to qualify, or `None` for one too
/// short ever to qualify. A missing, zero, negative or NaN length counts as
/// [`ASSUMED_SONG_LENGTH`].
pub fn required_playback(duration: Option<f64>) -> Option<f64> {
    let length = duration
        .filter(|&duration| duration > 0.0)
        .unwrap_or(ASSUMED_SONG_LENGTH);
    (length > MINIMUM_TRACK_DURATION).then(|| (length / 2.0).min(MAXIMUM_REQUIRED_PLAYBACK))
}

/// Whether the queue is passing a play over because the policy held it back, rather than
/// because Last.fm refused it.
pub fn is_held_from_scrobbling(scrobbled_at: Option<i64>, last_error: Option<&str>) -> bool {
    scrobbled_at.is_none()
        && matches!(
            last_error,
            Some(TOO_SHORT_REASON | NOT_PLAYED_ENOUGH_REASON)
        )
}
