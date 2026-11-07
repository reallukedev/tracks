import Foundation
import MusicKit
import Observation
import TracksCore

/// Plays captures through MusicKit's player.
///
/// On iOS that's `SystemMusicPlayer`, which hands the queue to the Music app so the play
/// count moves. The in-process `ApplicationMusicPlayer` reaches listening history but never
/// moves the play count (measured on macOS, where it's the only MusicKit player, which is why
/// macOS uses ``MusicAppPlaybackService``).
public struct MusicKitPlaybackService: PlaybackService {
    /// On macOS only tests and the probe use this type, but it still has to compile.
    #if os(iOS)
    private typealias Player = SystemMusicPlayer
    #else
    private typealias Player = ApplicationMusicPlayer
    #endif

    public init() {}

    public func play(songIDs: [String]) async throws {
        guard !songIDs.isEmpty else { throw PlaybackError.nothingToPlay }

        if let subscription = try? await MusicSubscription.current,
           !subscription.canPlayCatalogContent {
            throw PlaybackError.notSubscribed
        }

        let ordered = try await Self.songs(for: songIDs)
        guard !ordered.isEmpty else { throw PlaybackError.nothingToPlay }

        let player = Player.shared
        player.queue = Player.Queue(for: ordered)
        // Needed for the play to reach listening history, on either player.
        player.queue.affectsListeningHistory = true

        do {
            try await player.play()
        } catch {
            Log.playback.error("MusicKit couldn't start playback: \(String(describing: error), privacy: .public)")
            throw PlaybackError.failed(PlaybackFailure(error).words)
        }
    }

    /// Looks the songs up, in the order asked for, leaving out any that can't be found.
    ///
    /// Rows imported from Recently Played have library IDs ("i.aJGY3G9fEGApOQP"), and one of
    /// those in a catalog request fails the whole request, so a day with one import in it
    /// played nothing. Catalog and library IDs go to their own requests, as in
    /// ``CatalogLookup``, and each request failing only loses its own songs. An ID that is
    /// neither is left out, since neither request would take it.
    ///
    /// Throws only when nothing was found and a request failed, so the failure is reported
    /// rather than passed off as nothing to play.
    public static func songs(for songIDs: [String]) async throws -> [Song] {
        var found: [String: Song] = [:]
        var failure: (any Error)?

        let catalogIDs = Array(Set(songIDs.filter(MusicItemIdentity.isCatalogID)))
        if !catalogIDs.isEmpty {
            let request = MusicCatalogResourceRequest<Song>(
                matching: \.id,
                memberOf: catalogIDs.map { MusicItemID($0) }
            )
            do {
                for song in try await request.response().items { found[song.id.rawValue] = song }
            } catch {
                failure = error
            }
        }

        let libraryIDs = Array(Set(songIDs.filter(MusicItemIdentity.isLibraryID)))
        if !libraryIDs.isEmpty {
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.id, memberOf: libraryIDs.map { MusicItemID($0) })
            do {
                for song in try await request.response().items { found[song.id.rawValue] = song }
            } catch {
                failure = failure ?? error
            }
        }

        // Each request returns its own order; keep the caller's.
        let ordered = songIDs.compactMap { found[$0] }
        if ordered.isEmpty, let failure { throw failure }
        return ordered
    }

    /// Follows the player's own queue, so a song counts only when it actually starts.
    public func nowPlayingIDs() -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                let player = Player.shared
                var lastReported: String?
                for await entryID in Observations({ player.queue.currentEntry?.id }) {
                    guard entryID != nil else { continue }
                    guard case .song(let song) = player.queue.currentEntry?.item else { continue }
                    let id = song.id.rawValue
                    guard id != lastReported else { continue }
                    lastReported = id
                    continuation.yield(id)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func pause() async {
        Player.shared.pause()
    }

    public func skipToNext() async throws {
        try await Player.shared.skipToNextEntry()
    }
}
