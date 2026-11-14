//! Writing plays: idempotent upserts, removals and full rebuilds, each one transaction that
//! leaves every rollup and listening estimate consistent with the plays.

use std::collections::{HashMap, HashSet};

use rusqlite::{OptionalExtension, Transaction, params};
use tracks_model::{
    LONGEST_PLAUSIBLE_GAP_SECONDS, PlayKind, PlaySource, TYPICAL_SONG_SECONDS, album_key,
    credits_by_name, folded, search_folded, song_key,
};

use crate::{Result, Store, bump, meta_set, schema::DERIVATION_VERSION};

const TYPICAL_MS: i64 = TYPICAL_SONG_SECONDS as i64 * 1000;
const LONGEST_GAP_MS: i64 = LONGEST_PLAUSIBLE_GAP_SECONDS * 1000;
/// Past this many changed plays one pass over the whole history beats fixing each neighbour.
const FULL_RECOMPUTE_THRESHOLD: usize = 2_000;

/// One play as the host has it.
#[derive(Debug, Clone, PartialEq)]
pub struct PlayInput {
    /// The host's stable id for the play. Writing the same id again updates, never duplicates.
    pub ext_id: String,
    /// Catalog id, empty until resolved.
    pub catalog_id: String,
    /// The host's per-device song key.
    pub song_key: String,
    pub title: String,
    pub artist_name: String,
    pub album_title: Option<String>,
    pub artwork_url: Option<String>,
    /// Unix milliseconds.
    pub played_at: i64,
    pub kind: PlayKind,
    pub source: PlaySource,
    pub station_name: Option<String>,
}

/// What a write did.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct IngestReport {
    pub inserted: u64,
    pub updated: u64,
    pub unchanged: u64,
    pub removed: u64,
}

/// FNV-1a: stable across Rust versions and platforms, unlike `DefaultHasher`, so the keys
/// in an existing file stay valid. Collisions at 64 bits are not a practical concern for a
/// few million plays.
pub(crate) fn ext_key(ext_id: &str) -> i64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in ext_id.bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    hash as i64
}

/// Everything about a play that the index keeps, hashed, so a sync can tell a play that
/// changed from one that didn't without reading it back.
pub(crate) fn play_digest(play: &PlayInput) -> i64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    let mut feed = |bytes: &[u8]| {
        for &byte in bytes.iter().chain(&[0x1F]) {
            hash ^= u64::from(byte);
            hash = hash.wrapping_mul(0x0100_0000_01b3);
        }
    };
    feed(play.catalog_id.as_bytes());
    feed(play.song_key.as_bytes());
    feed(play.title.as_bytes());
    feed(play.artist_name.as_bytes());
    feed(play.album_title.as_deref().unwrap_or("\0").as_bytes());
    feed(play.artwork_url.as_deref().unwrap_or("\0").as_bytes());
    feed(&play.played_at.to_le_bytes());
    feed(&[play.kind as u8, play.source as u8]);
    feed(play.station_name.as_deref().unwrap_or("\0").as_bytes());
    hash as i64
}

/// The lead artist of a credit, for an album's byline ("A feat. B" is A's album).
pub(crate) fn lead_artist(artist: &str) -> &str {
    const MARKERS: [&str; 10] = [
        " feat. ",
        " feat ",
        " ft. ",
        " ft ",
        " featuring ",
        " (feat. ",
        " (feat ",
        " (ft. ",
        " (featuring ",
        " [feat. ",
    ];
    // ASCII lowercasing keeps byte offsets, so a cut found in the copy is valid in the original.
    let lowered = artist.to_ascii_lowercase();
    let Some(cut) = MARKERS
        .iter()
        .filter_map(|marker| lowered.find(marker))
        .min()
    else {
        return artist;
    };
    let lead = artist[..cut].trim();
    if lead.is_empty() { artist } else { lead }
}

pub(crate) fn is_loadable_artwork(url: Option<&str>) -> bool {
    url.and_then(|u| u.split_once(':'))
        .is_some_and(|(scheme, _)| {
            scheme.eq_ignore_ascii_case("https") || scheme.eq_ignore_ascii_case("http")
        })
}

