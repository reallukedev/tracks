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

## HomePod and AirPlay

What a third-party app can do with HomePods, as of iOS 27 and macOS 27. Read from the SDK and
Music's scripting dictionary; the device-only items are marked untested.

- **Mac, Music's speakers.** Music's `AirPlay device` elements and `current AirPlay devices`
  are in the `com.apple.Music.playback` access group (read and write), which the
  scripting-targets entitlement already holds. Each device has `name`, `kind` (`computer`,
  `HomePod`, `Apple TV`, `AirPlay device`, `Bluetooth device`, `TV`, `AirPort Express`),
  `available`, `supports audio`, `selected` (settable, which groups rooms) and
  `sound volume` (0 to 100, settable). Read them as lists, `name of every AirPlay device`,
  one Apple event per property, not per device. Setting `current AirPlay devices` to a list
  plays to those alone. This only moves what Music.app plays. Untested on a sandboxed build
  against a real HomePod.
- **Mac, Tracks' own player.** `ApplicationMusicPlayer` plays inside Tracks, and
  `AVRoutePickerView` without a `player` was reported to leave it on the Mac's speakers on
  macOS 14 (FB13521393, developer forums thread 744128). There is no public API to pick an
  AirPlay output for it. The Mac's sound output in Control Center does move it.
- **iPhone.** No public API chooses a route; only the system's `AVRoutePickerView` can.
  `AVAudioSession.currentRoute.outputs` names the AirPlay receivers (`portType == .airPlay`,
  `portName` is the room) and `routeChangeNotification` says when it changes, so nothing has
  to poll. A HomePod's kind isn't exposed, only its name. Tracks' session is only long-form
  (`.longFormAudio`) while your own music plays; whether the Apple Music player's route
  shows in the app's session otherwise is untested on a device.
- **`AVRouteDetector`** says whether there's anywhere besides the phone to play. Apple says
  detection "significantly increases power consumption", so Tracks enables it only while Your
  Devices is open.
- **Now Playing, Control Center, a HomePod's own controls and Handoff** to a HomePod come
  from `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`. `ApplicationMusicPlayer` fills
  both itself; the local player sets them in `LocalPlayerEngine.activate()`. iOS 26.4 fixed
  the route picker showing "Not Playing" for MusicKit players (forum thread 815154).
- **Siri on a HomePod** ("play X on Tracks") needs SiriKit Media Intents with a cloud
  extension and Media Setup, which is a program Apple admits services to. Not available to
  Tracks.

## SwiftUI on the Mac

- A `MenuBarExtra` with the `.window` style sizes itself to its content, and a `ScrollView`
  has no height of its own, so a scrolling list inside one collapses to nothing. Give the
  window a fixed width and the scrolling part a definite height.

## Notification observers and the main thread

Measured from TestFlight crash reports on iOS 27.2, November 2026.

- `NotificationCenter.addObserver(forName:object:queue:using:)` with `queue: .main` makes the
  posting thread wait until the main thread has run the block. A notification posted from a
  framework's private queue therefore blocks that queue on the main thread.
- MusicKit's first call to the system player (`SystemMusicPlayer.shared`, then
  `nowPlayingAudioFormat`) waits on the main thread for iTunesCloud's account queue. That
  queue writes iTunesCloud's own `UserDefaults` while it starts and posts
  `UserDefaults.didChangeNotification`. An observer of that name with `object: nil` and
  `queue: .main` closes the loop: each waits for the other, and the scene-update watchdog
  kills the app after 10 seconds (0x8BADF00D). CarPlay relaunched Tracks into the same
  deadlock four times in a minute.
- So: observe with `queue: nil` and hop with `Task { @MainActor in ... }` for anything a
  framework can post off the main thread (Core Data and CloudKit changes, iCloud key-value
  changes, `UserDefaults`, audio session, media library, power state). `queue: .main` is only
  for notifications UIKit or AppKit post on the main thread themselves (scene and window
  changes). Always pass the `object` you mean; `UserDefaults.didChangeNotification` with
  `object: nil` hears Apple's frameworks' defaults too.
- The Xcode debugger turns the watchdog off, so this never shows when running from Xcode.
  Test CarPlay connects and lock/unlock with the app launched from the Home Screen.
