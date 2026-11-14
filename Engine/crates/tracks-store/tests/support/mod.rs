#![allow(dead_code)]

use tracks_model::{PlayKind, PlaySource};
use tracks_store::PlayInput;

pub const MINUTE: i64 = 60_000;
pub const HOUR: i64 = 60 * MINUTE;
pub const DAY: i64 = 24 * HOUR;

pub fn play(ext: &str, title: &str, artist: &str, at: i64) -> PlayInput {
    PlayInput {
        ext_id: ext.to_owned(),
        catalog_id: String::new(),
        song_key: String::new(),
        title: title.to_owned(),
        artist_name: artist.to_owned(),
        album_title: None,
        artwork_url: None,
        played_at: at,
        kind: PlayKind::OnDemand,
        source: PlaySource::AppleMusic,
        station_name: None,
    }
}

pub fn on_album(mut play: PlayInput, album: &str) -> PlayInput {
    play.album_title = Some(album.to_owned());
    play
}

pub fn of_kind(mut play: PlayInput, kind: PlayKind) -> PlayInput {
    play.kind = kind;
    play
}