#[derive(Debug)]
struct CachedSong {
    id: i64,
    lead_identity: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct StoredPlay {
    key: i64,
    spelled: i64,
    digest: i64,
    song_id: i64,
    album_id: i64,
    played_at: i64,
    kind: u8,
    source: u8,
    station_id: Option<i64>,
    listen_ms: i64,
}

/// A transaction's worth of writing, with lookups cached so a bulk load never asks SQLite
/// for the same song twice.
struct Writer<'conn> {
    tx: Transaction<'conn>,
    songs: HashMap<String, CachedSong>,
    albums: HashMap<String, i64>,
    stations: HashMap<String, i64>,
    artists: HashMap<String, i64>,
    spellings: HashMap<(i64, String), i64>,
    spelled_ids: HashMap<[String; 6], i64>,
    /// Each spelling's credits as (artist, name as written).
    spelled_credits: HashMap<i64, Vec<(i64, String)>>,
    /// (song, album) rollups to recount from the plays.
    touched: HashSet<(i64, i64)>,
    /// Known-time plays, as (time, key), whose estimate or whose predecessor's may have changed.
    anchors: Vec<(i64, i64)>,
    report: IngestReport,
    /// Whether names, credits or first plays changed, so cached lookups need rebuilding.
    catalog_changed: bool,
}

impl<'conn> Writer<'conn> {
    fn new(tx: Transaction<'conn>) -> Self {
        Self {
            tx,
            songs: HashMap::new(),
            albums: HashMap::new(),
            stations: HashMap::new(),
            artists: HashMap::new(),
            spellings: HashMap::new(),
            spelled_ids: HashMap::new(),
            spelled_credits: HashMap::new(),
            touched: HashSet::new(),
            anchors: Vec::new(),
            report: IngestReport::default(),
            catalog_changed: false,
        }
    }

    fn artist_id(&mut self, identity: &str, name: &str) -> Result<i64> {
        if let Some(&id) = self.artists.get(identity) {
            return Ok(id);
        }
        let id = self.tx.query_row(
            "INSERT INTO artists (identity, name) VALUES (?1, ?2)
             ON CONFLICT(identity) DO UPDATE SET identity = identity RETURNING id",
            params![identity, name],
            |row| row.get(0),
        )?;
        self.artists.insert(identity.to_owned(), id);
        Ok(id)
    }

    /// The song row for this play, created with its credits the first time it's seen. Its
    /// names and cover are worked out from its plays in `flush`.
    fn song(&mut self, play: &PlayInput) -> Result<(i64, String)> {
        let identity = song_key(&play.title, &play.artist_name);
        if let Some(song) = self.songs.get(&identity) {
            return Ok((song.id, song.lead_identity.clone()));
        }
        let existing = self
            .tx
            .query_row(
                "SELECT s.id, COALESCE(a.identity, '') FROM songs s
                 LEFT JOIN artists a ON a.id = s.lead_artist_id WHERE s.identity = ?1",
                [&identity],
                |row| {
                    Ok(CachedSong {
                        id: row.get(0)?,
                        lead_identity: row.get(1)?,
                    })
                },
            )
            .optional()?;
        let song = match existing {
            Some(song) => song,
            None => {
                let credits = credits_by_name(&play.artist_name, &play.title);
                let lead = credits.first().filter(|c| !c.identity.is_empty());
                let lead_id = match lead {
                    Some(credit) => Some(self.artist_id(&credit.identity, &credit.name)?),
                    None => None,
                };
                self.catalog_changed = true;
                let id: i64 = self.tx.query_row(
                    "INSERT INTO songs (identity, title, artist_name, lead_artist_id) VALUES (?1, ?2, ?3, ?4) RETURNING id",
                    params![identity, play.title, play.artist_name, lead_id],
                    |row| row.get(0),
                )?;
                let mut seen = HashSet::new();
                for (position, credit) in credits.iter().enumerate() {
                    if credit.identity.is_empty() || !seen.insert(credit.identity.clone()) {
                        continue;
                    }
                    let artist = self.artist_id(&credit.identity, &credit.name)?;
                    self.tx.execute(
                        "INSERT OR IGNORE INTO song_artists (song_id, artist_id, position) VALUES (?1, ?2, ?3)",
                        params![id, artist, position as i64],
                    )?;
                }
                CachedSong {
                    id,
                    lead_identity: lead.map(|c| c.identity.clone()).unwrap_or_default(),
                }
            }
        };
        let result = (song.id, song.lead_identity.clone());
        self.songs.insert(identity, song);
        Ok(result)
    }

