//! Last.fm for Tracks: signed requests, the answers read into typed values, and the
//! scrobbling rules, with the transport left to the host.
//!
//! The crate is sans-IO. [`Client`] builds an [`HttpRequest`]; the host sends it with its
//! own stack (`URLSession` on Apple platforms, `OkHttp` on Android) and hands the
//! [`HttpResponse`] to the matching `parse_` function. The native stack brings the
//! platform's proxy, ATS, cellular and background-session handling for free, the binary
//! carries no TLS or async runtime, and every behaviour here is testable without a socket.
//! No clock is read either: times are Unix seconds passed in by the caller.
//!
//! ```
//! use tracks_lastfm::{Client, HttpResponse, Scrobble, Session};
//!
//! let client = Client::new("KEY", "SECRET", "Tracks/1.0");
//! let session = Session::new("listener", "sk");
//! let submission = client
//!     .scrobble(&[Scrobble::new("BANKS", "Love Is Unkind", 1_700_000_000)], &session)
//!     .expect("one scrobble is a request");
//! // The host sends `submission.request` and wraps what came back.
//! let response = HttpResponse::new(
//!     200,
//!     r##"{"scrobbles":{"scrobble":{"ignoredMessage":{"code":"0","#text":""}},"@attr":{"accepted":1,"ignored":0}}}"##,
//! );
//! let outcomes = submission.parse(&response).expect("a readable answer");
//! assert!(outcomes[0].is_accepted());
//! ```

mod backoff;
mod client;
mod encoding;
mod error;
mod history;
mod http;
mod json;
pub mod policy;
mod queue;
mod responses;
mod track_info;

pub use backoff::RetryBackoff;
pub use client::{
    AUTHORISATION_PAGE, BATCH_LIMIT, Client, DEFAULT_SIMILAR_LIMIT, ENDPOINT, HISTORY_PAGE_LIMIT,
    Scrobble, ScrobbleSubmission, Session,
};
pub use encoding::{UNSIGNED_PARAMETERS, form_body, form_escape, md5_hex, sign};
pub use error::{LastFmError, Result};
pub use history::{
    HISTORY_PAGE_ATTEMPTS, HistoryProgress, HistoryRange, KnownPlay, MISSING_ARTWORK_ID,
    MergeWindows, PageStep, ScrobbleHistoryPage, ScrobbledTrack, history_retry_delay, new_plays,
    parse_recent_tracks,
};
pub use http::{HttpRequest, HttpResponse, Method};
pub use queue::{
    AfterBatch, BatchSettlement, FailureAction, IgnoredScrobble, ImportedPlay,
    MAX_SCROBBLE_ATTEMPTS, already_scrobbled, failure_action, import_check_from, settle_batch,
};
pub use responses::{
    ScrobbleOutcome, parse_now_playing, parse_scrobbles, parse_session, parse_token,
};
pub use track_info::{
    SimilarTrack, TAG_LIMIT, TrackInfo, parse_similar_tracks, parse_track_info, plain_summary,
    useful_tags,
};
