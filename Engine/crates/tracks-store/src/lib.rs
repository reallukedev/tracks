//! The play history as a SQLite index, and everything read from it: charts, totals,
//! activity by hour and day, profiles and search.
//!
//! The host (`SwiftData` on Apple platforms today) stays the source of truth and syncs; this
//! index mirrors it and can always be thrown away and rebuilt. That keeps it safe to evolve:
//! a corrupt or stale file costs one rebuild, never a play.
//!
//! Reads never block each other or the writer (WAL, a small pool of read connections), and
//! every query walks an index or a rollup, so cost follows what is shown rather than how many
//! years of history there are.

mod directory;
mod ingest;
mod pool;
mod query;
mod schema;
mod time;

use std::path::{Path, PathBuf};

use rusqlite::Connection;

pub use ingest::{IngestReport, PlayInput};
pub use query::{
    ActivitySummary, AlbumRow, ArtistRow, Chart, ChartRow, HeatCell, Period, PeriodTotals, Scope,
    SearchResults, SongRow, SourceFilter, Streak, TimelineBucket,
};
pub use schema::DERIVATION_VERSION;

use pool::ConnectionPool;

/// What can go wrong reading or writing the index.
#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("database: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("migration: {0}")]
    Migration(#[from] rusqlite_migration::Error),
    #[error("unknown time zone `{0}`")]
    TimeZone(String),
    #[error("the index is closed")]
    Closed,
}

pub type Result<T, E = StoreError> = std::result::Result<T, E>;

/// The history index. Cheap to share across threads: every method takes `&self`.
#[derive(Debug)]
pub struct Store {
    pool: ConnectionPool,
    path: Option<PathBuf>,
    zone: std::sync::RwLock<jiff::tz::TimeZone>,
    /// Lookups shared by reads until the next write, keyed by the generation counters in
    /// `meta`, which every write bumps in its own transaction. Living in the file, they also
    /// tell another process (a widget) that the app wrote.
    directory: std::sync::Mutex<Option<std::sync::Arc<directory::Directory>>>,
}

