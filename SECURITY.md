# Security policy

## Reporting a vulnerability

Please report security problems privately through GitHub's private vulnerability reporting by opening the repository's Security tab and clicking "Report a vulnerability", or by going to [the advisory form](https://github.com/reallukedev/tracks/security/advisories/new).

Do not open a public issue, pull request or discussion for a vulnerability.

Please include what you found, how to reproduce it, the platform and OS version, and the commit or release you tested. You can expect an acknowledgement within a week. Tracks is currently maintained by just one person, so a fix may take longer, but you'll be kept informed, and credited in the advisory if you'd like to be.

## Supported versions

Security fixes are made on `main` and included in the next release. Older releases are not patched.

## Scope

Tracks has no account server. What there is to attack is the app, its extensions, the App Clip and the Mac watchdog, the data they keep on the device and in iCloud, and two ways devices talk to each other:

- **Your Devices.** Each device listens on the local network with Bonjour (`_tracks._tcp`), and only accepts TLS with a pre-shared key that the person's devices share through iCloud key-value storage. A way for another device to connect, read what's playing, or send commands without that key is in scope.
- **SharePlay's relay.** Passengers joining by code exchange messages through a Supabase Realtime channel, sealed with AES-GCM under a key derived from the code. A way to read or forge those messages without the code is in scope. The relay's host and publishable key ship inside the app and can be extracted, so the project relies on Supabase's own limits, not on keeping them secret.

The Last.fm session key never expires and is enough by itself to scrobble as the user, so Tracks stores it in the Keychain and not in `UserDefaults` or the App Group container. Any way of getting at it is in scope, whether through another app, an extension that shouldn't have it, a log or crash report, or a request to anywhere other than Last.fm.

The Last.fm API key and shared secret identify the application. They're read from the gitignored `Config/Secrets.xcconfig`, and the tracked `Config/Tracks.xcconfig` leaves them empty. A commit, workflow or build step that would publish them is in scope. Any Last.fm desktop client has to ship its secret inside the app, where it can be extracted, and that alone is a limitation of Last.fm's authentication that Tracks can't fix.

Listening history is stored with SwiftData in an App Group container that only the Tracks widgets share, and mirrored to the user's private CloudKit database. Report anything that lets another app or another iCloud user read it, or that sends it anywhere except the user's iCloud and, if connected, Last.fm.

Passwords for the person's own music servers and the Lidarr API key are stored in the Keychain. Any way of getting at them, or of sending them anywhere but the server they belong to, is in scope.

The Mac app sends Apple events to Music under scripting-target entitlements limited to specific access groups. A way to make Tracks control another app, or run a script, beyond those groups is in scope.

### Out of scope

- Vulnerabilities in Apple's frameworks, Apple Music, iCloud or Last.fm themselves. Please report those to Apple or Last.fm.
- Attacks that need a jailbroken or already-compromised device, or physical access to an unlocked one.
- Missing hardening with no demonstrated impact.

## Keeping your own credentials safe

If you build Tracks yourself, keep your Last.fm key and secret, and the relay's host and key, in `Config/Secrets.xcconfig`, which is gitignored, and never paste them into an issue, a screenshot or a log. If a secret does leak, register a new Last.fm API application and stop using the old one.
