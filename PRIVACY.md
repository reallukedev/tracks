# Tracks privacy policy

**Effective date: September 2026**

Tracks is an app for iPhone and Mac that keeps a history of the music you play in Apple
Music and turns it into statistics. This policy explains what Tracks stores, where it stores it,
and what leaves your device.

The short version is that **Tracks DOES NOT collect your data.** Nothing Tracks records is sent to me. The one server Tracks uses is a relay for SharePlay codes, which passes along messages it can't read and keeps none of them. Your listening history lives on your devices and in your own iCloud account. If you choose to connect Last.fm, Tracks sends your listening to your Last.fm account, and nowhere else.

## What Tracks stores, and where

### Your listening history

For each song Tracks records, it keeps the title, artist, album, a link to the album artwork, the Apple Music identifier for the song, when you played it, whether it came from radio, from on-demand listening or from Apple Music's Recently Played list, and which radio station it was heard on. It also keeps whether it has been added to your "Heard on Radio" playlist, played back, or sent to Last.fm. All of this is stored in a database inside the app's own storage on your device. The Tracks widgets read the same database, on the same device.

### A device identifier made by Tracks

Tracks creates a random identifier the first time it runs on a device and stores it with each song recorded on that device. It exists so that two of your devices don't both add the same song to your playlist. It is not your device's serial number or advertising identifier, it can't be used to identify you, and it is only ever stored on your devices and in your iCloud account.

### Your settings

Preferences such as your playlist name, which stations you've excluded, the artists you've blocked, and how the menu bar looks are stored on the device. So is a list of the songs you have deleted, so that Tracks doesn't add them back from Apple Music's Recently Played list, and the songs you skipped. With "Sync with iCloud" on, these sync between your devices, as described under [iCloud](#icloud). Genres, release years and artist pictures looked up in Apple Music are kept on each device, and aren't synced.

### Your Last.fm sign-in, if you connect Last.fm

Your Last.fm username is stored with your settings on the device. The key that lets Tracks scrobble on your behalf is stored in the device's Keychain, the system's secure storage for passwords. Neither is synced to iCloud or sent anywhere except to Last.fm.

### Your history from Motif, if you used Motif

Tracks replaces an earlier app of mine called Motif. On a device that has Motif, Tracks reads
Motif's listening history and a few of its settings (blocked artists, forgotten songs and the
radio playlist) from the storage the two apps share on that device, and copies them into
Tracks. This happens on the device; nothing is sent anywhere, and Motif's own copy isn't
changed. The first device to do it notes that in your iCloud account, so your other devices
get the history through Tracks' sync instead of copying it again.

## iCloud