impl Store {
    /// Opens (or creates) the index at `path`, migrating it forward.
    ///
    /// Only a file SQLite says is damaged (not a database, or corrupt) is moved aside, with its
    /// journal, and a fresh one created, since the host can always refill it; the caller learns
    /// this from [`Store::needs_rebuild`]. Anything else (the file busy in another process,
    /// locked by data protection, a full disk, a newer schema) is returned as an error and the
    /// file is left alone, so a passing problem never costs the index.
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref().to_path_buf();
        match Self::open_at(&path) {
            Err(error) if is_damage(&error) => {
                for suffix in ["", "-wal", "-shm"] {
                    let mut from = path.clone().into_os_string();
                    from.push(suffix);
                    let mut to = path.with_extension("damaged").into_os_string();
                    to.push(suffix);
                    let _ = std::fs::remove_file(&to);
                    let _ = std::fs::rename(&from, &to);
                }
                Self::open_at(&path).map_err(|_| error)
            }
            other => other,
        }
    }

    /// An index that lives only in memory, for tests and previews.
    pub fn open_in_memory() -> Result<Self> {
        let pool = ConnectionPool::in_memory()?;
        pool.write(|conn| Ok(schema::migrations().to_latest(conn)?))?;
        Ok(Self::new(pool, None))
    }

    fn open_at(path: &Path) -> Result<Self> {
        let pool = ConnectionPool::open(path)?;
        // No integrity check on open: it reads the whole file, and corruption it would find
        // surfaces as SQLITE_CORRUPT on use, where the host falls back and rebuilds.
        pool.write(|conn| Ok(schema::migrations().to_latest(conn)?))?;
        Ok(Self::new(pool, Some(path.to_path_buf())))
    }

    fn new(pool: ConnectionPool, path: Option<PathBuf>) -> Self {
        Self {
            pool,
            path,
            zone: std::sync::RwLock::new(jiff::tz::TimeZone::UTC),
            directory: std::sync::Mutex::new(None),
        }
    }

    /// Where the index lives, if on disk.
    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }

    /// Sets the time zone that hours, weekdays, days and streaks are counted in, by IANA name
    /// ("Europe/London"). The host passes its own, so the engine follows the system setting.
    pub fn set_time_zone(&self, name: &str) -> Result<()> {
        let zone =
            jiff::tz::TimeZone::get(name).map_err(|_| StoreError::TimeZone(name.to_owned()))?;
        *self.zone.write().map_err(|_| StoreError::Closed)? = zone;
        Ok(())
    }

    pub(crate) fn zone(&self) -> jiff::tz::TimeZone {
        self.zone
            .read()
            .map_or(jiff::tz::TimeZone::UTC, |zone| zone.clone())
    }

    /// Whether the index was built by an older derivation (or never filled), so the host
    /// should send its whole history with [`Store::replace_all`].
    pub fn needs_rebuild(&self) -> Result<bool> {
        self.pool.read(|conn| {
            Ok(
                meta_get(conn, "derivation")?.and_then(|v| v.parse::<i64>().ok())
                    != Some(DERIVATION_VERSION),
            )
        })
    }

    /// An opaque value the host stores with its own sync state (a history token), so after a
    /// relaunch it knows where to pick up. Kept in the same transaction as the plays.
    pub fn sync_marker(&self) -> Result<Option<String>> {
        self.pool.read(|conn| meta_get(conn, "sync_marker"))
    }

    /// Compacts the file and refreshes the planner's statistics. Cheap enough to run when the
    /// app goes to the background after a big import.
    pub fn optimize(&self) -> Result<()> {
        self.pool.write(|conn| {
            conn.execute_batch("PRAGMA optimize; PRAGMA wal_checkpoint(TRUNCATE);")?;
            Ok(())
        })
    }

    /// How many plays the index holds.
    pub fn play_count(&self) -> Result<u64> {
        self.pool.read(|conn| {
            Ok(
                conn.query_row("SELECT COUNT(*) FROM plays", [], |row| row.get::<_, i64>(0))?
                    as u64,
            )
        })
    }
}

pub(crate) fn meta_get(conn: &Connection, key: &str) -> Result<Option<String>> {
    use rusqlite::OptionalExtension;
    Ok(conn
        .query_row("SELECT value FROM meta WHERE key = ?1", [key], |row| {
            row.get(0)
        })
        .optional()?)
}

pub(crate) fn meta_set(conn: &Connection, key: &str, value: &str) -> Result<()> {
    conn.execute(
        "INSERT INTO meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        [key, value],
    )?;
    Ok(())
}

/// Whether SQLite reported the file itself as damaged, as opposed to busy or unreachable.
fn is_damage(error: &StoreError) -> bool {
    let code = match error {
        StoreError::Sqlite(rusqlite::Error::SqliteFailure(e, _))
        | StoreError::Migration(rusqlite_migration::Error::RusqliteError {
            err: rusqlite::Error::SqliteFailure(e, _),
            ..
        }) => e.code,
        _ => return false,
    };

    matches!(
        code,
        rusqlite::ErrorCode::NotADatabase | rusqlite::ErrorCode::DatabaseCorrupt
    )
}

/// Counts every committed write (and, separately, writes that change names or first plays),
/// inside the write's own transaction.
pub(crate) fn bump(conn: &Connection, key: &str) -> Result<()> {
    conn.execute(
        "INSERT INTO meta (key, value) VALUES (?1, '1')
         ON CONFLICT(key) DO UPDATE SET value = CAST(value AS INTEGER) + 1",
        [key],
    )?;
    Ok(())
}

pub(crate) fn counter(conn: &Connection, key: &str) -> Result<u64> {
    Ok(meta_get(conn, key)?
        .and_then(|v| v.parse().ok())
        .unwrap_or(0))
}
