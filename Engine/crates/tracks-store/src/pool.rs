//! One writer and a few readers over the same file. WAL lets readers run alongside the
//! writer, so a chart never waits for an import.

use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard};

use rusqlite::{Connection, OpenFlags};

use crate::{Result, StoreError};

/// More readers than this buys nothing on a phone: the UI asks for a handful of things at once.
const MAX_IDLE_READERS: usize = 3;

#[derive(Debug)]
pub struct ConnectionPool {
    writer: Mutex<Connection>,
    readers: Mutex<Vec<Connection>>,
    /// In memory, readers would each see their own empty database, so reads go to the writer.
    path: Option<Arc<Path>>,
}

impl ConnectionPool {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).ok();
        }
        let writer = Connection::open(path)?;
        configure(&writer, true)?;
        Ok(Self {
            writer: Mutex::new(writer),
            readers: Mutex::new(Vec::new()),
            path: Some(Arc::from(path)),
        })
    }

    pub fn in_memory() -> Result<Self> {
        let writer = Connection::open_in_memory()?;
        configure(&writer, true)?;
        Ok(Self {
            writer: Mutex::new(writer),
            readers: Mutex::new(Vec::new()),
            path: None,
        })
    }

    fn writer(&self) -> MutexGuard<'_, Connection> {
        // A panic while holding the lock leaves SQLite itself consistent (the transaction rolls
        // back on drop), so a poisoned lock is safe to keep using.
        self.writer
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    pub fn write<T>(&self, work: impl FnOnce(&mut Connection) -> Result<T>) -> Result<T> {
        let mut conn = self.writer();
        work(&mut conn)
    }

    pub fn read<T>(&self, work: impl FnOnce(&Connection) -> Result<T>) -> Result<T> {
        let Some(path) = &self.path else {
            let conn = self.writer();
            return in_snapshot(&conn, work);
        };
        let reader = self.readers.lock().map_err(|_| StoreError::Closed)?.pop();
        let conn = match reader {
            Some(conn) => conn,
            None => {
                let conn = Connection::open_with_flags(
                    path.as_ref(),
                    OpenFlags::SQLITE_OPEN_READ_ONLY
                        | OpenFlags::SQLITE_OPEN_NO_MUTEX
                        | OpenFlags::SQLITE_OPEN_URI,
                )?;
                configure(&conn, false)?;
                conn
            }
        };
        let result = in_snapshot(&conn, work);
        if let Ok(mut idle) = self.readers.lock()
            && idle.len() < MAX_IDLE_READERS
        {
            idle.push(conn);
        }
        result
    }
}

fn configure(conn: &Connection, writer: bool) -> Result<()> {
    // Tuned for phones as much as Macs: a modest page cache, memory-mapped reads (the OS
    // shares those pages with the file cache instead of copying them), and NORMAL sync, which
    // in WAL mode is durable across app crashes and only risks the last commit on power loss,
    // a play the host still has.
    conn.busy_timeout(std::time::Duration::from_secs(5))?;
    conn.set_prepared_statement_cache_capacity(64);
    conn.execute_batch(
        "PRAGMA foreign_keys = ON;
         PRAGMA cache_size = -8000;
         PRAGMA mmap_size = 268435456;
         PRAGMA temp_store = MEMORY;",
    )?;
    if writer {
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA synchronous = NORMAL;
             PRAGMA journal_size_limit = 8388608;",
        )?;
    }
    Ok(())
}

/// Runs a read in one transaction, so every statement in it sees the same version of the
/// history even while a write commits.
fn in_snapshot<T>(conn: &Connection, work: impl FnOnce(&Connection) -> Result<T>) -> Result<T> {
    conn.execute_batch("BEGIN DEFERRED")?;
    let result = work(conn);
    // Nothing was written, so ending it can't lose anything; a failure here only means the
    // transaction had already ended.
    let _ = conn.execute_batch(if result.is_ok() { "COMMIT" } else { "ROLLBACK" });
    result
}