    /// The id of this play's song exactly as written, interned.
    fn spelled(&mut self, play: &PlayInput) -> Result<i64> {
        let key = [
            play.artist_name.clone(),
            play.title.clone(),
            play.album_title
                .as_deref()
                .map(str::trim)
                .unwrap_or_default()
                .to_owned(),
            play.catalog_id.clone(),
            play.song_key.clone(),
            play.artwork_url
                .clone()
                .filter(|u| is_loadable_artwork(Some(u)))
                .unwrap_or_default(),
        ];
        if let Some(&id) = self.spelled_ids.get(&key) {
            return Ok(id);
        }
        let id = self.tx.query_row(
            "INSERT INTO spelled (artist, title, album, catalog_id, song_key, artwork_url) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT DO UPDATE SET artist = artist RETURNING id",
            params![key[0], key[1], key[2], key[3], key[4], key[5]],
            |row| row.get(0),
        )?;
        self.spelled_ids.insert(key, id);
        Ok(id)
    }

    /// Counts (or with -1 un-counts) a play's credited spellings, so artists show the name
    /// people see most.
    fn count_spellings(&mut self, spelled: i64, delta: i64) -> Result<()> {
        if !self.spelled_credits.contains_key(&spelled) {
            let (artist, title): (String, String) = self.tx.query_row(
                "SELECT artist, title FROM spelled WHERE id = ?1",
                [spelled],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )?;
            let mut credits = Vec::new();
            for credit in credits_by_name(&artist, &title)
                .into_iter()
                .filter(|c| !c.identity.is_empty())
            {
                credits.push((self.artist_id(&credit.identity, &credit.name)?, credit.name));
            }
            self.spelled_credits.insert(spelled, credits);
        }
        for (artist, name) in self.spelled_credits.get(&spelled).into_iter().flatten() {
            *self.spellings.entry((*artist, name.clone())).or_insert(0) += delta;
        }
        Ok(())
    }

    fn album_id(&mut self, title: Option<&str>, lead_identity: &str, artist: &str) -> Result<i64> {
        let Some(title) = title else { return Ok(0) };
        let Some(identity) = album_key(title, lead_identity) else {
            return Ok(0);
        };
        if let Some(&id) = self.albums.get(&identity) {
            return Ok(id);
        }
        let byline = lead_artist(artist);
        // Returns a row only when the album is new or its names changed.
        let changed: Option<i64> = self
            .tx
            .query_row(
                "INSERT INTO albums (identity, title, artist) VALUES (?1, ?2, ?3)
                 ON CONFLICT(identity) DO UPDATE SET title = excluded.title, artist = excluded.artist
                     WHERE title IS NOT excluded.title OR artist IS NOT excluded.artist
                 RETURNING id",
                params![identity, title.trim(), byline],
                |row| row.get(0),
            )
            .optional()?;
        let id = match changed {
            Some(id) => {
                self.catalog_changed = true;
                id
            }
            None => self.tx.query_row(
                "SELECT id FROM albums WHERE identity = ?1",
                [&identity],
                |row| row.get(0),
            )?,
        };
        self.albums.insert(identity, id);
        Ok(id)
    }

    fn station_id(&mut self, name: Option<&str>) -> Result<Option<i64>> {
        let Some(name) = name.map(str::trim).filter(|n| !n.is_empty()) else {
            return Ok(None);
        };
        let key = folded(name);
        if let Some(&id) = self.stations.get(&key) {
            return Ok(Some(id));
        }
        let id = self.tx.query_row(
            "INSERT INTO stations (key, name) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET name = excluded.name RETURNING id",
            params![key, name],
            |row| row.get(0),
        )?;
        self.stations.insert(key, id);
        Ok(Some(id))
    }

    fn stored(&self, key: i64) -> Result<Option<StoredPlay>> {
        Ok(self
            .tx
            .query_row(
                "SELECT ext_key, song_id, album_id, played_at, kind, source, station_id, listen_ms, spelled_id, digest
                 FROM plays WHERE ext_key = ?1",
                [key],
                |row| {
                    Ok(StoredPlay {
                        key: row.get(0)?,
                        song_id: row.get(1)?,
                        album_id: row.get(2)?,
                        played_at: row.get(3)?,
                        kind: row.get(4)?,
                        source: row.get(5)?,
                        station_id: row.get(6)?,
                        listen_ms: row.get(7)?,
                        spelled: row.get(8)?,
                        digest: row.get(9)?,
                    })
                },
            )
            .optional()?)
    }

