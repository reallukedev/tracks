import Foundation

/// A capture reduced to what the statistics need.
///
/// `Capture` is a SwiftData model and can't leave the main actor, so the views map rows
/// into these before calculating anything.
public struct CaptureStat: Sendable, Equatable {
    public let songKey: String
    /// Catalog id, if the song was resolved. Lets a row in a chart be played.
    public let songID: String
    public let title: String
    public let artistName: String
    public let albumTitle: String?
    public let artworkURL: String?
    public let capturedAt: Date
    public let stationName: String?
    public let playedBackAt: Date?
    public let kind: CaptureKind
    /// Apple Music or Your Music.
    public let source: PlaySource

    /// Folded title and artist. We group on this rather than `songKey` because the key
    /// depends on the device (iOS uses the catalog id, macOS the title and artist), so one
    /// song heard on both would otherwise show up twice in a chart.
    public let songIdentity: String
    /// Everyone the song credits, main artists first: a play of "A & B" counts for both.
    /// From the artist and title, and Apple Music's own list once it's been looked up.
    public let credits: [ArtistCredit]
    /// The first credited artist, folded: whose song it is when one artist is needed, as for
    /// a link from the song's page. Empty for a blank artist.
    public let artistIdentity: String
    /// Album and lead artist together, since plenty of artists have an album called "Home".
    /// The lead alone, so "Umbra feat. Yuki Tanabe" and "Umbra & Mara Solis" count on
    /// Umbra's album.
    public let albumIdentity: String?
    /// Whether the credit could name more than one artist, so Apple Music's list of the
    /// song's artists is worth having.
    public let mayCreditSeveral: Bool

    public init(
        songKey: String,
        songID: String = "",
        title: String,
        artistName: String,
        albumTitle: String? = nil,
        artworkURL: String? = nil,
        capturedAt: Date,
        stationName: String? = nil,
        playedBackAt: Date? = nil,
        kind: CaptureKind = .radio,
        source: PlaySource = .appleMusic
    ) {
        self.songKey = songKey
        self.songID = songID
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.artworkURL = artworkURL
        self.capturedAt = capturedAt
        self.stationName = stationName
        self.playedBackAt = playedBackAt
        self.kind = kind
        self.source = source
        self.songIdentity = HistoryImport.key(title: title, artistName: artistName)
        self.mayCreditSeveral = ArtistCredits.mayCreditSeveral(artist: artistName, title: title)
        self.credits = ArtistCredits.byName(artist: artistName, title: title)
        self.artistIdentity = credits.first?.identity ?? ""
        let album = albumTitle.map(StatsCalculator.folded) ?? ""
        self.albumIdentity = album.isEmpty ? nil : "\(album)\u{1F}\(artistIdentity)"
    }

    /// Every credited artist's identity, main artists first.
    public var creditIdentities: [String] { credits.map(\.identity) }

    /// Whether the song credits the artist with this identity.
    public func credits(_ identity: String) -> Bool {
        credits.contains { $0.identity == identity }
    }

    /// The ``albumIdentity`` of a song on an album, or nil when the album has no name.
    public static func albumIdentity(title: String, artistName: String) -> String? {
        let album = StatsCalculator.folded(title)
        guard !album.isEmpty else { return nil }
        return "\(album)\u{1F}\(leadArtistIdentity(StatsCalculator.folded(artistName)))"
    }

    /// An album identity built from a song's own artist, as a link to an album may be, made
    /// the one plays are grouped by.
    public static func canonicalAlbumIdentity(_ id: String) -> String {
        guard let separator = id.lastIndex(of: "\u{1F}") else { return id }
        let artist = String(id[id.index(after: separator)...])
        return id[..<separator] + "\u{1F}" + leadArtistIdentity(artist)
    }

