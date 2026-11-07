#if os(macOS)
import Foundation
import Synchronization
import MusicKit
import TracksCore

/// Plays captures by handing them to Music.app, so the plays count.
///
/// `ApplicationMusicPlayer` adds plays to Apple's listening history but never moves the play
/// count Music.app shows (tested with both the catalog song and the library copy), and
/// `SystemMusicPlayer` is unavailable on macOS. Music.app playing the same track updates the
/// count within seconds. The songs are already in the library because Tracks added them.
///
/// Tracks sequences the queue itself. Started on a playlist track, Music.app left the playlist
/// after one song and went into Autoplay, so this plays one song at a time and starts the next
/// when it stops. Playback only continues while Tracks is running.
public final class MusicAppPlaybackService: PlaybackService, Sendable {
    /// Read at play time because the playlist can be renamed in Settings.
    private let playlistName: @Sendable () -> String

    private struct Pending: Sendable {
        var remaining: [Song] = []
        var current: Song?
    }

    private struct Song: Sendable, Equatable {
        let id: String
        let title: String
        let artist: String

        var track: MusicLibraryPlayback.Track {
            MusicLibraryPlayback.Track(name: title, artist: artist)
        }
    }

    private let state = Mutex(Pending())
    private let reached = ReachedSongs()
    private let sequencer = TaskSlot()

    public init(playlistName: @escaping @Sendable () -> String) {
        self.playlistName = playlistName
    }

    /// Plays songs by the names Music.app reported when they were captured, which is what
    /// the library search below matches on. No catalog request, so a song imported with a
    /// library ID ("i.…") plays too.
    ///
    /// One song that isn't in the library can't be started, so it's opened in Music instead,
    /// which is as close as the Mac allows. A queue doesn't do that: opening page after page
    /// would bury the person in Music windows.
    public func play(_ items: [PlaybackItem]) async throws {
        let songs = items.map { Song(id: $0.songID, title: $0.title, artist: $0.artistName) }
        if songs.count == 1, let song = songs.first, MusicItemIdentity.isCatalogID(song.id) {
            let playlist = playlistName()
            let location = await ScriptingQueue.run { MusicLibraryPlayback.locate(song.track, inPlaylist: playlist) }
            if case .success(.missing) = location {
                await MainActor.run { _ = MusicLibraryPlayback.openInMusic(songID: song.id) }
                throw PlaybackError.openedInMusic
            }
        }
        try await begin(songs)
    }

    /// Plays songs known only by ID, looking up their names first. Catalog and library IDs
    /// need different requests: the catalog rejects a library ID outright.
    public func play(songIDs: [String]) async throws {
        guard !songIDs.isEmpty else { throw PlaybackError.nothingToPlay }

        var names: [String: (title: String, artist: String)] = [:]
        let catalogIDs = songIDs.filter(MusicItemIdentity.isCatalogID)
        if !catalogIDs.isEmpty {
            let request = MusicCatalogResourceRequest<MusicKit.Song>(
                matching: \.id,
                memberOf: catalogIDs.map { MusicItemID($0) }
            )
            for song in try await request.response().items {
                names[song.id.rawValue] = (song.title, song.artistName)
            }
        }
        let libraryIDs = songIDs.filter(MusicItemIdentity.isLibraryID)
        if !libraryIDs.isEmpty {
            var request = MusicLibraryRequest<MusicKit.Song>()
            request.filter(matching: \.id, memberOf: libraryIDs.map { MusicItemID($0) })
            for song in try await request.response().items {
                names[song.id.rawValue] = (song.title, song.artistName)
            }
        }
        try await begin(songIDs.compactMap { id in
            names[id].map { Song(id: id, title: $0.title, artist: $0.artist) }
        })
    }

    private func begin(_ ordered: [Song]) async throws {
        if let subscription = try? await MusicSubscription.current,
           !subscription.canPlayCatalogContent {
            throw PlaybackError.notSubscribed
        }
        guard let first = ordered.first else { throw PlaybackError.nothingToPlay }

        sequencer.cancel()
        state.withLock {
            $0.remaining = Array(ordered.dropFirst())
            $0.current = nil
        }
        reached.clearBacklog()

        try await start(first)
        startSequencer()
    }

