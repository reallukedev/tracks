# Releasing

Tracks ships through Xcode Cloud. The project is generated, and the credentials live in
secret environment variables, so a release needs nothing on your Mac but a push.

## Before a release

1. Set `MARKETING_VERSION` in `Config/Tracks.xcconfig` if the version people see changes.
   `CURRENT_PROJECT_VERSION` has to go up with every upload.
2. Run `./build.sh ci`. It runs the tests on both platforms and builds both apps unsigned,
   the same as Xcode Cloud's build and test actions.
3. Add the release to `CHANGELOG.md`.
4. Load the Privacy Policy, Support and Source links in Settings › About and check each one
   opens.

## Xcode Cloud

Xcode Cloud runs two scripts from `ci_scripts/`:

- `ci_post_clone.sh` installs XcodeGen, generates `Tracks.xcodeproj`, and writes
  `Config/Secrets.xcconfig` from the workflow's secret environment variables.
- `ci_pre_xcodebuild.sh` stops an archive when any of those variables is empty. Build and
  test actions run without them.

Set these as secret environment variables in each archiving workflow's Environment settings:

| Variable                | What it is                                                  |
| ----------------------- | ----------------------------------------------------------- |
| `TRACKS_LASTFM_API_KEY` | The Last.fm application's API key                           |
| `TRACKS_LASTFM_SECRET`  | The Last.fm application's shared secret                     |
| `TRACKS_RELAY_HOST`     | SharePlay's relay, a Supabase project host with no scheme   |
| `TRACKS_RELAY_KEY`      | That project's publishable key                              |

Without the Last.fm pair, testers see that the build has no Last.fm API key. Without the
relay, the App Clip has no way to reach the host's iPhone.

Xcode Cloud can't register a new identifier. Build the **Tracks (iOS)** scheme for a device
in Xcode once before the first cloud archive, so automatic signing creates the App Clip's App
ID. See "SharePlay by code" in the README.

## Archiving by hand

If you archive in Xcode instead, put the same four values in `Config/Secrets.xcconfig` (start
from `Secrets.example.xcconfig`). `Config/ExportOptions-AppStore.plist` holds the export
settings for `xcodebuild -exportArchive`: upload to App Store Connect, automatic signing, the
production iCloud environment. Change its `teamID` if you aren't the maintainer.

## Checking the archive

Check that the exported app has the production entitlements before you submit:

```sh
codesign -d --entitlements - Tracks.app
```

`aps-environment` should be `production`, and the App Group and iCloud container should be
present. A Mac build without the App Group runs on an in-memory store and keeps nothing.

## App Review notes

Explain these in the review notes, since each draws questions:

- **Arbitrary loads.** Your Music connects to the person's own Subsonic-compatible servers,
  which often run plain HTTP on a home network or a VPN.
- **Background location.** Louder at Speed follows the car's speed to set the volume. It's
  off until turned on in Play settings.
- **The Mac watchdog.** "Reopen Tracks If It Quits Unexpectedly" in Settings › General is
  off by default. When it's on, a small helper reopens Tracks if macOS ends it, but never
  after Quit or Force Quit.