    /// A folded artist's first credited artist. From the name alone, never Apple Music's
    /// list, so an album link made anywhere finds the same album.
    static func leadArtistIdentity(_ artistIdentity: String) -> String {
        guard ArtistCredits.mayCreditSeveral(artist: artistIdentity) else { return artistIdentity }
        return ArtistCredits.parse(artist: artistIdentity).first?.identity ?? artistIdentity
    }

    /// The same play under another station name, without folding its names again.
    ///
    /// Folding is most of what it costs to make one of these, and a renamed or merged station
    /// can touch thousands of plays at once.
    public func with(stationName: String?) -> CaptureStat {
        guard stationName != self.stationName else { return self }
        return CaptureStat(copying: self, stationName: stationName, credits: credits)
    }

    /// The same play credited otherwise, as Apple Music's list of the song's artists says.
    /// The album stays where the name alone puts it, so a link to it made anywhere finds it.
    func with(credits: [ArtistCredit]) -> CaptureStat {
        CaptureStat(copying: self, stationName: stationName, credits: credits)
    }

    private init(copying other: CaptureStat, stationName: String?, credits: [ArtistCredit]) {
        songKey = other.songKey
        songID = other.songID
        title = other.title
        artistName = other.artistName
        albumTitle = other.albumTitle
        artworkURL = other.artworkURL
        capturedAt = other.capturedAt
        self.stationName = stationName
        playedBackAt = other.playedBackAt
        kind = other.kind
        source = other.source
        songIdentity = other.songIdentity
        self.credits = credits
        artistIdentity = credits.first?.identity ?? ""
        albumIdentity = other.albumIdentity
        mayCreditSeveral = other.mayCreditSeveral
    }
}

public struct SongTally: Sendable, Equatable, Identifiable {
    public let id: String
    public let songKey: String
    public let songID: String
    public let title: String
    public let artistName: String
    public let albumTitle: String?
    public let artworkURL: String?
    public let count: Int
    public let firstHeard: Date
    public let lastHeard: Date
    public let listeningSeconds: TimeInterval
    /// Everyone the song credits, main artists first, for a link to each.
    public let credits: [ArtistCredit]

    public init(
        id: String? = nil,
        songKey: String,
        songID: String,
        title: String,
        artistName: String,
        albumTitle: String? = nil,
        artworkURL: String?,
        count: Int,
        firstHeard: Date,
        lastHeard: Date? = nil,
        listeningSeconds: TimeInterval = 0,
        credits: [ArtistCredit]? = nil
    ) {
        self.credits = credits ?? ArtistCredits.byName(artist: artistName, title: title)
        self.id = id ?? HistoryImport.key(title: title, artistName: artistName)
        self.songKey = songKey
        self.songID = songID
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.artworkURL = artworkURL
        self.count = count
        self.firstHeard = firstHeard
        self.lastHeard = lastHeard ?? firstHeard
        self.listeningSeconds = listeningSeconds
    }
}

public struct ArtistTally: Sendable, Equatable, Identifiable {
    public let id: String
    /// Whichever spelling was seen most often.
    public let name: String
    public let count: Int
    public let songCount: Int
    public let listeningSeconds: TimeInterval
    /// Their picture from Apple Music once it's been looked up, otherwise the cover of
    /// their most played song.
    public let artworkURL: String?
    public let firstHeard: Date
    public let lastHeard: Date

    public init(
        id: String,
        name: String,
        count: Int,
        songCount: Int,
        listeningSeconds: TimeInterval,
        artworkURL: String?,
        firstHeard: Date,
        lastHeard: Date
    ) {
        self.id = id
        self.name = name
        self.count = count
        self.songCount = songCount
        self.listeningSeconds = listeningSeconds
        self.artworkURL = artworkURL
        self.firstHeard = firstHeard
        self.lastHeard = lastHeard
    }
}

public struct AlbumTally: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let artistName: String
    public let count: Int
    public let songCount: Int
    public let artworkURL: String?
    public let listeningSeconds: TimeInterval

    public init(
        id: String,
        title: String,
        artistName: String,
        count: Int,
        songCount: Int,
        artworkURL: String?,
        listeningSeconds: TimeInterval
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.count = count
        self.songCount = songCount
        self.artworkURL = artworkURL
        self.listeningSeconds = listeningSeconds
    }
}

