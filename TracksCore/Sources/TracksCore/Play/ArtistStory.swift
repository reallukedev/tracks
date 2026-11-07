import Foundation

/// What the history says about one artist, for the line under their name on their page:
/// "Your No. 3 artist · 412 plays since 2023", and your own top songs by them.
public struct ArtistStory: Sendable, Equatable {
    public let plays: Int
    /// Their place among every artist you've played, all time. Nil past
    /// ``ArtistStories/rankLimit``, where a place stops meaning much.
    public let rank: Int?
    public let firstHeard: Date
    public let lastHeard: Date
    /// Your songs by them, most played first.
    public let topSongs: [MixSong]

    public init(plays: Int, rank: Int?, firstHeard: Date, lastHeard: Date, topSongs: [MixSong]) {
        self.plays = plays
        self.rank = rank
        self.firstHeard = firstHeard
        self.lastHeard = lastHeard
        self.topSongs = topSongs
    }
}

public enum ArtistStories {
    /// Places past this aren't worth saying.
    public static let rankLimit = 50

    /// The story of the artist with this ``CaptureStat/artistIdentity``, or nil if nothing of
    /// theirs has been kept.
    public static func story(of identity: String, in history: ListeningHistory, songLimit: Int = 10) -> ArtistStory? {
        guard !identity.isEmpty else { return nil }
        let counts = plays(in: history)
        guard let mine = counts[identity], mine > 0 else { return nil }
        var first: Date?
        var last: Date?
        for capture in history.captures where capture.credits(identity) {
            if first == nil { first = capture.capturedAt }
            last = capture.capturedAt
        }
        guard let first, let last else { return nil }
        return ArtistStory(
            plays: mine,
            rank: rank(of: identity, in: counts),
            firstHeard: first,
            lastHeard: last,
            topSongs: PlayFacts.songs(byArtist: identity, in: history, limit: songLimit)
        )
    }

    /// Every artist's plays, by ``CaptureStat/artistIdentity``: for a library's list of
    /// artists, and for ranking one of them.
    public static func plays(in history: ListeningHistory) -> [String: Int] {
        var counts: [String: Int] = [:]
        for capture in history.captures {
            for identity in capture.creditIdentities { counts[identity, default: 0] += 1 }
        }
        return counts
    }

    /// 1 for the artist played most. Ties share the better place, as charts do.
    static func rank(of identity: String, in counts: [String: Int]) -> Int? {
        guard let mine = counts[identity], mine > 0 else { return nil }
        let rank = counts.values.filter { $0 > mine }.count + 1
        return rank <= rankLimit ? rank : nil
    }
}