    fn upsert(&mut self, play: &PlayInput, check_existing: bool) -> Result<()> {
        let key = ext_key(&play.ext_id);
        let digest = play_digest(play);
        if check_existing && let Some(old) = self.stored(key)? {
            if old.digest == digest {
                self.report.unchanged += 1;
                return Ok(());
            }
            self.remove_stored(old)?;
            self.report.removed -= 1;
            self.report.updated += 1;
        } else {
            self.report.inserted += 1;
        }

        let (song_id, lead_identity) = self.song(play)?;
        let album_id = self.album_id(
            play.album_title.as_deref(),
            &lead_identity,
            &play.artist_name,
        )?;
        let station_id = self.station_id(play.station_name.as_deref())?;
        let spelled = self.spelled(play)?;
        let kind = play.kind as u8;
        let source = play.source as u8;

        self.tx.execute(
            "INSERT INTO plays (ext_key, song_id, album_id, played_at, kind, source, station_id, spelled_id, digest, listen_ms)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            params![key, song_id, album_id, play.played_at, kind, source, station_id, spelled, digest, TYPICAL_MS],
        )?;
        self.count_spellings(spelled, 1)?;
        self.touched.insert((song_id, album_id));
        if play.kind.time_is_known() {
            self.anchors.push((play.played_at, key));
        }
        Ok(())
    }

    fn remove_stored(&mut self, old: StoredPlay) -> Result<()> {
        self.tx.execute(
            "DELETE FROM plays WHERE played_at = ?1 AND ext_key = ?2",
            [old.played_at, old.key],
        )?;
        self.count_spellings(old.spelled, -1)?;
        self.touched.insert((old.song_id, old.album_id));
        if PlayKind::from_u8(old.kind).is_some_and(PlayKind::time_is_known) {
            self.anchors.push((old.played_at, old.key));
        }
        self.report.removed += 1;
        Ok(())
    }

    fn remove(&mut self, key: i64) -> Result<()> {
        if let Some(old) = self.stored(key)? {
            self.remove_stored(old)?;
        }
        Ok(())
    }

    /// Re-estimates the plays around each anchor: the play itself (its next play may have
    /// changed) and the play before it (whose next play may now be this one, or gone).
    fn refresh_estimates(&mut self) -> Result<()> {
        if self.anchors.len() > FULL_RECOMPUTE_THRESHOLD {
            return self.recompute_all_estimates();
        }
        let anchors = std::mem::take(&mut self.anchors);
        let mut done = HashSet::new();
        for (at, key) in anchors {
            if let Some(play) = self.known_play_at_or_before(at, key)? {
                self.reestimate(play, &mut done)?;
                if let Some(previous) = self.known_play_before(play.0, play.1)? {
                    self.reestimate(previous, &mut done)?;
                }
            }
        }
        Ok(())
    }

