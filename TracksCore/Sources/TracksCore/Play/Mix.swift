import Foundation

/// A playlist Tracks builds from the listening history, for the Play tab.
///
/// Apple Music's mixes only see what Apple counted. These see everything Tracks kept: radio,
/// on-demand plays and recovered songs, the hour each was played, and what was skipped.
public struct Mix: Sendable, Equatable, Identifiable {
    public let kind: MixKind
    /// Sequenced, not ranked: artists are spread out, in an order that holds for the day.
    public let songs: [MixSong]
    /// How many plays in the history the mix was drawn from, for its footer.
    public let playCount: Int

    public var id: String { kind.id }

    public init(kind: MixKind, songs: [MixSong], playCount: Int) {
        self.kind = kind
        self.songs = songs
        self.playCount = playCount
    }

    /// The songs the player can find: those the catalog identified.
    public var playableSongs: [MixSong] {
        songs.filter { !$0.songID.isEmpty }
    }

    /// Up to four covers, from different albums where there are enough, for the mix's art.
    /// Albums with a cover come first; one without still has a name to draw a cover from.
    public var covers: [MixCoverArt] {
        var seen = Set<String>()
        var withArt: [MixCoverArt] = []
        var withoutArt: [MixCoverArt] = []
        for song in songs where seen.insert(song.albumKey).inserted {
            let cover = MixCoverArt(url: song.artworkURL, seed: song.albumTitle ?? song.title)
            if cover.url == nil { withoutArt.append(cover) } else { withArt.append(cover) }
            if withArt.count == 4 { break }
        }
        return Array((withArt + withoutArt).prefix(4))
    }
}

/// One cover in a mix's art: its address, and the name a stand-in cover is drawn from.
public struct MixCoverArt: Sendable, Equatable, Hashable {
    public let url: String?
    public let seed: String

    public init(url: String?, seed: String) {
        self.url = url
        self.seed = seed
    }
}

/// Which mix, and what it was built around.
public enum MixKind: Sendable, Equatable, Hashable {
    /// What you play at this time of day, on this kind of day.
    case rightNow(DayPart, isWeekend: Bool)
    /// Your most played lately, weighted to the last couple of weeks.
    case onRepeat
    /// Songs first heard in the last month that you went back to.
    case newFinds
    /// Songs caught on the radio that you've never played yourself.
    case radioFinds
    /// Old favourites you haven't played in months.
    case rediscover
    /// What you were playing around this week, some months ago.
    case throwback(monthsAgo: Int, around: Date)
    /// The most played ever, still in rotation first.
    case allTimeFavorites
    /// Barely heard songs by the artists played most.
    case deepCuts

    public var id: String {
        switch self {
        case .rightNow(let part, let isWeekend): "rightNow.\(part.rawValue).\(isWeekend)"
        case .onRepeat: "onRepeat"
        case .newFinds: "newFinds"
        case .radioFinds: "radioFinds"
        case .rediscover: "rediscover"
        case .throwback(let months, _): "throwback.\(months)"
        case .allTimeFavorites: "allTimeFavorites"
        case .deepCuts: "deepCuts"
        }
    }
}

/// One song in a mix, with the facts the row shows beside it.
public struct MixSong: Sendable, Equatable, Identifiable {
    public let songIdentity: String
    public let songID: String
    public let title: String
    public let artistName: String
    public let albumTitle: String?
    public let artworkURL: String?
    /// Every play in the history.
    public let plays: Int
    public let lastHeard: Date
    /// Apple Music's genre, where it's known: a new find's own, for tuning Tracks Radio.
    public let genre: String?

    public var id: String { songIdentity }

    var artistKey: String { StatsCalculator.folded(artistName) }
    var albumKey: String { albumTitle.map(StatsCalculator.folded) ?? songIdentity }

    public init(
        songIdentity: String,
        songID: String,
        title: String,
        artistName: String,
        albumTitle: String?,
        artworkURL: String?,
        plays: Int,
        lastHeard: Date,
        genre: String? = nil
    ) {
        self.songIdentity = songIdentity
        self.songID = songID
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.artworkURL = artworkURL
        self.plays = plays
        self.lastHeard = lastHeard
        self.genre = genre
    }
}
