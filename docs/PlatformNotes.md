# Platform notes

What Apple's frameworks actually do, as measured while building Tracks, where it differs from
what you'd expect or isn't documented. Code comments point here. If you measure something new,
add it, with the platform and OS version you saw it on.

## What Apple counts as a play

- Songs heard on an Apple Music radio station don't count as plays in Music. That's why
  Tracks keeps them itself, adds them to "Heard on Radio", and offers Play Back.
- On iOS, `SystemMusicPlayer` hands the queue to Music, so a play moves both the listening
  history behind Recently Played and Replay and the play count in Get Info.
- `ApplicationMusicPlayer` adds to the listening history but never moves the play count.
  Measured on macOS with both the catalog song and the library copy. macOS has no
  `SystemMusicPlayer`, so the Mac plays back through Music itself (`MusicAppPlaybackService`),
  which moves the count within seconds.

## Telling radio from on demand

No API says a song came from a station.

- **iOS.** On iOS 27 a queue entry's identifier is `<queue>::<item>`, and the item half is
  `STREAM` for radio. When it's there it decides on its own. The queue half stays the same
  across a station's songs and changes with the station, which marks a new session. The
  format is undocumented; `QueueEntryIdentifier`'s tests use real ones. MusicKit reports a
  real duration for a radio song once the entry resolves, so duration means nothing on iOS.
- **macOS.** A station track reports no duration: Music's `playerInfo` notification leaves out
  `Total Time`, and AppleScript's `duration of current track` is `missing value`. The player
  position also stays at 0 on a station, and the composer is usually missing. Music drops
  integer keys whose value is zero.
- These were the same for radio and on demand, so they're no use: `cloud status`,
  `current playlist`, `current stream title` and `URL`, `media kind`, and `database ID`.
- Both platforms name a station only when you tune in. Tracks opened mid-station asks
  MusicKit for the most recently played station instead.

The rules are in `RadioHeuristic`, with tests.

## Catalog IDs and artwork

- iOS reads the catalog song ID off the queue entry, so it only searches the catalog for rows
  a Mac synced first.
- macOS gets no ID and no artwork from `playerInfo`, so it searches the catalog for every song,
  and that search is also its only source of covers.

## Recently Played

- The list has no dates, so a recovered song gets the time Tracks found it. Last.fm only gets
  those when the person allows it.
- Each device sees its own list. The point Tracks last read up to is kept per device and
  never synced, or one device would skip real plays and the other import old ones again.

## Scripting Music on the Mac

- A sandboxed app names the library as `library playlist 1 of source 1`. The shorter
  `library playlist 1` is the same playlist, but Music refuses it with -10004
  (`errAEPrivilegeError`) from a sandboxed app.
- -10004 means the script reached outside the access groups in the scripting-targets
  entitlement. Automation being turned off is a different error, -1743.
- A script run from Terminal isn't sandboxed, so it can't reproduce -10004. Test in the app.

## Music's transport controls on the Mac

- On a live radio station, `next track`, `previous track` and `back track` return no error
  and do nothing. Only `playpause` works, so Tracks disables skipping on radio. Only tested
  on a live broadcast; an algorithmic station might accept `next track`.
- Delivered isn't done. To know a skip worked, compare `database ID of current track` before
  and after.
- Addressing Music when it isn't running launches it, so check first.

## SwiftUI on the Mac

- A `MenuBarExtra` with the `.window` style sizes itself to its content, and a `ScrollView`
  has no height of its own, so a scrolling list inside one collapses to nothing. Give the
  window a fixed width and the scrolling part a definite height.
