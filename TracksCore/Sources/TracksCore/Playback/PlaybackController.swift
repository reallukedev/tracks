import Foundation
import Observation
import SwiftData

/// Drives playback and records which captures were played back.
///
/// "Play back" uses those marks to know what's left, and statistics use them to count what
/// the user heard again.
@MainActor
@Observable
public final class PlaybackController {
    public private(set) var isPlaying = false
    public private(set) var lastError: String?
    /// Songs handed to the player in this run.
    public private(set) var queuedCount = 0

    private let store: TracksStore
    private let service: any PlaybackService
    private var progressTask: Task<Void, Never>?

    /// The service is injected so this can live in the MusicKit-free core and be tested.
    public init(store: TracksStore, service: any PlaybackService) {
        self.store = store
        self.service = service
    }

    /// Plays today's captures that have not been played back yet.
    public func playBackToday() async {
        await play((try? store.playBackQueue()) ?? [])
    }

    /// Plays one capture. Every capture row in the app goes through here.
    public func play(_ capture: Capture) async {
        await play([capture])
    }

    /// Plays a single song, for the statistics screens, which hold tallies rather than
    /// captures. Marking still waits for playback to reach the song.
    public func play(_ item: PlaybackItem) async {
        await play([item])
    }

    /// Plays songs in order, for the statistics screens, which hold tallies rather than
    /// captures. Songs the catalog never identified are dropped rather than failing the lot.
    ///
    /// Playing a song this way still counts for today's play-back: when playback reaches
    /// it, the captures of it that "Play back today" would have queued are marked. Nothing
    /// older, and nothing that isn't radio, since those were never owed a play-back.
    public func play(_ items: [PlaybackItem]) async {
        let playable = items.filter { !$0.songID.isEmpty }
        guard !playable.isEmpty else {
            lastError = items.count == 1
                ? String(localized: "That song hasn’t been identified yet.")
                : String(localized: "None of those songs have been identified yet.")
            return
        }
        lastError = nil
        queuedCount = playable.count

        try? store.context.save()
        let songIDs = Set(playable.map(\.songID))
        let owed = ((try? store.playBackQueue()) ?? []).filter { songIDs.contains($0.songID) }
        await start(Self.marks(for: owed)) { try await $0.play(playable) }
    }

    private func play(_ captures: [Capture]) async {
        guard !captures.isEmpty else {
            lastError = String(localized: "Nothing to play back yet.")
            return
        }
        lastError = nil
        queuedCount = captures.count

        // Saved so the identities held below are the ones the rows keep.
        try? store.context.save()
        let items = captures.map {
            PlaybackItem(songID: $0.songID, title: $0.title, artistName: $0.artistName)
        }
        // Not marked yet: `followPlayback` marks each capture when playback reaches it, in
        // case the queue never starts.
        await start(Self.marks(for: captures)) { try await $0.play(items) }
    }

    /// Counts play requests, so one that finishes after a newer one leaves it alone.
    private var latestRequest = 0

    /// Hands the queue to the player and follows it, unless a newer request came in while
    /// the player was starting this one. That one is what's playing, and following this
    /// one instead would stop its songs being marked.
    private func start(
        _ marks: [String: [PersistentIdentifier]],
        playing: (any PlaybackService) async throws -> Void
    ) async {
        latestRequest += 1
        let request = latestRequest
        do {
            try await playing(service)
            guard request == latestRequest else { return }
            isPlaying = true
            followPlayback(marking: marks)
        } catch PlaybackError.openedInMusic {
            guard request == latestRequest else { return }
            isPlaying = false
        } catch {
            guard request == latestRequest else { return }
            isPlaying = false
            lastError = Self.describe(error)
        }
    }

    /// The captures each queued song stands for, by identity rather than by object, since
    /// the rows can be merged away before playback reaches them.
    private static func marks(for captures: [Capture]) -> [String: [PersistentIdentifier]] {
        captures.reduce(into: [:]) { marks, capture in
            guard !capture.songID.isEmpty else { return }
            marks[capture.songID, default: []].append(capture.persistentModelID)
        }
    }

    /// Whether playback is still being followed for a play-back. Read by the tests.
    var isFollowingPlayback: Bool { progressTask != nil }
    /// Tells a finished follow from one that replaced it.
    private var followGeneration = 0

    /// Marks the queued captures played back as the player reaches their songs.
    ///
    /// Only the captures this play-back queued. It used to mark every unmarked capture of the
    /// song, from any day and of any kind, and on iOS it followed the system player for good,
    /// so a song played weeks later from somewhere else marked today's radio capture of it.
    ///
    /// It stops once every queued song has been reached, or when a song that wasn't queued
    /// plays, which means the person has moved on. Except for the very first song reported:
    /// that can be whatever was playing before the queue took over.
    private func followPlayback(marking queued: [String: [PersistentIdentifier]]) {
        progressTask?.cancel()
        progressTask = nil
        followGeneration += 1
        guard !queued.isEmpty else { return }

        let generation = followGeneration
        // Subscribed now rather than inside the task, so a song reached in between is kept.
        let reached = service.nowPlayingIDs()
        progressTask = Task { [weak self] in
            var waiting = queued
            var reports = 0
            for await songID in reached {
                guard !Task.isCancelled, let self else { return }
                reports += 1
                if let ids = waiting.removeValue(forKey: songID) {
                    self.markPlayedBack(ids)
                    if waiting.isEmpty { break }
                } else if queued[songID] == nil, reports > 1 || waiting.count < queued.count {
                    self.isPlaying = false
                    break
                }
            }
            guard let self, self.followGeneration == generation else { return }
            self.progressTask = nil
        }
    }

    private func markPlayedBack(_ ids: [PersistentIdentifier]) {
        let now = Date.now
        for capture in store.existingCaptures(ids).values where capture.playedBackAt == nil {
            capture.playedBackAt = now
        }
        try? store.context.save()
    }

    public func pause() async {
        // A request still starting is no longer the one to follow.
        latestRequest += 1
        await service.pause()
        progressTask?.cancel()
        progressTask = nil
        followGeneration += 1
        isPlaying = false
    }

    /// What went wrong, in words. The error itself only goes to the log.
    static func describe(_ error: any Error) -> String {
        guard let playbackError = error as? PlaybackError else {
            Log.playback.error("Playback failed: \(String(describing: error), privacy: .public)")
            return PlaybackFailure(error).words
        }
        return switch playbackError {
        case .nothingToPlay: String(localized: "Those songs are no longer available in the catalog.")
        case .notSubscribed: PlaybackFailure.noSubscription.words
        // The player has already said it plainly.
        case .failed(let words): words
        case .openedInMusic: String(localized: "Opened in Music.")
        }
    }
}
