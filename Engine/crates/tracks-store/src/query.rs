//! Everything read from the index. Periods are half-open `[start, end)` in Unix
//! milliseconds, worked out by the host's own calendar (so first weekday, locale and the
//! user's calendar system stay native); `None` on both ends is all time.

use rustc_hash::{FxHashMap as HashMap, FxHashSet as HashSet};
use std::sync::Arc;

use rusqlite::{Connection, OptionalExtension, params};
use tracks_model::{is_near, search_folded};

use crate::directory::{Agg, Directory, Tally, all_time_aggregates};
use crate::time::LocalClock;
use crate::{Result, Store, StoreError, counter};

/// A span of time, or all of it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Period {
    pub start: Option<i64>,
    pub end: Option<i64>,
}

impl Period {
    pub const ALL_TIME: Self = Self {
        start: None,
        end: None,
    };

    pub const fn between(start: i64, end: i64) -> Self {
        Self {
            start: Some(start),
            end: Some(end),
        }
    }

    fn is_all_time(self) -> bool {
        self.start.is_none() && self.end.is_none()
    }

    fn bounds(self) -> (i64, i64) {
        (self.start.unwrap_or(i64::MIN), self.end.unwrap_or(i64::MAX))
    }
}

/// Which plays count, when the person has asked to see Apple Music and their own music apart.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SourceFilter {
    #[default]
    All,
    AppleMusic,
    YourMusic,
}

