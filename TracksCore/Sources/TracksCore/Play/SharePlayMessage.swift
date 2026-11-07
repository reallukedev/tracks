import Foundation

// What Tracks’ SharePlay says. One iPhone, the host, keeps playing (often into the car);
// everyone who joins sees what's on and picks songs for its queue from their own Tracks.
// The host tells the group what's on; a guest asks for a song and hears back whether it
// made it.

/// A song a guest picked, as it travels to the host: by Apple Music's catalog id, and by name
/// for a host playing its own music, which finds songs that way.
public struct SharePlaySong: Codable, Sendable, Hashable {
    public var catalogID: String
    public var title: String
    public var artistName: String
    public var albumTitle: String?
    /// Apple Music's cover. Only ever an address anyone can load.
    public var artworkURL: String?
    public var isExplicit: Bool

    public init(catalogID: String, title: String, artistName: String, albumTitle: String? = nil, artworkURL: String? = nil, isExplicit: Bool = false) {
        self.catalogID = catalogID
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.artworkURL = artworkURL
        self.isExplicit = isExplicit
    }

    /// The key Tracks’ history groups plays by, which ties a row in Up Next back to the
    /// request that put it there, whichever copy of the song the host found.
    public var identity: String { HistoryImport.key(title: title, artistName: artistName) }
}

/// A song in the host's queue, as the group sees it.
public struct SharePlayTrack: Codable, Sendable, Hashable, Identifiable {
    /// The queue entry's id: two copies of one song are two rows.
    public var id: String
    public var title: String
    public var artistName: String
    public var artworkURL: String?
    /// Someone at SharePlay added it.
    public var isFromSharePlay: Bool

    public init(id: String, title: String, artistName: String, artworkURL: String? = nil, isFromSharePlay: Bool = false) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.artworkURL = artworkURL
        self.isFromSharePlay = isFromSharePlay
    }

    public var identity: String { HistoryImport.key(title: title, artistName: artistName) }
}

/// What's on at the host: the song, what's next, and whether there's a queue to add to.
public struct SharePlaySnapshot: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        case appleMusic
        /// The host's own files and servers, where songs are found by name.
        case yourMusic
    }

    public var nowPlaying: SharePlayTrack?
    public var isPlaying: Bool
    /// The first of what's queued, up to ``upNextLimit``.
    public var upNext: [SharePlayTrack]
    /// Everything queued, which can be more than is sent.
    public var upNextCount: Int
    public var source: Source
    /// A station picks as it goes: it has no queue to add to.
    public var isStation: Bool
    /// Off on the host, so an explicit song won't play there.
    public var allowsExplicit: Bool

    /// How much of Up Next travels: enough to see what's coming, small enough to send often.
    public static let upNextLimit = 15

    public init(
        nowPlaying: SharePlayTrack? = nil,
        isPlaying: Bool = false,
        upNext: [SharePlayTrack] = [],
        upNextCount: Int? = nil,
        source: Source = .appleMusic,
        isStation: Bool = false,
        allowsExplicit: Bool = true
    ) {
        self.nowPlaying = nowPlaying
        self.isPlaying = isPlaying
        self.upNext = Array(upNext.prefix(Self.upNextLimit))
        self.upNextCount = max(upNextCount ?? upNext.count, self.upNext.count)
        self.source = source
        self.isStation = isStation
        self.allowsExplicit = allowsExplicit
    }

    /// Whether a song can be added at all right now.
    public var acceptsSongs: Bool { !isStation }

    /// Every song on now or coming up, by identity: what's already on its way.
    public var queuedIdentities: Set<String> {
        Set(([nowPlaying].compactMap(\.self) + upNext).map(\.identity))
    }
}

/// Where a guest's song goes: straight after this one, or at the end.
public enum SharePlayPlacement: String, Codable, Sendable {
    case next, last
}

/// A guest asking for a song.
public struct SharePlayAddRequest: Codable, Sendable, Equatable {
    public var id: UUID
    public var song: SharePlaySong
    public var placement: SharePlayPlacement

    public init(id: UUID = UUID(), song: SharePlaySong, placement: SharePlayPlacement) {
        self.id = id
        self.song = song
        self.placement = placement
    }
}

/// Why a song didn't make it into the host's queue.
public enum SharePlayRefusal: String, Codable, Sendable {
    /// A station is playing, and adding would replace it.
    case station
    /// The host couldn't find it: not in its own music, or gone from Apple Music.
    case notFound
    /// Explicit songs are off on the host.
    case explicit
    /// It's already on or coming up.
    case alreadyQueued
    /// Too many at once from one person.
    case tooMany
    /// The host can't add anything just now: it's switching what it plays from, or its
    /// player failed.
    case unavailable
    /// No answer from the host.
    case noAnswer
}

/// What became of a request.
public enum SharePlayAddOutcome: Codable, Sendable, Equatable {
    case added(SharePlayPlacement)
    case refused(SharePlayRefusal)
}

/// The host's answer to one request.
public struct SharePlayAddReply: Codable, Sendable, Equatable {
    public var requestID: UUID
    public var outcome: SharePlayAddOutcome

    public init(requestID: UUID, outcome: SharePlayAddOutcome) {
        self.requestID = requestID
        self.outcome = outcome
    }
}

/// Everything said in a Tracks SharePlay session.
public enum SharePlayMessage: Codable, Sendable, Equatable {
    /// A guest arriving, asking for what's on.
    case hello
    /// The host saying what's on, whenever it changes and to anyone who arrives.
    case snapshot(SharePlaySnapshot)
    case add(SharePlayAddRequest)
    case reply(SharePlayAddReply)
    /// The host ending it, for guests who joined by its code: a session in Messages says so
    /// itself.
    case ended
}
