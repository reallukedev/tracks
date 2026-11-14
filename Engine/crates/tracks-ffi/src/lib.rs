//! The engine as Swift (and later Kotlin) sees it, generated with `UniFFI`.
//!
//! Every call is synchronous and thread-safe; hosts call it off their main thread. Times
//! cross as Unix milliseconds, so no calendar logic leaks across the boundary: the host
//! works out periods with its own calendar and the engine counts within them.

// UniFFI hands every argument over owned, so taking references isn't an option.
#![expect(
    clippy::needless_pass_by_value,
    reason = "UniFFI passes arguments by value"
)]

use std::sync::Arc;

uniffi::setup_scaffolding!();

/// Something the engine couldn't do.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum EngineError {
    #[error("database: {message}")]
    Database { message: String },
    #[error("unknown time zone `{identifier}`")]
    TimeZone { identifier: String },
    #[error("the index is closed")]
    Closed,
}

impl From<tracks_store::StoreError> for EngineError {
    fn from(error: tracks_store::StoreError) -> Self {
        match error {
            tracks_store::StoreError::TimeZone(identifier) => Self::TimeZone { identifier },
            tracks_store::StoreError::Closed => Self::Closed,
            other => Self::Database {
                message: other.to_string(),
            },
        }
    }
}

type Result<T> = std::result::Result<T, EngineError>;

// MARK: - Model

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PlayKind {
    Radio,
    OnDemand,
    Imported,
    LastFm,
}

