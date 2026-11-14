//! The index's schema and its migrations.
//!
//! Everything here can be rebuilt from the host's history (`SwiftData` today), so a migration
//! may drop and rebuild freely. Still, migrations only ever move forward, each in a
//! transaction, tracked by SQLite's `user_version`.

use rusqlite_migration::{M, Migrations};

/// Bumped when a change to how plays are folded or estimated means existing rows are stale.
/// The host sees `needs_rebuild` and sends the whole history again.
pub const DERIVATION_VERSION: i64 = 1;

/// The current schema, for a new file or one being reset.
macro_rules! schema_sql {
    () => {
        r"
        CREATE TABLE meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        ) WITHOUT ROWID;

        CREATE TABLE artists (
            id       INTEGER PRIMARY KEY,
            identity TEXT NOT NULL UNIQUE,
            name     TEXT NOT NULL
        );

        -- How often each spelling of an artist was credited, so the chart shows the one
        -- people actually see most.
        CREATE TABLE artist_spellings (
            artist_id INTEGER NOT NULL REFERENCES artists(id) ON DELETE CASCADE,
            name      TEXT NOT NULL,
            plays     INTEGER NOT NULL,
            PRIMARY KEY (artist_id, name)
        ) WITHOUT ROWID;

        -- Each play's song exactly as written (names, album, ids, cover), interned. Removing a
        -- play un-counts exactly the spellings it counted, and a song shows what its newest
        -- remaining play says. Blank album, ids and unloadable covers are ''.
        CREATE TABLE spelled (
            id          INTEGER PRIMARY KEY,
            artist      TEXT NOT NULL,
            title       TEXT NOT NULL,
            album       TEXT NOT NULL,
            catalog_id  TEXT NOT NULL,
            song_key    TEXT NOT NULL,
            artwork_url TEXT NOT NULL,
            UNIQUE (artist, title, album, catalog_id, song_key, artwork_url)
        );

        CREATE TABLE albums (
            id        INTEGER PRIMARY KEY,
            identity  TEXT NOT NULL UNIQUE,
            title     TEXT NOT NULL,
            artist    TEXT NOT NULL
        );

        CREATE TABLE stations (
            id   INTEGER PRIMARY KEY,
            key  TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL
        );

        -- One row per song identity (folded title and artist). Display fields follow the
        -- newest play that has them; the totals are all-time and kept current on every write,
        -- so all-time charts never scan the plays.
        CREATE TABLE songs (
            id             INTEGER PRIMARY KEY,
            identity       TEXT NOT NULL UNIQUE,
            title          TEXT NOT NULL,
            artist_name    TEXT NOT NULL,
            album_title    TEXT,
            catalog_id     TEXT NOT NULL DEFAULT '',
            song_key       TEXT NOT NULL DEFAULT '',
            artwork_url    TEXT,
            lead_artist_id INTEGER REFERENCES artists(id),
            genre          TEXT,
            release_year   INTEGER,
            search_text    TEXT NOT NULL DEFAULT '',
            plays          INTEGER NOT NULL DEFAULT 0,
            listen_ms        INTEGER NOT NULL DEFAULT 0,
            first_at       INTEGER,
            last_at        INTEGER
        );
        -- Search walks this in chart order and stops at the limit.
        CREATE INDEX songs_rank ON songs (plays DESC, last_at DESC, title, identity);
        CREATE INDEX songs_first ON songs (first_at);

        CREATE TABLE song_artists (
            song_id   INTEGER NOT NULL REFERENCES songs(id) ON DELETE CASCADE,
            artist_id INTEGER NOT NULL REFERENCES artists(id),
            position  INTEGER NOT NULL,
            PRIMARY KEY (song_id, artist_id)
        ) WITHOUT ROWID;
        CREATE INDEX song_artists_artist ON song_artists (artist_id, song_id);

        -- All-time totals per song and album, the rollup every all-time chart reads.
        CREATE TABLE song_albums (
            song_id  INTEGER NOT NULL,
            album_id INTEGER NOT NULL,
            plays    INTEGER NOT NULL,
            listen_ms  INTEGER NOT NULL,
            first_at INTEGER NOT NULL,
            last_at  INTEGER NOT NULL,
            PRIMARY KEY (song_id, album_id)
        ) WITHOUT ROWID;
        CREATE INDEX song_albums_album ON song_albums (album_id);

        -- Times are Unix milliseconds. Clustered by time, so a period is one contiguous read
        -- of the file and the table is its own time index. `ext_key` is a stable hash of the
        -- host's id for the play, which makes every write idempotent and breaks ties between
        -- plays at the same moment the same way however they arrived.
        CREATE TABLE plays (
            played_at  INTEGER NOT NULL,
            ext_key    INTEGER NOT NULL,
            song_id    INTEGER NOT NULL,
            album_id   INTEGER NOT NULL DEFAULT 0,
            kind       INTEGER NOT NULL,
            source     INTEGER NOT NULL,
            station_id INTEGER,
            spelled_id INTEGER NOT NULL,
            digest     INTEGER NOT NULL,
            listen_ms  INTEGER NOT NULL,
            PRIMARY KEY (played_at, ext_key)
        ) WITHOUT ROWID;
        CREATE UNIQUE INDEX plays_ext ON plays (ext_key);
        CREATE INDEX plays_song ON plays (song_id, album_id);
        CREATE INDEX plays_album ON plays (album_id) WHERE album_id != 0;
        "
    };
}

pub fn migrations() -> Migrations<'static> {
    Migrations::new(vec![
        M::up(schema_sql!()),
        // 2: prototype files made before the final layout. The index is a cache, so a layout
        // change is a reset and a rebuild from the history, never a data migration.
        M::up(concat!(
            "DROP TABLE IF EXISTS plays; DROP TABLE IF EXISTS song_albums; DROP TABLE IF EXISTS song_artists;
             DROP TABLE IF EXISTS songs; DROP TABLE IF EXISTS stations; DROP TABLE IF EXISTS albums;
             DROP TABLE IF EXISTS spelled; DROP TABLE IF EXISTS artist_spellings; DROP TABLE IF EXISTS artists;
             DROP TABLE IF EXISTS meta;",
            schema_sql!()
        )),
    ])
}

#[cfg(test)]
mod tests {
    #[test]
    fn migrations_are_valid() {
        assert!(super::migrations().validate().is_ok());
    }
}