/// An entry in a chart, plus where it was in the previous period's chart.
public struct Ranked<Item: Sendable & Equatable & Identifiable>: Sendable, Equatable, Identifiable
where Item.ID: Sendable {
    public let item: Item
    /// 1-based. Ties share a rank.
    public let rank: Int
    public let previousRank: Int?
    /// False for all time, or when nothing was played last period.
    public let hasPrevious: Bool

    public var id: Item.ID { item.id }

    public init(item: Item, rank: Int, previousRank: Int?, hasPrevious: Bool) {
        self.item = item
        self.rank = rank
        self.previousRank = previousRank
        self.hasPrevious = hasPrevious
    }

    public var movement: ChartMovement {
        guard hasPrevious else { return .none }
        guard let previousRank else { return .new }
        if previousRank > rank { return .up(previousRank - rank) }
        if previousRank < rank { return .down(rank - previousRank) }
        return .same
    }
}

public enum ChartMovement: Sendable, Equatable {
    case new
    case up(Int)
    case down(Int)
    case same
    /// Nothing to compare with.
    case none
}

public struct SessionStat: Sendable, Equatable {
    public let startedAt: Date
    /// `endedAt`, or `lastActivityAt` while the session is still open (same rule as
    /// `Session.duration`).
    public let finishedAt: Date
    public let stationName: String?

    public init(startedAt: Date, finishedAt: Date, stationName: String?) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.stationName = stationName
    }
}

public struct NamedCount: Sendable, Equatable, Identifiable {
    public let name: String
    public let count: Int

    public var id: String { name }

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

public struct TimeBucket: Sendable, Equatable, Identifiable {
    public let start: Date
    public let count: Int
    public let seconds: TimeInterval

    public var id: Date { start }

    public init(start: Date, count: Int, seconds: TimeInterval = 0) {
        self.start = start
        self.count = count
        self.seconds = seconds
    }
}

public struct HourCount: Sendable, Equatable, Identifiable {
    public let hour: Int
    public let count: Int

    public var id: Int { hour }

    public init(hour: Int, count: Int) {
        self.hour = hour
        self.count = count
    }
}

public struct WeekdayCount: Sendable, Equatable, Identifiable {
    /// Calendar numbering: 1 is Sunday regardless of locale.
    public let weekday: Int
    public let count: Int
    public let isWeekend: Bool

    public var id: Int { weekday }

    public init(weekday: Int, count: Int, isWeekend: Bool) {
        self.weekday = weekday
        self.count = count
        self.isWeekend = isWeekend
    }
}

public struct SourceCount: Sendable, Equatable, Identifiable {
    public let kind: CaptureKind
    public let count: Int

    public var id: CaptureKind { kind }

    public init(kind: CaptureKind, count: Int) {
        self.kind = kind
        self.count = count
    }
}

/// Consecutive days with at least one song.
public struct Streak: Sendable, Equatable {
    /// Counts back from today, or from yesterday if nothing has played yet today.
    public let current: Int
    public let longest: Int
    public let currentStart: Date?

    public init(current: Int, longest: Int, currentStart: Date?) {
        self.current = current
        self.longest = longest
        self.currentStart = currentStart
    }

    public static let none = Streak(current: 0, longest: 0, currentStart: nil)
}

public enum ListeningPersona: String, Sendable, Equatable, CaseIterable {
    case nightOwl
    case earlyBird
}

public struct HeatCell: Sendable, Equatable, Identifiable {
    public let weekday: Int
    public let hour: Int
    public let count: Int

    public var id: Int { weekday * 100 + hour }

    public init(weekday: Int, hour: Int, count: Int) {
        self.weekday = weekday
        self.hour = hour
        self.count = count
    }
}
