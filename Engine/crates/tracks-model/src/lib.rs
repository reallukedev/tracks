//! Tracks' domain model: what a play is, and how names fold into the identities that
//! charts, search and mixes group on.
//!
//! Pure logic with no I/O, so every platform shares it unchanged.

pub mod credits;
mod fold;
mod kind;

pub use credits::{ArtistCredit, credits_by_name, may_credit_several};
pub use fold::{KEY_SEPARATOR, album_key, folded, is_near, search_folded, song_key};
pub use kind::{PlayKind, PlaySource, UnknownValue};

/// How long a play is assumed to last when nothing measures it.
pub const TYPICAL_SONG_SECONDS: u32 = 210;

/// A longer gap than this between two plays means playback stopped in between.
pub const LONGEST_PLAUSIBLE_GAP_SECONDS: i64 = 600;