    // Plays at the same moment are ordered by key, which depends only on the play, so the
    // order (and every estimate) is the same however the plays arrived.
    fn known_play_at_or_before(&self, at: i64, key: i64) -> Result<Option<(i64, i64)>> {
        Ok(self
            .tx
            .query_row(
                "SELECT played_at, ext_key FROM plays WHERE kind != 2 AND (played_at, ext_key) <= (?1, ?2)
                 ORDER BY played_at DESC, ext_key DESC LIMIT 1",
                params![at, key],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?)
    }

    fn known_play_before(&self, at: i64, key: i64) -> Result<Option<(i64, i64)>> {
        Ok(self
            .tx
            .query_row(
                "SELECT played_at, ext_key FROM plays WHERE kind != 2 AND (played_at, ext_key) < (?1, ?2)
                 ORDER BY played_at DESC, ext_key DESC LIMIT 1",
                params![at, key],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?)
    }

    fn reestimate(&mut self, (at, key): (i64, i64), done: &mut HashSet<i64>) -> Result<()> {
        if !done.insert(key) {
            return Ok(());
        }
        let (song_id, current): (i64, i64) = self.tx.query_row(
            "SELECT song_id, listen_ms FROM plays WHERE played_at = ?1 AND ext_key = ?2",
            [at, key],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        let next: Option<(i64, i64)> = self
            .tx
            .query_row(
                "SELECT played_at, song_id FROM plays WHERE kind != 2 AND (played_at, ext_key) > (?1, ?2)
                 ORDER BY played_at, ext_key LIMIT 1",
                params![at, key],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        let estimate = estimate_ms(at, song_id, next);
        if estimate != current {
            let album: i64 = self.tx.query_row(
                "UPDATE plays SET listen_ms = ?3 WHERE played_at = ?1 AND ext_key = ?2 RETURNING album_id",
                params![at, key, estimate],
                |row| row.get(0),
            )?;
            self.touched.insert((song_id, album));
        }
        Ok(())
    }

    /// One ordered pass over every play, the way the Swift `ListeningEstimate` walks them.
    fn recompute_all_estimates(&mut self) -> Result<()> {
        self.anchors.clear();
        let mut known: Vec<(i64, i64, i64, i64, i64)> = Vec::new();
        {
            let mut stmt = self
                .tx
                .prepare("SELECT ext_key, played_at, song_id, album_id, listen_ms FROM plays WHERE kind != 2 ORDER BY played_at, ext_key")?;
            let rows = stmt.query_map([], |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                ))
            })?;
            for row in rows {
                known.push(row?);
            }
        }
        let mut update = self
            .tx
            .prepare("UPDATE plays SET listen_ms = ?3 WHERE played_at = ?1 AND ext_key = ?2")?;
        let mut touched = Vec::new();
        for (index, &(key, at, song, album, current)) in known.iter().enumerate() {
            let next = known
                .get(index + 1)
                .map(|&(_, next_at, next_song, _, _)| (next_at, next_song));
            let estimate = estimate_ms(at, song, next);
            if estimate != current {
                update.execute(params![at, key, estimate])?;
                touched.push((song, album));
            }
        }
        drop(update);
        self.touched.extend(touched);
        Ok(())
    }

    /// Works out what each song shows from its plays, for every song (`all`) or those given.
    fn refresh_display(&mut self, all: bool, songs: &HashSet<i64>) -> Result<()> {
        const COLUMNS: &str = "p.song_id, p.played_at, p.ext_key, s.title, s.artist, s.album, s.catalog_id, s.song_key, s.artwork_url";
        let mut displays: HashMap<i64, Display> = HashMap::new();
        let mut offer = |row: &rusqlite::Row<'_>| -> rusqlite::Result<()> {
            displays.entry(row.get(0)?).or_default().offer(
                (row.get(1)?, row.get(2)?),
                [
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                    row.get(7)?,
                    row.get(8)?,
                ],
            );
            Ok(())
        };
        if all {
            let mut stmt = self.tx.prepare(&format!(
                "SELECT {COLUMNS} FROM plays p JOIN spelled s ON s.id = p.spelled_id"
            ))?;
            let mut rows = stmt.query([])?;
            while let Some(row) = rows.next()? {
                offer(row)?;
            }
        } else {
            let mut stmt = self
                .tx
                .prepare(&format!("SELECT {COLUMNS} FROM plays p JOIN spelled s ON s.id = p.spelled_id WHERE p.song_id = ?1"))?;
            for song in songs {
                let mut rows = stmt.query([song])?;
                while let Some(row) = rows.next()? {
                    offer(row)?;
                }
            }
        }
        let mut update = self.tx.prepare(
            "UPDATE songs SET title = ?2, artist_name = ?3, catalog_id = ?4, song_key = ?5, album_title = ?6,
                 artwork_url = ?7, search_text = ?8 WHERE id = ?1",
        )?;
        for (song, display) in displays {
            let Some((_, [title, artist, catalog_id, song_key])) = display.names else {
                continue;
            };
            let album = display.album.map(|(_, album)| album);
            let artwork = display.artwork.map(|(_, url)| url);
            let search = search_folded(&format!(
                "{title} {artist} {}",
                album.as_deref().unwrap_or_default()
            ));
            update.execute(params![
                song, title, artist, catalog_id, song_key, album, artwork, search
            ])?;
        }
        Ok(())
    }

