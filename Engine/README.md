# Tracks Engine

The cross-platform core of Tracks, in Rust. Each platform keeps its own native UI and system
integration (SwiftUI, MusicKit, CarPlay, widgets, CloudKit and Keychain on Apple; the same
roles on Android, Windows and Linux later) and calls the engine for everything that is the
same everywhere.

## Layout

| Crate | What it holds |
| --- | --- |
| `tracks-model` | Play kinds and sources, name folding (byte-for-byte Foundation's, checked against golden vectors produced by Foundation), song and album identities, artist credits ("A feat. B", "A & B"), search folding. Pure, no I/O. |
| `tracks-store` | The history index: SQLite with running totals, and every chart, total, timeline, activity, streak and search read from it. |
| `tracks-lastfm` | Last.fm requests, signing and response parsing, the scrobble queue rules and backoff. Sans-IO: the host sends the request with its own HTTP stack. |
| `tracks-ffi` | The surface the apps see, generated with [UniFFI](https://mozilla.github.io/uniffi-rs/) (Swift today, Kotlin for Android later). |
| `uniffi-bindgen` | The bindings generator. |

Dependencies are deliberately few and mature: `rusqlite` (bundled SQLite), `rusqlite_migration`,
`jiff` (time zones), `unicode-normalization`, `caseless`, `md-5`, `serde_json`, `rustc-hash`,
`thiserror`, `uniffi`.

## Decisions

- **The index mirrors the store; it is never the source of truth.** SwiftData and CloudKit keep
  the history and sync it. The index can be deleted at any time and refills itself, and a file
  that won't open is moved aside and rebuilt. Anything going wrong costs a rebuild, never a play.
  The Swift callers fall back to the Swift calculator if the engine is unavailable.
- **Cost follows what's shown, not how long the history is.** Plays are clustered by time
  (`WITHOUT ROWID`, primary key `(played_at, key)`), so a period is one contiguous read.
  All-time totals per song and album are kept current on every write, so all-time charts never
  scan plays. Lookups that only change when names do (credits, first plays, all-time artist and
  album charts) are cached per write and shared by every read until the next one.
- **Every write is idempotent.** A play is keyed by a stable hash of the host's id and carries a
  digest of its fields, so replaying a batch after a crash is a no-op and a launch-time sync
  writes only what changed.
- **Periods come from the host's calendar.** Swift works out weeks, months and years with its own
  `Calendar` (first weekday, locale, calendar system) and passes Unix milliseconds; the engine
  counts within them. Hours, weekdays and streaks use the IANA zone the host passes.
- **Native networking.** Last.fm requests are built and parsed in Rust and sent with URLSession
  (OkHttp on Android), keeping proxies, ATS, cellular rules and background sessions native and
  keeping a TLS stack out of the binary.
- **Synchronous, thread-safe API.** One writer and up to three reader connections over WAL, so
  reads never wait for an import. Hosts call it off their main thread.

## Speed

`cargo bench -p tracks-store --bench large_history` seeds the same library as the Swift app's
`LargeLibraryBenchmarks` (150,000 plays, 25,000 songs, 4,000 artists over five years) and a
ten-year, 300,000-play one. On an M-series Mac, release build:

| | Swift (in memory) | Engine |
| --- | --- | --- |
| First load of the history | 4.9 s | 2.2 s (once; later launches sync only changes) |
| All-time song chart | 80 ms | 0.06 ms |
| All-time artist chart | 47 ms | 0.1 ms |
| All-time album chart | 292 ms | 0.14 ms |
| Search | 522 ms index build, then 11 ms a query | 0.3 to 0.5 ms a query, no build |
| Add a play, then the next all-time chart | rebuild of in-memory state | 10 ms |

A year's charts take 6 to 12 ms and a month's about 1 ms, and none of it grows with history
outside the period: the ten-year, 300,000-play library gives the same figures. The index file is
34 MB for 150,000 plays and 53 MB for 300,000.

## Building

```bash
Engine/build-apple.sh
```

Builds the static libraries for iPhone, the Simulator and the Mac, generates the Swift bindings
and writes `Engine/apple/TracksEngine` (a local Swift package TracksCore depends on). Run it once
after cloning and after any change in `Engine/`. Both outputs are gitignored.

```bash
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
```

`tests/consistency.rs` in `tracks-store` is a property test: random adds, edits, removals and
syncs, read between each, must always end exactly where a rebuild from the final history does.
`HistoryEngineParityTests` in TracksCore checks the engine's charts against the Swift
calculator row for row.

## Status

Moved to the engine so far: name folding, artist credits, the history index and its charts,
totals, activity, streaks and search; Last.fm request building, signing and parsing. In the app,
Charts (songs, artists, albums) reads from the engine. Still in Swift, to move next: Summary and
the profiles, search with its "remembered" phrases, mixes and Tracks Radio, the scrobble service
(switching it to the Rust request builder), widgets reading the shared index, and replacing the
in-memory `ListeningHistoryReader` so launch and memory no longer scale with history.
