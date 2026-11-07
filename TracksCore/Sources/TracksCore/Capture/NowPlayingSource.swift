import Foundation

/// The track currently playing, normalised across platforms.
///
/// iOS fills this from `SystemMusicPlayer`'s queue and macOS from Music's `playerInfo`
/// notification. They fill different fields (macOS has no catalog song ID), so identity
/// fields are optional.
public struct NowPlayingObservation: Sendable, Equatable {
    public var title: String
    public var artistName: String
    public var albumTitle: String?
    public var artworkURL: String?

    /// Apple Music catalog ID, when the platform gives one. Always nil on macOS, which
    /// has to search instead. See ``CatalogQuery``.
    public var catalogSongID: String?

    /// Track length. On macOS it comes from `Total Time` (milliseconds) and helps match
    /// catalog search results.
    public var duration: TimeInterval?

    public var playbackState: PlaybackState
    /// Advances on demand, stays at zero on a station. Nil when unknown.
    public var playerPosition: TimeInterval?
    /// Station name, when the platform gives one.
    public var stationName: String?
    /// Whether this came from a station, when the player knows rather than having to guess.
    /// Tracks’ own player on iPhone sets it, since it queued the music itself. Nil everywhere
    /// else, which leaves the decision to ``RadioHeuristic``.
    public var isStation: Bool?
    public var observedAt: Date

    /// Everything the platform reported, verbatim, for the probe and diagnostics.
    public var rawFields: [String: String]

    public init(
        title: String,
        artistName: String,
        albumTitle: String? = nil,
        artworkURL: String? = nil,
        catalogSongID: String? = nil,
        duration: TimeInterval? = nil,
        playbackState: PlaybackState = .playing,
        playerPosition: TimeInterval? = nil,
        stationName: String? = nil,
        isStation: Bool? = nil,
        observedAt: Date = .now,
        rawFields: [String: String] = [:]
    ) {
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.artworkURL = artworkURL
        self.catalogSongID = catalogSongID
        self.duration = duration
        self.playbackState = playbackState
        self.playerPosition = playerPosition
        self.stationName = stationName
        self.isStation = isStation
        self.observedAt = observedAt
        self.rawFields = rawFields
    }

    /// Whether this looks like radio, and how sure we are. See ``RadioHeuristic``.
    public func radioVerdict(userForcedCapture: Bool = false) -> RadioHeuristic.Verdict {
        RadioHeuristic.evaluate(
            .init(
                duration: duration,
                hasComposer: !(rawFields[PlayerInfoKey.composer] ?? "").isEmpty,
                playerPosition: playerPosition,
                entryIdentifier: rawFields["entry.id"].flatMap(QueueEntryIdentifier.init),
                statedStation: isStation,
                userForcedCapture: userForcedCapture
            )
        )
    }

    /// Whether this observation carries enough to identify a track at all.
    public var isIdentifiable: Bool {
        catalogSongID != nil || (!title.isEmpty && !artistName.isEmpty)
    }

    /// Music briefly reports the station as the current track when you tune in, e.g.
    /// `Name = "Apple Music 1"` with no artist or album.
    ///
    /// It's the only source of the station name on macOS (`current stream title` is always
    /// empty), and it must never be captured as a song.
    public var isStationAnnouncement: Bool {
        !title.isEmpty && artistName.isEmpty
    }

    /// The station name, when this observation is announcing one.
    public var announcedStationName: String? {
        isStationAnnouncement ? title : nil
    }

    /// Whether this is worth acting on at all.
    ///
    /// Rejects state-only notifications (just a `Player State`) and station announcements.
    public var isCapturable: Bool {
        playbackState == .playing && isIdentifiable && !isStationAnnouncement
    }

    /// The catalog search for this track. Nil if we already have an ID or can't search.
    public var catalogQuery: CatalogQuery? {
        guard catalogSongID == nil, !title.isEmpty, !artistName.isEmpty else { return nil }
        return CatalogQuery(
            title: title,
            artistName: artistName,
            duration: duration,
            albumTitle: albumTitle
        )
    }
}

public enum PlaybackState: String, Sendable, Equatable, CaseIterable {
    case playing, paused, stopped
}

/// A source of now-playing observations.
///
/// Serves one consumer at a time and can be stopped and started again, which is what
/// pausing and resuming capture does.
public protocol NowPlayingSource: AnyObject, Sendable {
    /// Starts observing and returns the observations from now on.
    ///
    /// Each call hands back a new stream and finishes the previous one. A finished
    /// `AsyncStream` can't be restarted, so a single stream made up front would leave a
    /// resumed consumer iterating one that has already ended.
    func start() -> AsyncStream<NowPlayingObservation>
    /// Stops observing and finishes the stream the last ``start()`` returned.
    func stop()
}