impl SourceFilter {
    /// The `source` values to match, as a SQL range: `source BETWEEN lo AND hi`.
    fn range(self) -> (u8, u8) {
        match self {
            Self::All => (0, u8::MAX),
            Self::AppleMusic => (0, 0),
            Self::YourMusic => (1, 1),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct SongRow {
    pub identity: String,
    pub title: String,
    pub artist_name: String,
    pub album_title: Option<String>,
    pub catalog_id: String,
    pub song_key: String,
    pub artwork_url: Option<String>,
    pub plays: u64,
    pub listen_ms: i64,
    pub first_at: i64,
    pub last_at: i64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ArtistRow {
    pub identity: String,
    pub name: String,
    pub plays: u64,
    pub song_count: u64,
    pub listen_ms: i64,
    pub artwork_url: Option<String>,
    pub first_at: i64,
    pub last_at: i64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct AlbumRow {
    pub identity: String,
    pub title: String,
    pub artist_name: String,
    pub plays: u64,
    pub song_count: u64,
    pub listen_ms: i64,
    pub artwork_url: Option<String>,
}

/// A chart position, with where the item stood over the whole previous period.
#[derive(Debug, Clone, PartialEq)]
pub struct ChartRow<T> {
    pub item: T,
    /// Competition rank: 1, 2, 2, 4.
    pub rank: u32,
    pub previous_rank: Option<u32>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Chart<T> {
    pub rows: Vec<ChartRow<T>>,
    /// False when there was no previous period or nothing played in it, so every row would
    /// otherwise read as new.
    pub has_previous: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct PeriodTotals {
    pub plays: u64,
    pub listen_ms: i64,
    pub songs: u64,
    pub artists: u64,
    /// Songs and artists first heard in the period.
    pub new_songs: u64,
    pub new_artists: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TimelineBucket {
    pub start: i64,
    pub plays: u64,
    pub listen_ms: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HeatCell {
    /// 0 is Sunday.
    pub weekday: u8,
    pub hour: u8,
    pub plays: u64,
}

/// When in the day and week the plays of a period fell, and how they were played.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActivitySummary {
    pub hours: [u64; 24],
    /// Sunday first.
    pub weekdays: [u64; 7],
    /// Weekday-major, 7 × 24.
    pub heat: Vec<HeatCell>,
    /// Indexed by `PlayKind as usize`.
    pub kinds: [u64; 4],
    pub days_with_plays: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Streak {
    /// Consecutive local days with a play, ending today or yesterday.
    pub current: u32,
    pub longest: u32,
    /// Local day number (days since 1970-01-01) the longest run ended.
    pub longest_end_day: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct SearchResults {
    pub songs: Vec<SongRow>,
    pub artists: Vec<ArtistRow>,
    pub albums: Vec<AlbumRow>,
}

impl SearchResults {
    pub fn is_empty(&self) -> bool {
        self.songs.is_empty() && self.artists.is_empty() && self.albums.is_empty()
    }
}

/// Per-song-and-album sums for a period: the one shape every chart is built from.
/// Per-song-and-album sums for a period: the one shape every chart is built from. All time
/// reads the rollup; anything else is one contiguous read of the time-clustered plays.
fn aggregates(conn: &Connection, period: Period, filter: SourceFilter) -> Result<Vec<Agg>> {
    if period.is_all_time() && filter == SourceFilter::All {
        return all_time_aggregates(conn);
    }
    let (start, end) = period.bounds();
    let (lo, hi) = filter.range();
    let mut sums: HashMap<(i64, i64), Agg> = HashMap::default();
    let mut stmt = conn.prepare_cached(
        "SELECT song_id, album_id, listen_ms, played_at FROM plays
         WHERE played_at >= ?1 AND played_at < ?2 AND source BETWEEN ?3 AND ?4 ORDER BY played_at",
    )?;
    let mut rows = stmt.query(params![start, end, lo, hi])?;
    while let Some(row) = rows.next()? {
        let (song, album, listen_ms, at): (i64, i64, i64, i64) =
            (row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?);
        let agg = sums.entry((song, album)).or_insert(Agg {
            song,
            album,
            plays: 0,
            listen_ms: 0,
            first_at: at,
            last_at: at,
        });
        agg.plays += 1;
        agg.listen_ms += listen_ms;
        // Rows arrive in time order.
        agg.last_at = at;
    }
    Ok(sums.into_values().collect())
}

/// Competition rank of a count among counts sorted high to low: 1 + how many are higher.
fn rank_in(sorted_desc: &[u64], count: u64) -> u32 {
    sorted_desc.partition_point(|&c| c > count) as u32 + 1
}

/// Ranks in the previous period by id, or `None` when nothing played then.
fn previous_ranks(counts: HashMap<i64, u64>) -> Option<HashMap<i64, u32>> {
    if counts.is_empty() {
        return None;
    }
    let mut sorted: Vec<u64> = counts.values().copied().collect();
    sorted.sort_unstable_by(|a, b| b.cmp(a));
    Some(
        counts
            .into_iter()
            .map(|(id, count)| (id, rank_in(&sorted, count)))
            .collect(),
    )
}

fn per_song(aggs: &[Agg]) -> HashMap<i64, Agg> {
    let mut songs: HashMap<i64, Agg> =
        HashMap::with_capacity_and_hasher(aggs.len(), rustc_hash::FxBuildHasher);
    for agg in aggs {
        let song = songs.entry(agg.song).or_insert(Agg {
            song: agg.song,
            first_at: i64::MAX,
            last_at: i64::MIN,
            ..Agg::default()
        });
        song.plays += agg.plays;
        song.listen_ms += agg.listen_ms;
        song.first_at = song.first_at.min(agg.first_at);
        song.last_at = song.last_at.max(agg.last_at);
    }
    songs
}

impl Store {
    /// The shared lookups for the current history, built on first use after each write.
    fn directory(&self, conn: &Connection) -> Result<Arc<Directory>> {
        // Reads run in one snapshot, so these counters match the data this read sees.
        let generation = counter(conn, "generation")?;
        let catalog_generation = counter(conn, "catalog_generation")?;
        let previous = self
            .directory
            .lock()
            .map_err(|_| StoreError::Closed)?
            .clone();
        if let Some(directory) = &previous
            && directory.generation == generation
        {
            return Ok(Arc::clone(directory));
        }
        let built = Directory::build(conn, generation, catalog_generation, previous.as_deref())?;
        let mut cache = self.directory.lock().map_err(|_| StoreError::Closed)?;
        // Never replace a newer one another read built meanwhile.
        if cache
            .as_ref()
            .is_none_or(|cached| cached.generation <= generation)
        {
            *cache = Some(Arc::clone(&built));
        }
        Ok(built)
    }

    /// Top songs of a period, most played first; ties go to the most recent, then by title.
    pub fn song_chart(
        &self,
        period: Period,
        previous: Option<Period>,
        filter: SourceFilter,
        limit: u32,
    ) -> Result<Chart<SongRow>> {
        self.pool.read(|conn| {
            let mut fetch =
                conn.prepare_cached(&format!("SELECT {SONG_COLUMNS} FROM songs WHERE id = ?1"))?;
            let rows: Vec<(SongRow, u32)> = if period.is_all_time() && filter == SourceFilter::All {
                // The rollup's index is already in chart order.
                let mut stmt = conn.prepare_cached(&format!(
                    "SELECT {SONG_COLUMNS}, plays, listen_ms, first_at, last_at FROM songs
                     WHERE plays > 0 ORDER BY plays DESC, last_at DESC, title, identity LIMIT ?1"
                ))?;
                let songs = stmt
                    .query_map([limit], song_row)?
                    .collect::<Result<Vec<_>, _>>()?;
                let ranks = competition_ranks(songs.iter().map(|s| s.plays));
                songs.into_iter().zip(ranks).collect()
            } else {
                let mut songs: Vec<Agg> = per_song(&aggregates(conn, period, filter)?)
                    .into_values()
                    .collect();
                songs.sort_unstable_by(|a, b| {
                    (b.plays, b.last_at, a.song).cmp(&(a.plays, a.last_at, b.song))
                });
                let counts: Vec<u64> = songs.iter().map(|s| s.plays).collect();
                // Only rows tied with the last one shown can need their titles to settle the
                // order, so look up just those rather than every song of the period.
                let cut = (limit as usize).min(songs.len());
                let boundary = cut
                    .checked_sub(1)
                    .map(|i| (songs[i].plays, songs[i].last_at));
                let end = songs
                    .iter()
                    .skip(cut)
                    .position(|s| Some((s.plays, s.last_at)) != boundary)
                    .map_or(songs.len(), |n| cut + n);
                let mut shown = Vec::with_capacity(end);
                for agg in &songs[..end] {
                    let mut row = fetch.query_row([agg.song], song_display)?;
                    row.plays = agg.plays;
                    row.listen_ms = agg.listen_ms;
                    row.first_at = agg.first_at;
                    row.last_at = agg.last_at;
                    shown.push((agg.song, row));
                }
                shown.sort_by(|(_, a), (_, b)| {
                    (b.plays, b.last_at)
                        .cmp(&(a.plays, a.last_at))
                        .then_with(|| a.title.cmp(&b.title))
                        .then_with(|| a.identity.cmp(&b.identity))
                });
                shown.truncate(limit as usize);
                let previous = Self::previous_song_counts(conn, period, previous, filter)?;
                return Ok(Chart {
                    has_previous: previous.is_some(),
                    rows: shown
                        .into_iter()
                        .map(|(id, item)| ChartRow {
                            rank: rank_in(&counts, item.plays),
                            previous_rank: previous.as_ref().and_then(|p| p.get(&id).copied()),
                            item,
                        })
                        .collect(),
                });
            };
            Ok(Chart {
                has_previous: false,
                rows: rows
                    .into_iter()
                    .map(|(item, rank)| ChartRow {
                        item,
                        rank,
                        previous_rank: None,
                    })
                    .collect(),
            })
        })
    }

    fn previous_song_counts(
        conn: &Connection,
        period: Period,
        previous: Option<Period>,
        filter: SourceFilter,
    ) -> Result<Option<HashMap<i64, u32>>> {
        let Some(previous) = previous.filter(|_| !period.is_all_time()) else {
            return Ok(None);
        };
        let counts = per_song(&aggregates(conn, previous, filter)?)
            .into_iter()
            .map(|(id, agg)| (id, agg.plays))
            .collect();
        Ok(previous_ranks(counts))
    }

    /// Top artists of a period. A play counts in full for everyone it credits.
    pub fn artist_chart(
        &self,
        period: Period,
        previous: Option<Period>,
        filter: SourceFilter,
        limit: u32,
    ) -> Result<Chart<ArtistRow>> {
        self.pool.read(|conn| {
            let directory = self.directory(conn)?;
            let tally = if period.is_all_time() && filter == SourceFilter::All {
                directory.all_time_artists.clone()
            } else {
                directory.artist_tally(&aggregates(conn, period, filter)?)
            };
            let previous = match previous.filter(|_| !period.is_all_time()) {
                Some(p) => previous_ranks(
                    directory
                        .artist_tally(&aggregates(conn, p, filter)?)
                        .into_iter()
                        .map(|t| (t.id, t.plays))
                        .collect(),
                ),
                None => None,
            };
            let counts: Vec<u64> = tally.iter().map(|t| t.plays).collect();
            let rows = tally
                .iter()
                .take(limit as usize)
                .map(|t| {
                    Ok(ChartRow {
                        item: artist_row(conn, &directory, t)?,
                        rank: rank_in(&counts, t.plays),
                        previous_rank: previous.as_ref().and_then(|p| p.get(&t.id).copied()),
                    })
                })
                .collect::<Result<Vec<_>>>()?;
            Ok(Chart {
                rows,
                has_previous: previous.is_some(),
            })
        })
    }

    /// Top albums of a period. Plays without an album don't count.
    pub fn album_chart(
        &self,
        period: Period,
        previous: Option<Period>,
        filter: SourceFilter,
        limit: u32,
    ) -> Result<Chart<AlbumRow>> {
        self.pool.read(|conn| {
            let directory = self.directory(conn)?;
            let tally = if period.is_all_time() && filter == SourceFilter::All {
                directory.all_time_albums.clone()
            } else {
                directory.album_tally(&aggregates(conn, period, filter)?)
            };
            let previous = match previous.filter(|_| !period.is_all_time()) {
                Some(p) => previous_ranks(
                    directory
                        .album_tally(&aggregates(conn, p, filter)?)
                        .into_iter()
                        .map(|t| (t.id, t.plays))
                        .collect(),
                ),
                None => None,
            };
            let counts: Vec<u64> = tally.iter().map(|t| t.plays).collect();
            let rows = tally
                .iter()
                .take(limit as usize)
                .map(|t| {
                    Ok(ChartRow {
                        item: album_row(conn, &directory, t)?,
                        rank: rank_in(&counts, t.plays),
                        previous_rank: previous.as_ref().and_then(|p| p.get(&t.id).copied()),
                    })
                })
                .collect::<Result<Vec<_>>>()?;
            Ok(Chart {
                rows,
                has_previous: previous.is_some(),
            })
        })
    }

    /// Plays, time and variety in a period.
    pub fn totals(&self, period: Period, filter: SourceFilter) -> Result<PeriodTotals> {
        self.pool.read(|conn| {
            let directory = self.directory(conn)?;
            let aggs = aggregates(conn, period, filter)?;
            let mut totals = PeriodTotals::default();
            let mut songs = HashSet::default();
            let mut artists = HashSet::default();
            for agg in &aggs {
                totals.plays += agg.plays;
                totals.listen_ms += agg.listen_ms;
                if songs.insert(agg.song) {
                    artists.extend(
                        directory
                            .song_artists
                            .get(&agg.song)
                            .into_iter()
                            .flatten()
                            .copied(),
                    );
                }
            }
            totals.songs = songs.len() as u64;
            totals.artists = artists.len() as u64;
            // First heard is a fact about the whole history, whatever the period.
            let (start, end) = period.bounds();
            totals.new_artists = directory
                .artist_first
                .values()
                .filter(|&&first| first >= start && first < end)
                .count() as u64;
            totals.new_songs = conn.query_row(
                "SELECT COUNT(*) FROM songs WHERE first_at >= ?1 AND first_at < ?2",
                params![start, end],
                |r| r.get::<_, i64>(0),
            )? as u64;
            Ok(totals)
        })
    }

    /// Plays and listening per bucket. `boundaries` are ascending bucket starts from the
    /// host's calendar, with one more at the end closing the last bucket.
    pub fn timeline(
        &self,
        boundaries: &[i64],
        filter: SourceFilter,
        scope: &Scope,
    ) -> Result<Vec<TimelineBucket>> {
        let mut buckets: Vec<TimelineBucket> = boundaries
            .windows(2)
            .map(|pair| TimelineBucket {
                start: pair[0],
                plays: 0,
                listen_ms: 0,
            })
            .collect();
        let (Some(&first), Some(&last)) = (boundaries.first(), boundaries.last()) else {
            return Ok(buckets);
        };
        let mut index = 0;
        self.pool.read(|conn| {
            scan_plays(
                conn,
                Period::between(first, last),
                filter,
                scope,
                |at, listen_ms, _, _| {
                    // Plays arrive in time order, so the bucket only ever moves forward.
                    while index + 1 < boundaries.len() - 1 && boundaries[index + 1] <= at {
                        index += 1;
                    }
                    if let Some(bucket) = buckets.get_mut(index) {
                        bucket.plays += 1;
                        bucket.listen_ms += listen_ms;
                    }
                },
            )
        })?;
        Ok(buckets)
    }

    /// Hours, weekdays, the week-by-hour heat map and kinds of play for a period.
    pub fn activity(
        &self,
        period: Period,
        filter: SourceFilter,
        scope: &Scope,
    ) -> Result<ActivitySummary> {
        let mut clock = LocalClock::new(self.zone());
        let mut summary = ActivitySummary {
            hours: [0; 24],
            weekdays: [0; 7],
            heat: Vec::new(),
            kinds: [0; 4],
            days_with_plays: 0,
        };
        let mut heat = [[0u64; 24]; 7];
        let mut last_day = None;
        self.pool.read(|conn| {
            scan_plays(conn, period, filter, scope, |at, _, kind, _| {
                if let Some(slot) = summary.kinds.get_mut(kind as usize) {
                    *slot += 1;
                }
                // Imports are dated when found, so their hour means nothing.
                if kind == tracks_model::PlayKind::Imported as u8 {
                    return;
                }
                let local = clock.local(at);
                summary.hours[local.hour as usize] += 1;
                summary.weekdays[local.weekday as usize] += 1;
                heat[local.weekday as usize][local.hour as usize] += 1;
                if last_day != Some(local.day) {
                    summary.days_with_plays += 1;
                    last_day = Some(local.day);
                }
            })
        })?;
        summary.heat = (0..7u8)
            .flat_map(|weekday| (0..24u8).map(move |hour| (weekday, hour)))
            .map(|(weekday, hour)| HeatCell {
                weekday,
                hour,
                plays: heat[weekday as usize][hour as usize],
            })
            .collect();
        Ok(summary)
    }

    /// Runs of consecutive local days with a play, counted at `now_ms`.
    pub fn streak(&self, now_ms: i64) -> Result<Streak> {
        let mut clock = LocalClock::new(self.zone());
        let mut days: Vec<i64> = Vec::new();
        self.pool.read(|conn| {
            // Only a play's time is needed, so the primary key alone answers this.
            let mut stmt = conn
                .prepare_cached("SELECT played_at FROM plays WHERE kind != 2 ORDER BY played_at")?;
            let mut rows = stmt.query([])?;
            while let Some(row) = rows.next()? {
                let day = clock.local(row.get(0)?).day;
                if days.last() != Some(&day) {
                    days.push(day);
                }
            }
            Ok(())
        })?;
        let mut streak = Streak::default();
        let mut run = 0u32;
        for (index, &day) in days.iter().enumerate() {
            run = if index > 0 && days[index - 1] + 1 == day {
                run + 1
            } else {
                1
            };
            if run > streak.longest {
                streak.longest = run;
                streak.longest_end_day = Some(day);
            }
        }
        let today = clock.local(now_ms).day;
        if let Some(&last) = days.last()
            && (last == today || last == today - 1)
        {
            streak.current = run;
        }
        Ok(streak)
    }

    /// Songs, artists and albums whose names hold every typed word, most played first. When
    /// nothing matches exactly, words a letter off match too.
    pub fn search(&self, text: &str, limit: u32) -> Result<SearchResults> {
        let query = search_folded(text);
        let words: Vec<&str> = query.split_whitespace().collect();
        if words.is_empty() || limit == 0 {
            return Ok(SearchResults::default());
        }
        self.pool.read(|conn| {
            let directory = self.directory(conn)?;
            let exact = |hay: &str| words.iter().all(|w| hay.contains(w));
            let results = search_with(conn, &directory, limit, &exact)?;
            if !results.is_empty() {
                return Ok(results);
            }
            let near = |hay: &str| {
                words
                    .iter()
                    .all(|w| hay.contains(w) || hay.split_whitespace().any(|word| is_near(w, word)))
            };
            search_with(conn, &directory, limit, &near)
        })
    }

    /// One song's all-time figures, by identity.
    pub fn song(&self, identity: &str) -> Result<Option<SongRow>> {
        self.pool.read(|conn| {
            let mut stmt = conn.prepare_cached(&format!(
                "SELECT {SONG_COLUMNS}, plays, listen_ms, first_at, last_at FROM songs WHERE identity = ?1 AND plays > 0"
            ))?;
            Ok(stmt.query_row([identity], song_row).optional()?)
        })
    }

    /// A song's all-time rank among songs.
    pub fn song_rank(&self, identity: &str) -> Result<Option<u32>> {
        self.pool.read(|conn| {
            let plays: Option<i64> = conn
                .query_row(
                    "SELECT plays FROM songs WHERE identity = ?1 AND plays > 0",
                    [identity],
                    |r| r.get(0),
                )
                .optional()?;
            let Some(plays) = plays else { return Ok(None) };
            let above: i64 = conn.query_row(
                "SELECT COUNT(*) FROM songs WHERE plays > ?1",
                [plays],
                |r| r.get(0),
            )?;
            Ok(Some(above as u32 + 1))
        })
    }

    /// An artist's all-time figures and rank.
    pub fn artist(&self, identity: &str) -> Result<Option<ChartRow<ArtistRow>>> {
        self.pool.read(|conn| {
            let directory = self.directory(conn)?;
            let counts: Vec<u64> = directory.all_time_artists.iter().map(|t| t.plays).collect();
            let Some(tally) = directory
                .all_time_artists
                .iter()
                .find(|t| directory.artists[&t.id].identity == identity)
            else {
                return Ok(None);
            };
            Ok(Some(ChartRow {
                item: artist_row(conn, &directory, tally)?,
                rank: rank_in(&counts, tally.plays),
                previous_rank: None,
            }))
        })
    }

    /// An album's all-time figures and rank.
    pub fn album(&self, identity: &str) -> Result<Option<ChartRow<AlbumRow>>> {
        self.pool.read(|conn| {
            let directory = self.directory(conn)?;
            let counts: Vec<u64> = directory.all_time_albums.iter().map(|t| t.plays).collect();
            let Some(tally) = directory
                .all_time_albums
                .iter()
                .find(|t| directory.albums[&t.id].identity == identity)
            else {
                return Ok(None);
            };
            Ok(Some(ChartRow {
                item: album_row(conn, &directory, tally)?,
                rank: rank_in(&counts, tally.plays),
                previous_rank: None,
            }))
        })
    }
}

fn cover(conn: &Connection, song: i64) -> Result<Option<String>> {
    let mut stmt = conn.prepare_cached("SELECT artwork_url FROM songs WHERE id = ?1")?;
    Ok(stmt
        .query_row([song], |r| r.get::<_, Option<String>>(0))
        .optional()?
        .flatten())
}

fn artist_row(conn: &Connection, directory: &Directory, tally: &Tally) -> Result<ArtistRow> {
    let info = &directory.artists[&tally.id];
    Ok(ArtistRow {
        identity: info.identity.clone(),
        name: info.name.clone(),
        plays: tally.plays,
        song_count: tally.songs,
        listen_ms: tally.listen_ms,
        artwork_url: cover(conn, tally.cover_song)?,
        first_at: tally.first_at,
        last_at: tally.last_at,
    })
}

fn album_row(conn: &Connection, directory: &Directory, tally: &Tally) -> Result<AlbumRow> {
    let info = &directory.albums[&tally.id];
    Ok(AlbumRow {
        identity: info.identity.clone(),
        title: info.title.clone(),
        artist_name: info.artist.clone(),
        plays: tally.plays,
        song_count: tally.songs,
        listen_ms: tally.listen_ms,
        artwork_url: cover(conn, tally.cover_song)?,
    })
}

/// Competition ranks for counts already sorted high to low.
fn competition_ranks(counts: impl IntoIterator<Item = u64>) -> Vec<u32> {
    let mut ranks: Vec<u32> = Vec::new();
    let mut previous = None;
    for (index, count) in counts.into_iter().enumerate() {
        let rank = match (previous, ranks.last()) {
            (Some(p), Some(&last)) if p == count => last,
            _ => index as u32 + 1,
        };
        ranks.push(rank);
        previous = Some(count);
    }
    ranks
}

fn search_with(
    conn: &Connection,
    directory: &Directory,
    limit: u32,
    matches: &dyn Fn(&str) -> bool,
) -> Result<SearchResults> {
    let mut results = SearchResults::default();
    let limit = limit as usize;

    // Walks songs in chart order (the `songs_rank` index) and stops at the limit, so a common
    // word costs a few rows and only a rare one reads them all.
    let mut stmt = conn.prepare_cached(&format!(
        "SELECT {SONG_COLUMNS}, plays, listen_ms, first_at, last_at, search_text FROM songs
         WHERE plays > 0 ORDER BY plays DESC, last_at DESC, title, identity"
    ))?;
    let mut rows = stmt.query([])?;
    while let Some(row) = rows.next()? {
        let text: String = row.get(11)?;
        if matches(&text) {
            results.songs.push(song_row(row)?);
            if results.songs.len() == limit {
                break;
            }
        }
    }
    results.artists = directory
        .all_time_artists
        .iter()
        .filter(|t| matches(&directory.artists[&t.id].search))
        .take(limit)
        .map(|t| artist_row(conn, directory, t))
        .collect::<Result<_>>()?;
    results.albums = directory
        .all_time_albums
        .iter()
        .filter(|t| matches(&directory.albums[&t.id].search))
        .take(limit)
        .map(|t| album_row(conn, directory, t))
        .collect::<Result<_>>()?;
    Ok(results)
}

/// A song's names and ids, with figures left for the caller.
fn song_display(row: &rusqlite::Row<'_>) -> rusqlite::Result<SongRow> {
    Ok(SongRow {
        identity: row.get(0)?,
        title: row.get(1)?,
        artist_name: row.get(2)?,
        album_title: row.get(3)?,
        catalog_id: row.get(4)?,
        song_key: row.get(5)?,
        artwork_url: row.get(6)?,
        plays: 0,
        listen_ms: 0,
        first_at: 0,
        last_at: 0,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn competition_ranks_share_places_and_skip_after() {
        assert_eq!(competition_ranks([9, 7, 7, 7, 3]), vec![1, 2, 2, 2, 5]);
        assert_eq!(competition_ranks([]), Vec::<u32>::new());
        let sorted = [9, 7, 7, 7, 3];
        assert_eq!([9, 7, 3].map(|c| rank_in(&sorted, c)), [1, 2, 5]);
    }

    #[test]
    fn previous_ranks_follow_counts() {
        let ranks = previous_ranks(HashMap::from_iter([(1, 5), (2, 5), (3, 1)])).expect("ranks");
        assert_eq!((ranks[&1], ranks[&2], ranks[&3]), (1, 1, 3));
        assert!(previous_ranks(HashMap::default()).is_none());
    }
}
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum Scope {
    #[default]
    All,
    Song(String),
    Artist(String),
    Album(String),
}

/// Walks the plays of a period in time order: (time, listening, kind, song).
fn scan_plays(
    conn: &Connection,
    period: Period,
    filter: SourceFilter,
    scope: &Scope,
    mut visit: impl FnMut(i64, i64, u8, i64),
) -> Result<()> {
    let (start, end) = period.bounds();
    let (lo, hi) = filter.range();
    let mut emit = |row: &rusqlite::Row<'_>| -> rusqlite::Result<()> {
        visit(row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?);
        Ok(())
    };
    match scope {
        Scope::All => {
            let mut stmt = conn.prepare_cached(
                "SELECT played_at, listen_ms, kind, song_id FROM plays
                 WHERE played_at >= ?1 AND played_at < ?2 AND source BETWEEN ?3 AND ?4 ORDER BY played_at",
            )?;
            let mut rows = stmt.query(params![start, end, lo, hi])?;
            while let Some(row) = rows.next()? {
                emit(row)?;
            }
        }
        Scope::Song(identity) => {
            let mut stmt = conn.prepare_cached(
                "SELECT p.played_at, p.listen_ms, p.kind, p.song_id FROM songs s JOIN plays p ON p.song_id = s.id
                 WHERE s.identity = ?5 AND p.played_at >= ?1 AND p.played_at < ?2 AND p.source BETWEEN ?3 AND ?4
                 ORDER BY p.played_at",
            )?;
            let mut rows = stmt.query(params![start, end, lo, hi, identity])?;
            while let Some(row) = rows.next()? {
                emit(row)?;
            }
        }
        Scope::Artist(identity) => {
            let mut stmt = conn.prepare_cached(
                "SELECT p.played_at, p.listen_ms, p.kind, p.song_id FROM artists a
                 JOIN song_artists sa ON sa.artist_id = a.id JOIN plays p ON p.song_id = sa.song_id
                 WHERE a.identity = ?5 AND p.played_at >= ?1 AND p.played_at < ?2 AND p.source BETWEEN ?3 AND ?4
                 ORDER BY p.played_at",
            )?;
            let mut rows = stmt.query(params![start, end, lo, hi, identity])?;
            while let Some(row) = rows.next()? {
                emit(row)?;
            }
        }
        Scope::Album(identity) => {
            let mut stmt = conn.prepare_cached(
                "SELECT p.played_at, p.listen_ms, p.kind, p.song_id FROM albums al JOIN plays p ON p.album_id = al.id
                 WHERE al.identity = ?5 AND p.played_at >= ?1 AND p.played_at < ?2 AND p.source BETWEEN ?3 AND ?4
                 ORDER BY p.played_at",
            )?;
            let mut rows = stmt.query(params![start, end, lo, hi, identity])?;
            while let Some(row) = rows.next()? {
                emit(row)?;
            }
        }
    }
    Ok(())
}

const SONG_COLUMNS: &str =
    "identity, title, artist_name, album_title, catalog_id, song_key, artwork_url";

fn song_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<SongRow> {
    Ok(SongRow {
        identity: row.get(0)?,
        title: row.get(1)?,
        artist_name: row.get(2)?,
        album_title: row.get(3)?,
        catalog_id: row.get(4)?,
        song_key: row.get(5)?,
        artwork_url: row.get(6)?,
        plays: row.get::<_, i64>(7)? as u64,
        listen_ms: row.get(8)?,
        first_at: row.get::<_, Option<i64>>(9)?.unwrap_or_default(),
        last_at: row.get::<_, Option<i64>>(10)?.unwrap_or_default(),
    })
}