If you're signed in to iCloud, Tracks syncs your listening history between your devices using your private iCloud database. This is storage in your own iCloud account, provided by Apple under [Apple's privacy policy](https://www.apple.com/legal/privacy/). Only you, and Apple as your iCloud provider, can see what's in it.

Your listening history syncs through your private iCloud database, including your listening sessions, the stations you've heard, and the Tracks device identifier described above.

Your settings sync through iCloud's key-value storage, a small store in your own iCloud account for app preferences. That covers your playlist name and which playlist it is, the stations you've excluded, the artists you've blocked, the songs you've deleted or skipped, whether scrobbling is on, and how the menu bar looks. Two other small things are kept there whether or not sync is on: the key your devices use to find each other for [Your Devices](#your-devices), and, if you used Motif, the name of the device that brought its history over.

What doesn't sync: your Last.fm sign-in, your music servers and their passwords, Lidarr, and the "Sync with iCloud" switch itself, which is set on each device.

You can turn sync off in the Tracks settings ("Sync with iCloud"); the change takes effect the next time Tracks opens. It stops both your history and your settings syncing. You can also stop Tracks using iCloud entirely in your device's iCloud settings.

## Apple Music

With your permission, Tracks uses Apple's MusicKit to:

- See what's playing in Apple Music, so that it can record it
- Read your Recently Played list, so that it can fill in songs you played while Tracks wasn't open
- Look up songs in the Apple Music catalog, so that each recorded song is matched to the right one
- Look up each song's genre and release year, and each artist's picture, for the statistics
- Create a playlist called "Heard on Radio" in your library and add radio songs to it (you can turn this off in settings)
- Play songs, when you use Play Back.

These requests go directly from your device to Apple and are covered by [Apple's privacy policy](https://www.apple.com/legal/privacy/). Nothing Tracks reads from Apple Music is sent elsewhere.

Songs that Tracks has added to your "Heard on Radio" playlist stay there if you delete them from Tracks, because Apple doesn't let apps remove songs from a playlist. You can remove them in the Music app.

You can turn off Apple Music access for Tracks at any time in Settings → Privacy & Security → Media & Apple Music on iPhone, or System Settings → Privacy & Security → Media & Apple Music on Mac.

## Your own music (iPhone and Mac, optional)

If you choose Your Music as the music source, Tracks plays audio files you add to it and songs from music servers you connect yourself, such as Navidrome.

- **Your files** are copied into the app’s own storage on the device. On iPhone, the Files app can see them as On My iPhone › Tracks. Tracks reads their tags and covers to show them, and doesn't send them anywhere.
- **Your servers.** Tracks connects only to the servers you add, directly from your device. The address and username are stored with your settings on the device; the password is stored in the device's Keychain and is never sent: each request carries a token made from it, as the Subsonic API asks. When you play a song from a server, Tracks tells that server, so it can count your plays. Server details aren't synced to iCloud.
- **Downloads** from your servers are kept on your device, left out of iCloud backup, and can be removed at any time in Tracks.
- If a server is on your home network, your device asks your permission for Tracks to reach the local network. You can change your answer in Settings → Privacy & Security → Local Network on iPhone, or System Settings → Privacy & Security → Local Network on Mac.

- **Lidarr**, if you connect it, is reached directly from your device with the address and API key you give. The key is stored in the device's Keychain and sent only to your Lidarr, in a request header. Tracks asks Lidarr what it follows and has, and tells it which artists and albums you ask for.
- **Suggestions** in Your Music look up songs and artists in Apple Music's catalog, as they do with Apple Music, and check each one against your files, your servers and Lidarr, all from your device.

Songs you play from your own music are recorded in your listening history just like Apple Music's.

## Driving (iPhone, optional)

Tracks Radio can follow your drive, and Louder at Speed (below) needs to know you're driving. For these, Tracks asks iOS for Motion & Fitness and uses it only to tell when you're in a car; CarPlay counts too, and needs no permission. Nothing is asked until you start Tracks Radio with "Notice When You're Driving" on, or turn on Louder at Speed. Once allowed, Tracks remembers when each drive started and ended, on that iPhone only, so the radio knows the songs you play on the road. It isn't synced or sent anywhere. You can withdraw access in Settings → Privacy & Security → Motion & Fitness.

## Your speed while driving (iPhone, optional)

Louder at Speed is off until you turn it on. When it's on and you're driving with your own music playing, Tracks asks iOS for your location about once a second and uses only the speed from it, to set how loud the music plays. The location isn't stored, isn't added to your history, and never leaves your iPhone. Tracks stops asking when the drive ends or the music stops. While it's following your speed, iOS shows that Tracks is using your location.

You can turn Louder at Speed off in the Tracks Play settings, and withdraw location access at any time in Settings → Privacy & Security → Location Services.

## Your Devices

Your iPhone and Mac running Tracks find each other on the local network, peer-to-peer Wi-Fi included, so each can show what the other is playing, control it, and hand the music over. They tell each other the device's name, the song playing (title, artist, album, an Apple Music artwork link, and how far in it is), and playback commands. Nothing goes over the internet for this.

Only your own devices can connect: every connection is encrypted with a key your devices share through your iCloud account, so a stranger's Tracks on the same Wi-Fi can't see or reach yours. What anyone on the network can see is that a Tracks device is there, named only "iPhone", "iPad" or "Mac". You can turn this off in the Tracks settings under Devices, and withdraw local network access in your device's Privacy & Security settings.

## On the Mac: controlling Music

On the Mac, Tracks asks Music what is playing and sends it playback commands (play, pause, next, previous) from the menu bar. macOS asks for your permission the first time, and you can change your answer in System Settings → Privacy & Security → Automation.

If you turn on automatic play-back on the Mac, Tracks checks how many seconds have passed since you last used the keyboard, mouse or trackpad before it starts any music, so that it never plays to an empty room. It only reads that number of seconds, never what you typed or clicked, and it doesn't store or send it.

If you turn on "Reopen Tracks If It Quits Unexpectedly" (off by default), a small helper reads the same number when Tracks ends, so it doesn't reopen Tracks you just quit or force quit yourself.

## Last.fm (optional)

Last.fm is a separate service with its own account and its own [privacy policy](https://www.last.fm/legal/privacy). Tracks works fully without it.

If you connect your Last.fm account, Tracks opens Last.fm's website in your browser so you can approve the connection there. Tracks never sees your Last.fm password. From then on, Tracks sends Last.fm the artist, title and album of each song you listen to, and the time you played it ("scrobbling"), plus what's playing right now. These are sent directly from your device to Last.fm over an encrypted connection, to your own Last.fm profile. Songs Tracks found in Apple Music's Recently Played list, rather than saw playing, are only sent if you turn on the setting that allows it.

If you ask Tracks to import your Last.fm history, it reads your scrobbles from Last.fm and adds them to your listening history, which then syncs like the rest of it.

You can turn scrobbling off, or disconnect Last.fm, in the Tracks settings at any time. Disconnecting deletes the Tracks Last.fm key from that device. Scrobbles already sent stay on your Last.fm profile; you can delete them on Last.fm's website.

## Song info

When you choose Get Info on a song, Tracks asks [MusicBrainz](https://musicbrainz.org), the open music encyclopedia, who made it, what it samples and what other recordings of it exist. It sends only the song's identifying code (its ISRC) or, when it has none, its title and artist. Nothing about you or your listening is sent, and MusicBrainz's answers are kept on your device so the same song isn't asked about again. With Last.fm connected, Get Info also asks Last.fm for the song's tags, its wiki summary and similar songs. MusicBrainz has its own [privacy policy](https://metabrainz.org/privacy).

## SharePlay (iPhone, optional)

SharePlay lets the people with you add songs to what's playing on your iPhone. They join in Messages, or by scanning a code Tracks shows on your iPhone or your car's screen.

When someone joins, Tracks tells them the song that's playing and what's coming up (titles, artists, links to Apple Music artwork), and they send the songs they pick. Nothing else is shared: not your listening history, your library or your settings.

People who scan the code connect to your iPhone directly, over Wi-Fi, when they're close by. Tracks also passes these messages through a relay on the internet, for passengers using the Tracks App Clip (which can't connect directly) or whose iPhone can't reach yours that way. The relay runs on [Supabase](https://supabase.com/privacy). Every message is encrypted on the sending iPhone with a key that exists only in the code, so the relay can't read them, and it keeps nothing once they're delivered. It sees a random name for each SharePlay, and, like any server, the IP addresses of the iPhones connected to it. A new code, with a new key, is made each time SharePlay ends.

The Tracks App Clip searches Apple Music with Apple's public search, which needs no sign-in, so a passenger's searches go to Apple.

## What leaves your device

Tracks connects only to:

- **Apple**, for Apple Music (through MusicKit), album artwork, and iCloud sync, and Apple's public music search from the Tracks App Clip
- **Last.fm**, only if you connect your account
- **MusicBrainz**, only when you open a song's info, as described under [Song info](#song-info)
- **Your own music servers and Lidarr**, only the ones you add
- **SharePlay's relay**, only while a SharePlay code is showing or someone has joined with it, as described above
- **Your other devices** on the same local network, as described under [Your Devices](#your-devices)

While Stage or the Halo background is showing, Tracks downloads Apple Music's 30-second preview of each song you play to shape the visualizer to its beat; nothing about you is sent, and the preview is deleted once it's heard.

As with any internet connection, these services can see your device's IP address when Tracks talks to them.

## What Tracks doesn't do

- No analytics, usage tracking or advertising, and no third-party code that does any of these.
- No tracking across apps or websites, and no advertising identifier.
- No accounts: you never sign up for anything to use Tracks.
- Your data is never sold or shared. I don't have it in the first place.

If you've chosen to share analytics with app developers in your device's settings, Apple may send me anonymous crash reports and usage figures for Tracks. That is controlled by Apple and by you, in Settings → Privacy & Security → Analytics & Improvements (or System Settings on Mac), and it never includes your listening history.

## Deleting your data

- **Delete a song:** remove it from your history in Tracks. It is deleted from every device synced through iCloud. Tracks also remembers the deletion, and syncs that too, so it won't add the song back from Recently Played.
- **Stop syncing:** turn off "Sync with iCloud" in the Tracks settings, or turn off iCloud for Tracks in your device's settings. To remove the copy already in iCloud, delete the Tracks data from your iCloud storage settings where your device offers it (Settings → your name → iCloud → Manage Account Storage on iPhone; System Settings → your name → iCloud → Manage on Mac).
- **Disconnect Last.fm:** in the Tracks settings. This removes the Last.fm key from the device. Scrobbles already on Last.fm are managed on Last.fm's website.
- **Delete the app:** removes the Tracks database and settings from that device. Your history remains in iCloud until you delete it there, and on your other devices. On iPhone the system can keep Keychain items after an app is deleted, so disconnect Last.fm in Tracks first if you want its key removed straight away.

## Children

Tracks isn't directed at children and doesn't knowingly collect anything from anyone, of any age.

## Changes to this policy

If the way Tracks handles your data changes, this page will be updated and the effective date above changed. The history of every change is public in the project's [repository](https://github.com/reallukedev/tracks/commits/main/PRIVACY.md).

## Contact

Questions about privacy, or about anything else in Tracks, are welcome as an issue on GitHub: <https://github.com/reallukedev/tracks/issues>. Please don't include personal information in a public issue; if you need to share something privately, open an issue asking for a private contact and I'll reply there.
