//! What every read needs that only changes when the history does: who each song credits,
//! when each artist was first heard, and the all-time artist and album charts. Built once
//! per write, on the first read that needs it, and shared by every read until the next write.

use rustc_hash::FxHashMap as HashMap;
use std::sync::Arc;

use rusqlite::Connection;
use tracks_model::search_folded;

use crate::Result;

#[derive(Debug, Clone, Copy, Default)]
pub struct Agg {
    pub song: i64,
    pub album: i64,
    pub plays: u64,
    pub listen_ms: i64,
    pub first_at: i64,
    pub last_at: i64,
}

#[derive(Debug, Clone)]
pub struct ArtistInfo {
    pub identity: String,
    pub name: String,
    /// The name as search compares it.
    pub search: String,
}

#[derive(Debug, Clone)]
pub struct AlbumInfo {
    pub identity: String,
    pub title: String,
    pub artist: String,
    pub search: String,
}

/// An artist or album tallied over some plays, before its cover is looked up.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Tally {
    pub id: i64,
    pub plays: u64,
    pub listen_ms: i64,
    pub songs: u64,
    pub first_at: i64,
    pub last_at: i64,
    /// The song whose cover stands for the artist or album.
    pub cover_song: i64,
}

/// Who each song credits, the names and when each artist was first heard. Only changes when
/// a song, artist or album comes or goes, or an artist's best spelling changes.
#[derive(Debug)]
pub struct Catalog {
    pub generation: u64,
    pub song_artists: HashMap<i64, Vec<i64>>,
    pub artist_first: HashMap<i64, i64>,
    pub artists: HashMap<i64, ArtistInfo>,
    pub albums: HashMap<i64, AlbumInfo>,
}

/// The catalog plus the all-time tallies, which change with every play.
#[derive(Debug)]
pub struct Directory {
    pub generation: u64,
    pub catalog: Arc<Catalog>,
    /// All time, in chart order.
    pub all_time_artists: Vec<Tally>,
    pub all_time_albums: Vec<Tally>,
}

impl std::ops::Deref for Directory {
    type Target = Catalog;

    fn deref(&self) -> &Catalog {
        &self.catalog
    }
}

impl Directory {
    /// Builds the tallies, reusing `previous`'s catalog when no names changed since.
    pub fn build(
        conn: &Connection,
        generation: u64,
        catalog_generation: u64,
        previous: Option<&Self>,
    ) -> Result<Arc<Self>> {
        let catalog = match previous {
            Some(previous) if previous.catalog.generation == catalog_generation => {
                Arc::clone(&previous.catalog)
            }
            _ => Arc::new(Catalog::build(conn, catalog_generation)?),
        };
        let all_time = all_time_aggregates(conn)?;
        Ok(Arc::new(Self {
            generation,
            all_time_artists: catalog.artist_tally(&all_time),
            all_time_albums: catalog.album_tally(&all_time),
            catalog,
        }))
    }
}

impl Catalog {
    fn build(conn: &Connection, generation: u64) -> Result<Self> {
        let mut song_artists: HashMap<i64, Vec<i64>> = HashMap::default();
        let mut artist_first: HashMap<i64, i64> = HashMap::default();
        let mut stmt = conn.prepare_cached(
            "SELECT sa.song_id, sa.artist_id, s.first_at FROM song_artists sa JOIN songs s ON s.id = sa.song_id",
        )?;
        let mut rows = stmt.query([])?;
        while let Some(row) = rows.next()? {
            let (song, artist): (i64, i64) = (row.get(0)?, row.get(1)?);
            song_artists.entry(song).or_default().push(artist);
            if let Some(first) = row.get::<_, Option<i64>>(2)? {
                artist_first
                    .entry(artist)
                    .and_modify(|f| *f = (*f).min(first))
                    .or_insert(first);
            }
        }

        let mut artists = HashMap::default();
        let mut stmt = conn.prepare_cached("SELECT id, identity, name FROM artists")?;
        let mut rows = stmt.query([])?;
        while let Some(row) = rows.next()? {
            let name: String = row.get(2)?;
            artists.insert(
                row.get(0)?,
                ArtistInfo {
                    identity: row.get(1)?,
                    search: search_folded(&name),
                    name,
                },
            );
        }

        let mut albums = HashMap::default();
        let mut stmt = conn.prepare_cached("SELECT id, identity, title, artist FROM albums")?;
        let mut rows = stmt.query([])?;
        while let Some(row) = rows.next()? {
            let (title, artist): (String, String) = (row.get(2)?, row.get(3)?);
            albums.insert(
                row.get(0)?,
                AlbumInfo {
                    identity: row.get(1)?,
                    search: search_folded(&format!("{title} {artist}")),
                    title,
                    artist,
                },
            );
        }
        Ok(Self {
            generation,
            song_artists,
            artist_first,
            artists,
            albums,
        })
    }