    /// Starts one song. The sequencer only reports it once Music.app is actually playing it,
    /// because Music.app accepts some commands without acting on them (`next track`, for one).
    private func start(_ song: Song) async throws {
        let playlist = playlistName()
        let result = await ScriptingQueue.run {
            MusicLibraryPlayback.play(song.track, inPlaylist: playlist)
        }
        if case .failure(let failure) = result {
            throw PlaybackError.failed(Self.describe(failure, playlist: playlist))
        }
        state.withLock { $0.current = song }
    }

    /// Advances the queue as Music.app finishes each song.
    private func startSequencer() {
        let task = Task { [self] in
            var announced = Set<String>()
            while !Task.isCancelled {
                let playing = await ScriptingQueue.run { MusicLibraryPlayback.currentTrack() }
                let current = state.withLock { $0.current }
                guard let current else { return }

                if let playing, Self.matches(playing, current) {
                    // Music.app is on this song now.
                    if !announced.contains(current.id) {
                        announced.insert(current.id)
                        reached.deliver(current.id)
                    }
                } else if let playing, playing.isStream {
                    // The user started a station, so drop the queue. Without this, a station
                    // started mid play-back was replaced by the next capture three seconds
                    // later and nothing on it was heard or captured.
                    state.withLock { $0.remaining = [] }
                    return
                } else if announced.contains(current.id) {
                    // It played and moved on (finished, or Music.app went into Autoplay).
                    guard let next = state.withLock({ $0.remaining.isEmpty ? nil : $0.remaining.removeFirst() })
                    else {
                        // Queue done. Stop Music.app, or it carries on into Autoplay and
                        // those plays are logged under the user's name too (they showed up
                        // in a friend-activity app).
                        await stopIfStillPlaying()
                        return
                    }
                    try? await start(next)
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        // Replacing cancels the one before: two play-backs started together each start one,
        // and the earlier must not keep driving Music.app.
        sequencer.replace(with: task)
    }

    /// Pauses Music.app once the queue is done, if it's still playing.
    ///
    /// Scripting can't tell Autoplay from a song the user started in the same three-second
    /// window, so that song gets paused too. That's better than leaving Autoplay running.
    private func stopIfStillPlaying() async {
        guard await ScriptingQueue.run({ MusicLibraryPlayback.currentTrack() }) != nil else { return }
        _ = await ScriptingQueue.run { MediaTransportControl.perform(.playPause) }
    }

    public func nowPlayingIDs() -> AsyncStream<String> {
        reached.subscribe()
    }

    public func pause() async {
        sequencer.cancel()
        state.withLock { $0.remaining = [] }
        _ = await ScriptingQueue.run { MediaTransportControl.perform(.playPause) }
    }

    /// Starts the next queued song. Music.app's own `next track` would follow whatever
    /// context it has drifted into instead of Tracks’ queue.
    public func skipToNext() async throws {
        guard let next = state.withLock({ $0.remaining.isEmpty ? nil : $0.remaining.removeFirst() })
        else {
            _ = await ScriptingQueue.run { MediaTransportControl.perform(.next) }
            return
        }
        try await start(next)
    }

    private static func matches(_ playing: MusicLibraryPlayback.Track, _ song: Song) -> Bool {
        normalise(playing.name) == normalise(song.title)
            && normalise(playing.artist) == normalise(song.artist)
    }

    /// Case- and accent-insensitive. Music.app returns the library copy's metadata, which is
    /// usually but not always byte-identical to the catalog's.
    static func normalise(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// What went wrong, in words. Music's own answer to the script only goes to the log.
    static func describe(_ failure: MusicLibraryPlayback.Failure, playlist: String) -> String {
        switch failure {
        case .musicNotRunning:
            return String(localized: "Music isn’t open. Open Music and try again.")
        case .notInLibrary(let title):
            // Music can only be told to play what's in the library, and a song streamed from
            // Apple Music isn't until someone adds it.
            return String(localized: "“\(title)” isn’t in your Music library, so Tracks can’t start it. Add it in Music first.")
        case .scriptFailed(let detail):
            Log.playback.error("Music refused to play a song: \(detail, privacy: .public)")
            return String(localized: "Music couldn’t start the song. Open Music and try again.")
        }
    }
}
#endif
