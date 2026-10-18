import Foundation

/// Plays captured songs back through Apple Music, so Apple logs them normally.
///
/// The user actually hears them: nothing here is muted or sped up.
public protocol PlaybackService: Sendable {
    /// Queues the given catalog songs and starts playing.
    func play(songIDs: [String]) async throws
    /// Queues songs known by name as well as ID. A player that finds songs by name (Music.app
    /// on the Mac) uses the names; the default goes by ID.
    func play(_ items: [PlaybackItem]) async throws
    func pause() async
    func skipToNext() async throws

    /// Emits each song ID as playback reaches it.
    ///
    /// Captures are marked played back from this, not at queue time, because a queue can
    /// fail to start or be abandoned.
    func nowPlayingIDs() -> AsyncStream<String>
}

extension PlaybackService {
    public func play(_ items: [PlaybackItem]) async throws {
        try await play(songIDs: items.map(\.songID))
    }
}

/// A song to play: its ID, and the title and artist the player itself reported, which is
/// what Music.app on the Mac knows the track by.
public struct PlaybackItem: Sendable, Equatable {
    public let songID: String
    public let title: String
    public let artistName: String

    public init(songID: String, title: String, artistName: String) {
        self.songID = songID
        self.title = title
        self.artistName = artistName
    }
}

public enum PlaybackError: Error, Sendable, Equatable {
    case nothingToPlay
    case notSubscribed
    /// With what happened in words for the person, as ``PlaybackFailure/words`` puts it.
    /// The error behind it goes to the log, not here.
    case failed(String)
    /// The player couldn't start the song, so it opened it in Music for the person to play.
    /// Not a failure to report: it did what the person asked as far as it could.
    case openedInMusic
}

/// Chooses what "play back" means when the user has not picked anything.
public enum PlaybackSelection {
    /// Today's radio captures not yet played back, oldest first. Rows with no catalog ID
    /// are skipped so they don't fail the whole queue.
    public static func todaysUnplayed(
        from captures: [Capture],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [Capture] {
        let startOfDay = calendar.startOfDay(for: now)
        return captures
            .filter { $0.kind == .radio && $0.capturedAt >= startOfDay && $0.playedBackAt == nil }
            .filter { !$0.songID.isEmpty }
            .sorted { $0.capturedAt < $1.capturedAt }
    }
}