    /// Artists in chart order: most played, then most listened, then by name. A play counts
    /// in full for everyone it credits.
    pub fn artist_tally(&self, aggs: &[Agg]) -> Vec<Tally> {
        let mut per_song: HashMap<i64, Agg> =
            HashMap::with_capacity_and_hasher(aggs.len(), rustc_hash::FxBuildHasher);
        for agg in aggs {
            let song = per_song.entry(agg.song).or_insert(Agg {
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
        let mut tallies: HashMap<i64, (Tally, (u64, i64))> = HashMap::default();
        for song in per_song.values() {
            for &artist in self
                .song_artists
                .get(&song.song)
                .map_or(&[][..], Vec::as_slice)
            {
                let (tally, favourite) = tallies.entry(artist).or_insert((
                    Tally {
                        id: artist,
                        plays: 0,
                        listen_ms: 0,
                        songs: 0,
                        first_at: i64::MAX,
                        last_at: i64::MIN,
                        cover_song: song.song,
                    },
                    (0, i64::MIN),
                ));
                tally.plays += song.plays;
                tally.listen_ms += song.listen_ms;
                tally.songs += 1;
                tally.first_at = tally.first_at.min(song.first_at);
                tally.last_at = tally.last_at.max(song.last_at);
                if (song.plays, song.last_at) > *favourite {
                    *favourite = (song.plays, song.last_at);
                    tally.cover_song = song.song;
                }
            }
        }
        let mut out: Vec<Tally> = tallies
            .into_values()
            .map(|(tally, _)| tally)
            .filter(|t| self.artists.contains_key(&t.id))
            .collect();
        out.sort_by(|a, b| {
            (b.plays, b.listen_ms)
                .cmp(&(a.plays, a.listen_ms))
                .then_with(|| {
                    let (x, y) = (&self.artists[&a.id], &self.artists[&b.id]);
                    x.name
                        .cmp(&y.name)
                        .then_with(|| x.identity.cmp(&y.identity))
                })
        });
        out
    }

    /// Albums in chart order. Plays without an album don't count.
    pub fn album_tally(&self, aggs: &[Agg]) -> Vec<Tally> {
        let mut tallies: HashMap<i64, Tally> = HashMap::default();
        for agg in aggs.iter().filter(|a| a.album != 0) {
            let tally = tallies.entry(agg.album).or_insert(Tally {
                id: agg.album,
                plays: 0,
                listen_ms: 0,
                songs: 0,
                first_at: i64::MAX,
                last_at: i64::MIN,
                cover_song: agg.song,
            });
            tally.plays += agg.plays;
            tally.listen_ms += agg.listen_ms;
            // Aggregates are one per song and album, so each is another song on the album.
            tally.songs += 1;
            tally.first_at = tally.first_at.min(agg.first_at);
            if agg.last_at >= tally.last_at {
                tally.last_at = agg.last_at;
                tally.cover_song = agg.song;
            }
        }
        let mut out: Vec<Tally> = tallies
            .into_values()
            .filter(|t| self.albums.contains_key(&t.id))
            .collect();
        out.sort_by(|a, b| {
            (b.plays, b.listen_ms)
                .cmp(&(a.plays, a.listen_ms))
                .then_with(|| {
                    let (x, y) = (&self.albums[&a.id], &self.albums[&b.id]);
                    x.title
                        .cmp(&y.title)
                        .then_with(|| x.identity.cmp(&y.identity))
                })
        });
        out
    }
}

pub fn all_time_aggregates(conn: &Connection) -> Result<Vec<Agg>> {
    let mut stmt = conn.prepare_cached(
        "SELECT song_id, album_id, plays, listen_ms, first_at, last_at FROM song_albums",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok(Agg {
            song: row.get(0)?,
            album: row.get(1)?,
            plays: row.get::<_, i64>(2)? as u64,
            listen_ms: row.get(3)?,
            first_at: row.get(4)?,
            last_at: row.get(5)?,
        })
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}