    #[expect(clippy::too_many_lines, reason = "one transaction's steps, in order")]
    fn flush(mut self, full: bool, marker: Option<&str>) -> Result<(IngestReport, bool)> {
        if full {
            self.recompute_all_estimates()?;
        } else {
            self.refresh_estimates()?;
        }

        {
            let mut add = self.tx.prepare(
                "INSERT INTO artist_spellings (artist_id, name, plays) VALUES (?1, ?2, ?3)
                 ON CONFLICT(artist_id, name) DO UPDATE SET plays = plays + excluded.plays",
            )?;
            let mut drop = self.tx.prepare(
                "DELETE FROM artist_spellings WHERE artist_id = ?1 AND name = ?2 AND plays <= 0",
            )?;
            for ((artist, name), plays) in &self.spellings {
                add.execute(params![artist, name, plays])?;
                if *plays < 0 {
                    drop.execute(params![artist, name])?;
                }
            }
            let mut rename = self.tx.prepare(
                "UPDATE artists SET name = best.name
                 FROM (SELECT name FROM artist_spellings WHERE artist_id = ?1 ORDER BY plays DESC, name LIMIT 1) AS best
                 WHERE id = ?1 AND artists.name IS NOT best.name",
            )?;
            let artists: HashSet<i64> = self.spellings.keys().map(|(artist, _)| *artist).collect();
            for artist in artists {
                if rename.execute([artist])? > 0 {
                    self.catalog_changed = true;
                }
            }
        }

        let mut refresh_songs: HashSet<i64> = HashSet::new();
        if full {
            self.catalog_changed = true;
            self.tx.execute_batch(
                "DELETE FROM song_albums;
                 INSERT INTO song_albums (song_id, album_id, plays, listen_ms, first_at, last_at)
                     SELECT song_id, album_id, COUNT(*), SUM(listen_ms), MIN(played_at), MAX(played_at)
                     FROM plays GROUP BY song_id, album_id;
                 UPDATE songs SET plays = 0, listen_ms = 0, first_at = NULL, last_at = NULL;",
            )?;
            self.tx.execute_batch(
                "UPDATE songs SET plays = t.plays, listen_ms = t.listen_ms, first_at = t.first_at, last_at = t.last_at
                 FROM (SELECT song_id, SUM(plays) AS plays, SUM(listen_ms) AS listen_ms,
                              MIN(first_at) AS first_at, MAX(last_at) AS last_at
                       FROM song_albums GROUP BY song_id) AS t
                 WHERE songs.id = t.song_id;",
            )?;
        } else {
            let touched: Vec<(i64, i64)> = self.touched.drain().collect();
            let mut songs = HashSet::new();
            refresh_songs.extend(touched.iter().map(|(song, _)| *song));
            {
                let mut recount = self.tx.prepare(
                    "INSERT INTO song_albums (song_id, album_id, plays, listen_ms, first_at, last_at)
                     SELECT ?1, ?2, COUNT(*), SUM(listen_ms), MIN(played_at), MAX(played_at)
                     FROM plays WHERE song_id = ?1 AND album_id = ?2 HAVING COUNT(*) > 0
                     ON CONFLICT(song_id, album_id) DO UPDATE SET plays = excluded.plays,
                         listen_ms = excluded.listen_ms, first_at = excluded.first_at, last_at = excluded.last_at",
                )?;
                let mut forget = self.tx.prepare(
                    "DELETE FROM song_albums WHERE song_id = ?1 AND album_id = ?2
                     AND NOT EXISTS (SELECT 1 FROM plays WHERE song_id = ?1 AND album_id = ?2)",
                )?;
                for (song, album) in touched {
                    recount.execute(params![song, album])?;
                    forget.execute(params![song, album])?;
                    songs.insert(song);
                }
            }
            let mut first = self
                .tx
                .prepare("SELECT first_at FROM songs WHERE id = ?1")?;
            let mut total = self.tx.prepare(
                "UPDATE songs SET (plays, listen_ms, first_at, last_at) =
                     (SELECT COALESCE(SUM(plays), 0), COALESCE(SUM(listen_ms), 0), MIN(first_at), MAX(last_at)
                      FROM song_albums WHERE song_id = ?1)
                 WHERE id = ?1 RETURNING first_at",
            )?;
            for song in songs {
                let before: Option<i64> =
                    first.query_row([song], |r| r.get(0)).optional()?.flatten();
                let after: Option<i64> =
                    total.query_row([song], |r| r.get(0)).optional()?.flatten();
                // When an artist was first heard is cached with the names.
                if before != after {
                    self.catalog_changed = true;
                }
            }
        }

        self.refresh_display(full, &refresh_songs)?;

        // A song with no plays left goes, with its credits; artists and albums are only ever
        // reached through songs and plays, so an orphan is invisible and harmless.
        if self.tx.execute("DELETE FROM songs WHERE plays = 0 AND NOT EXISTS (SELECT 1 FROM plays WHERE plays.song_id = songs.id)", [])? > 0 {
            self.catalog_changed = true;
        }

        if let Some(marker) = marker {
            meta_set(&self.tx, "sync_marker", marker)?;
        }
        bump(&self.tx, "generation")?;
        if self.catalog_changed {
            bump(&self.tx, "catalog_generation")?;
        }
        let report = (self.report, self.catalog_changed);
        self.tx.commit()?;
        Ok(report)
    }
}