impl From<PlayKind> for tracks_model::PlayKind {
    fn from(kind: PlayKind) -> Self {
        match kind {
            PlayKind::Radio => Self::Radio,
            PlayKind::OnDemand => Self::OnDemand,
            PlayKind::Imported => Self::Imported,
            PlayKind::LastFm => Self::LastFm,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PlaySource {
    AppleMusic,
    YourMusic,
}

impl From<PlaySource> for tracks_model::PlaySource {
    fn from(source: PlaySource) -> Self {
        match source {
            PlaySource::AppleMusic => Self::AppleMusic,
            PlaySource::YourMusic => Self::YourMusic,
        }
    }
}

/// One play as the host has it.
#[derive(Debug, Clone, uniffi::Record)]
pub struct Play {
    /// The host's stable id for the play; writing it again updates rather than duplicates.
    pub id: String,
    pub catalog_id: String,
    pub song_key: String,
    pub title: String,
    pub artist_name: String,
    pub album_title: Option<String>,
    pub artwork_url: Option<String>,
    pub played_at_ms: i64,
    pub kind: PlayKind,
    pub source: PlaySource,
    pub station_name: Option<String>,
}

impl From<Play> for tracks_store::PlayInput {
    fn from(play: Play) -> Self {
        Self {
            ext_id: play.id,
            catalog_id: play.catalog_id,
            song_key: play.song_key,
            title: play.title,
            artist_name: play.artist_name,
            album_title: play.album_title,
            artwork_url: play.artwork_url,
            played_at: play.played_at_ms,
            kind: play.kind.into(),
            source: play.source.into(),
            station_name: play.station_name,
        }
    }
}

#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct WriteReport {
    pub inserted: u64,
    pub updated: u64,
    pub unchanged: u64,
    pub removed: u64,
}

impl From<tracks_store::IngestReport> for WriteReport {
    fn from(r: tracks_store::IngestReport) -> Self {
        Self {
            inserted: r.inserted,
            updated: r.updated,
            unchanged: r.unchanged,
            removed: r.removed,
        }
    }
}

/// `[start, end)` in Unix milliseconds; both `None` is all time.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct Period {
    pub start_ms: Option<i64>,
    pub end_ms: Option<i64>,
}

impl From<Period> for tracks_store::Period {
    fn from(p: Period) -> Self {
        Self {
            start: p.start_ms,
            end: p.end_ms,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SourceFilter {
    All,
    AppleMusic,
    YourMusic,
}

impl From<SourceFilter> for tracks_store::SourceFilter {
    fn from(f: SourceFilter) -> Self {
        match f {
            SourceFilter::All => Self::All,
            SourceFilter::AppleMusic => Self::AppleMusic,
            SourceFilter::YourMusic => Self::YourMusic,
        }
    }
}

/// Everything, or one song, artist or album, by identity.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum Scope {
    All,
    Song { identity: String },
    Artist { identity: String },
    Album { identity: String },
}

impl From<Scope> for tracks_store::Scope {
    fn from(scope: Scope) -> Self {
        match scope {
            Scope::All => Self::All,
            Scope::Song { identity } => Self::Song(identity),
            Scope::Artist { identity } => Self::Artist(identity),
            Scope::Album { identity } => Self::Album(identity),
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SongStats {
    pub identity: String,
    pub title: String,
    pub artist_name: String,
    pub album_title: Option<String>,
    pub catalog_id: String,
    pub song_key: String,
    pub artwork_url: Option<String>,
    pub plays: u64,
    pub listen_ms: i64,
    pub first_played_ms: i64,
    pub last_played_ms: i64,
}

impl From<tracks_store::SongRow> for SongStats {
    fn from(r: tracks_store::SongRow) -> Self {
        Self {
            identity: r.identity,
            title: r.title,
            artist_name: r.artist_name,
            album_title: r.album_title,
            catalog_id: r.catalog_id,
            song_key: r.song_key,
            artwork_url: r.artwork_url,
            plays: r.plays,
            listen_ms: r.listen_ms,
            first_played_ms: r.first_at,
            last_played_ms: r.last_at,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ArtistStats {
    pub identity: String,
    pub name: String,
    pub plays: u64,
    pub song_count: u64,
    pub listen_ms: i64,
    pub artwork_url: Option<String>,
    pub first_played_ms: i64,
    pub last_played_ms: i64,
}

impl From<tracks_store::ArtistRow> for ArtistStats {
    fn from(r: tracks_store::ArtistRow) -> Self {
        Self {
            identity: r.identity,
            name: r.name,
            plays: r.plays,
            song_count: r.song_count,
            listen_ms: r.listen_ms,
            artwork_url: r.artwork_url,
            first_played_ms: r.first_at,
            last_played_ms: r.last_at,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AlbumStats {
    pub identity: String,
    pub title: String,
    pub artist_name: String,
    pub plays: u64,
    pub song_count: u64,
    pub listen_ms: i64,
    pub artwork_url: Option<String>,
}

impl From<tracks_store::AlbumRow> for AlbumStats {
    fn from(r: tracks_store::AlbumRow) -> Self {
        Self {
            identity: r.identity,
            title: r.title,
            artist_name: r.artist_name,
            plays: r.plays,
            song_count: r.song_count,
            listen_ms: r.listen_ms,
            artwork_url: r.artwork_url,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct RankedSong {
    pub song: SongStats,
    pub rank: u32,
    pub previous_rank: Option<u32>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct RankedArtist {
    pub artist: ArtistStats,
    pub rank: u32,
    pub previous_rank: Option<u32>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct RankedAlbum {
    pub album: AlbumStats,
    pub rank: u32,
    pub previous_rank: Option<u32>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SongChart {
    pub rows: Vec<RankedSong>,
    /// False when there was no previous period or nothing played in it.
    pub has_previous: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ArtistChart {
    pub rows: Vec<RankedArtist>,
    pub has_previous: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AlbumChart {
    pub rows: Vec<RankedAlbum>,
    pub has_previous: bool,
}

#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct PeriodTotals {
    pub plays: u64,
    pub listen_ms: i64,
    pub songs: u64,
    pub artists: u64,
    pub new_songs: u64,
    pub new_artists: u64,
}

#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct TimelineBucket {
    pub start_ms: i64,
    pub plays: u64,
    pub listen_ms: i64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Activity {
    /// 24 counts, midnight first, in the index's time zone.
    pub hours: Vec<u64>,
    /// 7 counts, Sunday first.
    pub weekdays: Vec<u64>,
    /// 7 × 24, Sunday's hours first.
    pub heat: Vec<u64>,
    pub radio: u64,
    pub on_demand: u64,
    pub imported: u64,
    pub last_fm: u64,
    pub days_with_plays: u64,
}

#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct Streak {
    pub current: u32,
    pub longest: u32,
    /// Local days since 1970-01-01 when the longest run ended.
    pub longest_end_day: Option<i64>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SearchResults {
    pub songs: Vec<SongStats>,
    pub artists: Vec<ArtistStats>,
    pub albums: Vec<AlbumStats>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Credit {
    pub name: String,
    pub identity: String,
}

// MARK: - The index

/// The play history as an index on disk, and every chart and figure read from it.
#[derive(Debug, uniffi::Object)]
pub struct HistoryIndex {
    store: tracks_store::Store,
}

#[uniffi::export]
impl HistoryIndex {
    /// Opens or creates the index at `path`. A damaged file is moved aside and recreated empty,
    /// which `needs_rebuild` then reports.
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Arc<Self>> {
        Ok(Arc::new(Self {
            store: tracks_store::Store::open(path)?,
        }))
    }

    /// An index in memory only, for previews and tests.
    #[uniffi::constructor]
    pub fn in_memory() -> Result<Arc<Self>> {
        Ok(Arc::new(Self {
            store: tracks_store::Store::open_in_memory()?,
        }))
    }

    /// The IANA time zone hours, weekdays and streaks are counted in.
    pub fn set_time_zone(&self, identifier: String) -> Result<()> {
        Ok(self.store.set_time_zone(&identifier)?)
    }

    /// Whether the host should send its whole history with `replace_all`.
    pub fn needs_rebuild(&self) -> Result<bool> {
        Ok(self.store.needs_rebuild()?)
    }

    /// The host's own sync position, saved with the last write.
    pub fn sync_marker(&self) -> Result<Option<String>> {
        Ok(self.store.sync_marker()?)
    }

    pub fn upsert(&self, plays: Vec<Play>, marker: Option<String>) -> Result<WriteReport> {
        let plays: Vec<_> = plays.into_iter().map(Into::into).collect();
        Ok(self.store.upsert(&plays, marker.as_deref())?.into())
    }

    pub fn remove(&self, ids: Vec<String>, marker: Option<String>) -> Result<WriteReport> {
        Ok(self.store.remove(&ids, marker.as_deref())?.into())
    }

    /// Brings the index to exactly `plays`, the host's whole history, writing only what
    /// changed. What to call at launch, and whenever the host only has a full snapshot.
    pub fn sync(&self, plays: Vec<Play>, marker: Option<String>) -> Result<WriteReport> {
        let plays: Vec<_> = plays.into_iter().map(Into::into).collect();
        Ok(self.store.sync(&plays, marker.as_deref())?.into())
    }

    pub fn replace_all(&self, plays: Vec<Play>, marker: Option<String>) -> Result<WriteReport> {
        let plays: Vec<_> = plays.into_iter().map(Into::into).collect();
        Ok(self.store.replace_all(&plays, marker.as_deref())?.into())
    }

    pub fn play_count(&self) -> Result<u64> {
        Ok(self.store.play_count()?)
    }

    /// Checkpoints and tidies the file; for when the app goes to the background.
    pub fn optimize(&self) -> Result<()> {
        Ok(self.store.optimize()?)
    }

    pub fn song_chart(
        &self,
        period: Period,
        previous: Option<Period>,
        filter: SourceFilter,
        limit: u32,
    ) -> Result<SongChart> {
        let chart = self.store.song_chart(
            period.into(),
            previous.map(Into::into),
            filter.into(),
            limit,
        )?;
        Ok(SongChart {
            has_previous: chart.has_previous,
            rows: chart
                .rows
                .into_iter()
                .map(|r| RankedSong {
                    song: r.item.into(),
                    rank: r.rank,
                    previous_rank: r.previous_rank,
                })
                .collect(),
        })
    }

    pub fn artist_chart(
        &self,
        period: Period,
        previous: Option<Period>,
        filter: SourceFilter,
        limit: u32,
    ) -> Result<ArtistChart> {
        let chart = self.store.artist_chart(
            period.into(),
            previous.map(Into::into),
            filter.into(),
            limit,
        )?;
        Ok(ArtistChart {
            has_previous: chart.has_previous,
            rows: chart
                .rows
                .into_iter()
                .map(|r| RankedArtist {
                    artist: r.item.into(),
                    rank: r.rank,
                    previous_rank: r.previous_rank,
                })
                .collect(),
        })
    }

    pub fn album_chart(
        &self,
        period: Period,
        previous: Option<Period>,
        filter: SourceFilter,
        limit: u32,
    ) -> Result<AlbumChart> {
        let chart = self.store.album_chart(
            period.into(),
            previous.map(Into::into),
            filter.into(),
            limit,
        )?;
        Ok(AlbumChart {
            has_previous: chart.has_previous,
            rows: chart
                .rows
                .into_iter()
                .map(|r| RankedAlbum {
                    album: r.item.into(),
                    rank: r.rank,
                    previous_rank: r.previous_rank,
                })
                .collect(),
        })
    }

    pub fn totals(&self, period: Period, filter: SourceFilter) -> Result<PeriodTotals> {
        let t = self.store.totals(period.into(), filter.into())?;
        Ok(PeriodTotals {
            plays: t.plays,
            listen_ms: t.listen_ms,
            songs: t.songs,
            artists: t.artists,
            new_songs: t.new_songs,
            new_artists: t.new_artists,
        })
    }

    /// Plays per bucket between consecutive `boundaries` (Unix milliseconds, ascending).
    pub fn timeline(
        &self,
        boundaries_ms: Vec<i64>,
        filter: SourceFilter,
        scope: Scope,
    ) -> Result<Vec<TimelineBucket>> {
        Ok(self
            .store
            .timeline(&boundaries_ms, filter.into(), &scope.into())?
            .into_iter()
            .map(|b| TimelineBucket {
                start_ms: b.start,
                plays: b.plays,
                listen_ms: b.listen_ms,
            })
            .collect())
    }

    pub fn activity(&self, period: Period, filter: SourceFilter, scope: Scope) -> Result<Activity> {
        let a = self
            .store
            .activity(period.into(), filter.into(), &scope.into())?;
        Ok(Activity {
            hours: a.hours.to_vec(),
            weekdays: a.weekdays.to_vec(),
            heat: a.heat.iter().map(|cell| cell.plays).collect(),
            radio: a.kinds[0],
            on_demand: a.kinds[1],
            imported: a.kinds[2],
            last_fm: a.kinds[3],
            days_with_plays: a.days_with_plays,
        })
    }

    pub fn streak(&self, now_ms: i64) -> Result<Streak> {
        let s = self.store.streak(now_ms)?;
        Ok(Streak {
            current: s.current,
            longest: s.longest,
            longest_end_day: s.longest_end_day,
        })
    }

    pub fn search(&self, text: String, limit: u32) -> Result<SearchResults> {
        let r = self.store.search(&text, limit)?;
        Ok(SearchResults {
            songs: r.songs.into_iter().map(Into::into).collect(),
            artists: r.artists.into_iter().map(Into::into).collect(),
            albums: r.albums.into_iter().map(Into::into).collect(),
        })
    }

    pub fn song(&self, identity: String) -> Result<Option<SongStats>> {
        Ok(self.store.song(&identity)?.map(Into::into))
    }

    pub fn song_rank(&self, identity: String) -> Result<Option<u32>> {
        Ok(self.store.song_rank(&identity)?)
    }

    pub fn artist(&self, identity: String) -> Result<Option<RankedArtist>> {
        Ok(self.store.artist(&identity)?.map(|r| RankedArtist {
            artist: r.item.into(),
            rank: r.rank,
            previous_rank: None,
        }))
    }

    pub fn album(&self, identity: String) -> Result<Option<RankedAlbum>> {
        Ok(self.store.album(&identity)?.map(|r| RankedAlbum {
            album: r.item.into(),
            rank: r.rank,
            previous_rank: None,
        }))
    }
}

// MARK: - Names

/// Trimmed, case- and accent-folded, as Foundation folds: the base of every identity.
#[uniffi::export]
pub fn folded_name(name: String) -> String {
    tracks_model::folded(&name)
}

/// A song's identity: folded title and artist.
#[uniffi::export]
pub fn song_identity(title: String, artist: String) -> String {
    tracks_model::song_key(&title, &artist)
}

/// Everyone a song credits, main artists first.
#[uniffi::export]
pub fn credits(artist: String, title: String) -> Vec<Credit> {
    tracks_model::credits_by_name(&artist, &title)
        .into_iter()
        .map(|c| Credit {
            name: c.name,
            identity: c.identity,
        })
        .collect()
}

/// The engine's version, to check the library and its bindings match.
#[uniffi::export]
pub fn engine_version() -> String {
    env!("CARGO_PKG_VERSION").to_owned()
}
