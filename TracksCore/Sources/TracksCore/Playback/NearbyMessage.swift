import Foundation

/// What's playing on one of your devices, as it tells your others nearby.
public struct NearbyState: Codable, Sendable, Equatable {
    public var title: String?
    public var artist: String?
    public var album: String?
    /// A cover anyone can load: Apple Music's. Covers from your own server aren't sent, since
    /// they'd carry its password.
    public var artworkURL: String?
    public var isPlaying: Bool
    /// How far into the song, at `sentAt`, where the device knows.
    public var position: TimeInterval?
    public var duration: TimeInterval?
    public var sentAt: Date
    public var canSkipBack: Bool
    public var canSkipForward: Bool
    /// What the song is playing from: an album, a playlist, a mix. Missing from devices that
    /// came before it.
    public var context: NearbyContext?
    /// The songs coming up after this one, the first few of them.
    public var upNext: [NearbySong]?

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        artworkURL: String? = nil,
        isPlaying: Bool = false,
        position: TimeInterval? = nil,
        duration: TimeInterval? = nil,
        sentAt: Date = .now,
        canSkipBack: Bool = true,
        canSkipForward: Bool = true,
        context: NearbyContext? = nil,
        upNext: [NearbySong]? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.isPlaying = isPlaying
        self.position = position
        self.duration = duration
        self.sentAt = sentAt
        self.canSkipBack = canSkipBack
        self.canSkipForward = canSkipForward
        self.context = context
        self.upNext = upNext
    }

    /// Whether there's a song to show at all.
    public var hasSong: Bool { title?.isEmpty == false }

    /// Where the song is now: moved on by the time since it was sent, while it plays, and no
    /// further than its end.
    public func position(at date: Date) -> TimeInterval? {
        guard let position else { return nil }
        let moved = isPlaying ? max(0, date.timeIntervalSince(sentAt)) : 0
        guard let duration else { return position + moved }
        return min(duration, position + moved)
    }

    /// The same song and state, ignoring the moment it was sent: whether it's worth sending again.
    public func isSame(as other: NearbyState) -> Bool {
        var mine = self
        var theirs = other
        mine.sentAt = .distantPast
        theirs.sentAt = .distantPast
        // A second either way is the same place in the song, once each is moved on to the
        // same moment: a song playing on is the same, a seek isn't.
        if let a = position(at: max(sentAt, other.sentAt)), let b = other.position(at: max(sentAt, other.sentAt)),
           abs(a - b) < 1.5, isPlaying == other.isPlaying {
            mine.position = nil
            theirs.position = nil
        }
        return mine == theirs
    }
}

/// What a song on another device is playing from, as its player names it.
public struct NearbyContext: Codable, Sendable, Equatable {
    /// A ``Kind``'s wire name, kept as text so a kind added later doesn't stop the rest reading.
    public var kindName: String
    public var title: String

    public enum Kind: String, Sendable {
        case station, mix, album, playlist, artist, songs
        /// Tracks Radio or a mood, picked as it plays.
        case endless
    }

    public var kind: Kind? { Kind(rawValue: kindName) }

    public init(kind: Kind, title: String) {
        self.kindName = kind.rawValue
        self.title = title
    }
}

/// A song in another device's Up Next, by name, for this one to find in its own music.
public struct NearbySong: Codable, Sendable, Equatable {
    public var title: String
    public var artist: String
    public var album: String?
    public var duration: TimeInterval?

    public init(title: String, artist: String, album: String? = nil, duration: TimeInterval? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}

/// How a song from another device carries on here.
public enum NearbyCarry: Equatable, Sendable {
    /// The song by itself.
    case song
    /// The song, what it's playing from, and the songs after it. A nil context is named for
    /// the device it came from.
    case queue(NearbyContext?, [NearbySong])
    /// Tracks Radio or a mood, picking again from this song.
    case live(NearbyContext)
}

extension NearbyState {
    /// How many songs of Up Next go along with a song: enough to carry on for an hour, few
    /// enough that Handoff's small message holds them.
    public static let carriedSongs = 15

    /// How this song carries on on the device it moves to. With `bringsQueue` off, or from a
    /// station, whose songs can't be queued, it's the song alone.
    public func carry(bringsQueue: Bool) -> NearbyCarry {
        guard bringsQueue else { return .song }
        let songs = Array((upNext ?? []).prefix(Self.carriedSongs))
        switch context {
        case let context? where context.kind == .station: return .song
        case let context? where context.kind == .endless: return .live(context)
        case let context? where context.kind != .songs && context.kind != nil: return .queue(context, songs)
        // Songs with nothing to name them by, or a kind from a later version, are named for
        // the device they came from.
        default: return songs.isEmpty ? .song : .queue(nil, songs)
        }
    }
}

/// What your devices say to each other.
public enum NearbyMessage: Codable, Sendable, Equatable {
    /// The first thing each side says: who it is. `kind` is a ``NearbyDeviceKind``'s wire
    /// name, missing from devices that came before it.
    case hello(id: String, name: String, platform: String, kind: String? = nil)
    case state(NearbyState)
    case command(TransportCommand)
    /// Asks the other to pause, as the song moves here.
    case pause
    /// Asks the other to move to a point in its song, from its player's scrubber here.
    case seek(TimeInterval)
    /// Hands the other this song to play from where it's got to, as music moves there. It
    /// answers with ``pause`` once it's playing, as a song brought across does.
    case takeOver(NearbyState)
}

extension TransportCommand: Codable {}

/// Messages on the wire: each as JSON behind its length, four bytes, most significant first.
public enum NearbyFraming {
    /// Longer than any message could honestly be: a connection saying otherwise is dropped.
    public static let largest = 256 * 1024

    /// Any message, since SharePlay's code joins use the same framing.
    public static func frame<Message: Encodable>(_ message: Message) throws -> Data {
        let body = try JSONEncoder().encode(message)
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// The length a header gives, or nil for one that isn't four bytes or is too long.
    public static func length(of header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        return length <= largest ? length : nil
    }

    public static func message(from body: Data) throws -> NearbyMessage {
        try message(NearbyMessage.self, from: body)
    }

    public static func message<Message: Decodable>(_ type: Message.Type, from body: Data) throws -> Message {
        try JSONDecoder().decode(type, from: body)
    }
}