/// What a song shows, picked from its plays the way the Swift charts pick: names and ids from
/// the newest play that has a catalog id (or the newest of all), the album from the newest
/// play that names one, and the cover from the newest play with a cover that loads.
#[derive(Debug, Default)]
struct Display {
    names: Option<((bool, i64, i64), [String; 4])>,
    album: Option<((i64, i64), String)>,
    artwork: Option<((i64, i64), String)>,
}

impl Display {
    fn offer(
        &mut self,
        at: (i64, i64),
        [title, artist, album, catalog_id, song_key, artwork]: [String; 6],
    ) {
        let rank = (!catalog_id.is_empty(), at.0, at.1);
        if self.names.as_ref().is_none_or(|(best, _)| rank > *best) {
            self.names = Some((rank, [title, artist, catalog_id, song_key]));
        }
        if !album.is_empty() && self.album.as_ref().is_none_or(|(best, _)| at > *best) {
            self.album = Some((at, album));
        }
        if !artwork.is_empty() && self.artwork.as_ref().is_none_or(|(best, _)| at > *best) {
            self.artwork = Some((at, artwork));
        }
    }
}

/// How long a play lasted, from the gap/// How long a play lasted, from the gap to the next play whose time is known.
fn estimate_ms(at: i64, song: i64, next: Option<(i64, i64)>) -> i64 {
    match next {
        // Saturating, so absurd times from a host can't overflow.
        Some((next_at, _)) if (1..=LONGEST_GAP_MS).contains(&next_at.saturating_sub(at)) => {
            next_at.saturating_sub(at)
        }
        // The same play from two devices, not yet merged: the copy after it has the listening.
        Some((next_at, next_song)) if next_at == at && next_song == song => 0,
        _ => TYPICAL_MS,
    }
}

impl Store {
    #[expect(clippy::unused_self, reason = "kept as the one place every write ends")]
    fn finish_write(&self, result: Result<(IngestReport, bool)>) -> Result<IngestReport> {
        result.map(|(report, _)| report)
    }

    /// Adds or updates plays. Writing a play the index already has, unchanged, is a no-op, so
    /// replaying a batch after a crash is safe.
    pub fn upsert(&self, plays: &[PlayInput], marker: Option<&str>) -> Result<IngestReport> {
        let result = self.pool.write(|conn| {
            let mut writer = Writer::new(conn.transaction()?);
            for play in plays {
                writer.upsert(play, true)?;
            }
            let full = writer.anchors.len() > FULL_RECOMPUTE_THRESHOLD;
            writer.flush(full, marker)
        });
        self.finish_write(result)
    }

    /// Removes plays by the host's ids. Unknown ids are ignored.
    pub fn remove(&self, ext_ids: &[String], marker: Option<&str>) -> Result<IngestReport> {
        let result = self.pool.write(|conn| {
            let mut writer = Writer::new(conn.transaction()?);
            for id in ext_ids {
                writer.remove(ext_key(id))?;
            }
            writer.flush(false, marker)
        });
        self.finish_write(result)
    }

    /// Brings the index to exactly `plays`, the host's whole history: adds what's new, updates
    /// what changed and removes what's gone, touching nothing else. Cheap when little changed,
    /// which is every launch after the first; a rebuild when most did.
    pub fn sync(&self, plays: &[PlayInput], marker: Option<&str>) -> Result<IngestReport> {
        if self.needs_rebuild()? {
            return self.replace_all(plays, marker);
        }
        let mut rebuild = false;
        let result = self.pool.write(|conn| {
            // Read and write under the one lock, so nothing lands between the diff and the write.
            let existing: HashMap<i64, i64> = {
                let mut stmt = conn.prepare("SELECT ext_key, digest FROM plays")?;
                let rows = stmt.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?;
                rows.collect::<Result<_, _>>()?
            };
            let mut wanted: HashSet<i64> = HashSet::with_capacity(plays.len());
            let mut changed = Vec::new();
            for play in plays {
                let key = ext_key(&play.ext_id);
                // The same id twice in one snapshot is one play, as in a rebuild.
                if wanted.insert(key) && existing.get(&key) != Some(&play_digest(play)) {
                    changed.push(play);
                }
            }
            let removed: Vec<i64> = existing
                .keys()
                .filter(|key| !wanted.contains(key))
                .copied()
                .collect();
            if changed.len() + removed.len() > existing.len() / 4 + 1_000 {
                rebuild = true;
                return Ok((IngestReport::default(), false));
            }
            let unchanged = (wanted.len() - changed.len()) as u64;
            let mut writer = Writer::new(conn.transaction()?);
            for key in removed {
                writer.remove(key)?;
            }
            for play in changed {
                writer.upsert(play, true)?;
            }
            writer.report.unchanged += unchanged;
            let full = writer.anchors.len() > FULL_RECOMPUTE_THRESHOLD;
            writer.flush(full, marker)
        });
        if rebuild {
            return self.replace_all(plays, marker);
        }
        self.finish_write(result)
    }

    /// Replaces the whole history in one transaction: the first fill, or a rebuild after the
    /// derivation changed. Readers keep seeing the old history until it commits.
    pub fn replace_all(&self, plays: &[PlayInput], marker: Option<&str>) -> Result<IngestReport> {
        let result = self.pool.write(|conn| {
            let tx = conn.transaction()?;
            tx.execute_batch(
                "DELETE FROM plays; DELETE FROM song_albums; DELETE FROM song_artists; DELETE FROM songs;
                 DELETE FROM artist_spellings; DELETE FROM artists; DELETE FROM albums; DELETE FROM stations;
                 DELETE FROM spelled;",
            )?;
            let mut writer = Writer::new(tx);
            let mut seen = HashSet::with_capacity(plays.len());
            for play in plays {
                // The same id twice in one snapshot is one play.
                if seen.insert(ext_key(&play.ext_id)) {
                    writer.upsert(play, false)?;
                }
            }
            meta_set(&writer.tx, "derivation", &DERIVATION_VERSION.to_string())?;
            writer.flush(true, marker)
        });
        self.finish_write(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lead_artist_cuts_at_the_first_feature_marker() {
        assert_eq!(lead_artist("Umbra feat. Yuki Tanabe"), "Umbra");
        assert_eq!(lead_artist("Umbra (FEAT. Yuki)"), "Umbra");
        assert_eq!(lead_artist("Mara Solis"), "Mara Solis");
        assert_eq!(lead_artist(" feat. Nobody"), " feat. Nobody");
    }

    #[test]
    fn only_web_artwork_is_loadable() {
        assert!(is_loadable_artwork(Some("https://example.com/a.jpg")));
        assert!(is_loadable_artwork(Some("HTTP://example.com/a.jpg")));
        assert!(!is_loadable_artwork(Some("musicKit://artwork/transient/1")));
        assert!(!is_loadable_artwork(Some("")));
        assert!(!is_loadable_artwork(None));
    }

    #[test]
    fn estimates_follow_the_swift_rules() {
        assert_eq!(estimate_ms(0, 1, Some((180_000, 2))), 180_000);
        assert_eq!(estimate_ms(0, 1, Some((600_001, 2))), TYPICAL_MS);
        assert_eq!(estimate_ms(0, 1, Some((0, 1))), 0);
        assert_eq!(estimate_ms(0, 1, Some((0, 2))), TYPICAL_MS);
        assert_eq!(estimate_ms(0, 1, None), TYPICAL_MS);
    }
}
