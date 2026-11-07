import Foundation

/// What the history says about one song, for the player to show beside it.
public struct SongFacts: Sendable, Equatable {
    public let plays: Int
    public let radioPlays: Int
    public let firstHeard: Date
    public let lastHeard: Date

    public init(plays: Int, radioPlays: Int, firstHeard: Date, lastHeard: Date) {
        self.plays = plays
        self.radioPlays = radioPlays
        self.firstHeard = firstHeard
        self.lastHeard = lastHeard
    }
}

/// An artist played a lot lately, for the Play tab's Your Artists.
public struct FavoriteArtist: Sendable, Equatable, Identifiable {
    /// The folded name, as ``CaptureStat/artistIdentity``.
    public let id: String
    /// The spelling heard most recently.
    public let name: String
    public let plays: Int
    /// Their picture, or else the cover of their most recent song that has one.
    public let artworkURL: String?

    public init(id: String, name: String, plays: Int, artworkURL: String?) {
        self.id = id
        self.name = name
        self.plays = plays
        self.artworkURL = artworkURL
    }
}

/// A station the history has songs from.
public struct HeardStation: Sendable, Equatable, Identifiable {
    public let name: String
    public let plays: Int
    public let lastHeard: Date

    public var id: String { name }

    public init(name: String, plays: Int, lastHeard: Date) {
        self.name = name
        self.plays = plays
        self.lastHeard = lastHeard
    }
}

public enum PlayFacts {
    /// Facts for every song, by ``CaptureStat/songIdentity``.
    public static func songs(in history: ListeningHistory) -> [String: SongFacts] {
        var facts: [String: SongFacts] = [:]
        facts.reserveCapacity(history.captures.count / 3)
        // Oldest first, so the first play seen is the first heard.
        for capture in history.captures {
            let isRadio = capture.kind == .radio ? 1 : 0
            if let existing = facts[capture.songIdentity] {
                facts[capture.songIdentity] = SongFacts(
                    plays: existing.plays + 1,
                    radioPlays: existing.radioPlays + isRadio,
                    firstHeard: existing.firstHeard,
                    lastHeard: capture.capturedAt
                )
            } else {
                facts[capture.songIdentity] = SongFacts(
                    plays: 1,
                    radioPlays: isRadio,
                    firstHeard: capture.capturedAt,
                    lastHeard: capture.capturedAt
                )
            }
        }
        return facts
    }

    /// Stations the history has radio songs from, the ones listened to most recently first,
    /// since that's the one likeliest to be wanted again.
    public static func stations(in history: ListeningHistory, limit: Int = 12) -> [HeardStation] {
        var byName: [String: (plays: Int, last: Date)] = [:]
        for capture in history.captures where capture.kind == .radio {
            guard let name = capture.stationName?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            let existing = byName[name]
            byName[name] = ((existing?.plays ?? 0) + 1, capture.capturedAt)
        }
        let stations: [HeardStation] = byName.map { name, heard in
            HeardStation(name: name, plays: heard.plays, lastHeard: heard.last)
        }
        let sorted = stations.sorted { lhs, rhs in
            lhs.lastHeard == rhs.lastHeard ? lhs.name < rhs.name : lhs.lastHeard > rhs.lastHeard
        }
        return Array(sorted.prefix(limit))
    }

    /// The artists played most since `start`, by the spelling seen most recently. For
    /// Discover, which looks up what else they've made.
    public static func topArtists(in history: ListeningHistory, since start: Date, limit: Int = 8) -> [String] {
        var plays: [String: (count: Int, name: String)] = [:]
        for capture in history.captures where capture.capturedAt >= start {
            for credit in capture.credits {
                plays[credit.identity] = ((plays[credit.identity]?.count ?? 0) + 1, credit.name)
            }
        }
        let ranked = plays.sorted { lhs, rhs in
            lhs.value.count == rhs.value.count ? lhs.key < rhs.key : lhs.value.count > rhs.value.count
        }
        return ranked.prefix(limit).map(\.value.name)
    }

    /// The artists played most since `start`, with a picture each.
    /// - Parameter halfLife: when given, how long it takes a play to count half as much, so
    ///   the order follows where your listening is going rather than where it's been. The
    ///   play counts stay counts.
    public static func favoriteArtists(in history: ListeningHistory, since start: Date, limit: Int = 12, halfLife: TimeInterval? = nil, now: Date = .now) -> [FavoriteArtist] {
        var plays: [String: (count: Int, score: Double, name: String, cover: String?)] = [:]
        for capture in history.captures where capture.capturedAt >= start {
            let weight = halfLife.map { pow(0.5, max(0, now.timeIntervalSince(capture.capturedAt)) / $0) } ?? 1
            for credit in capture.credits {
                let existing = plays[credit.identity]
                plays[credit.identity] = (
                    (existing?.count ?? 0) + 1,
                    (existing?.score ?? 0) + weight,
                    credit.name,
                    capture.artworkURL ?? existing?.cover
                )
            }
        }
        return plays
            .sorted { lhs, rhs in lhs.value.score == rhs.value.score ? lhs.key < rhs.key : lhs.value.score > rhs.value.score }
            .prefix(limit)
            .map { identity, value in
                FavoriteArtist(
                    id: identity,
                    name: value.name,
                    plays: value.count,
                    artworkURL: history.artistArtwork[identity] ?? value.cover
                )
            }
    }

    /// An artist's songs, most played first, for playing them from their tile.
    public static func songs(byArtist identity: String, in history: ListeningHistory, limit: Int = 50) -> [MixSong] {
        var counts: [String: (count: Int, song: MixSong)] = [:]
        for capture in history.captures where capture.credits(identity) {
            let count = (counts[capture.songIdentity]?.count ?? 0) + 1
            let earlier = counts[capture.songIdentity]?.song
            counts[capture.songIdentity] = (count, MixSong(
                songIdentity: capture.songIdentity,
                songID: capture.songID.isEmpty ? earlier?.songID ?? "" : capture.songID,
                title: capture.title,
                artistName: capture.artistName,
                albumTitle: capture.albumTitle ?? earlier?.albumTitle,
                artworkURL: capture.artworkURL ?? earlier?.artworkURL,
                plays: count,
                lastHeard: capture.capturedAt
            ))
        }
        return counts.values
            .sorted { lhs, rhs in lhs.count == rhs.count ? lhs.song.id < rhs.song.id : lhs.count > rhs.count }
            .prefix(limit)
            .map(\.song)
    }
}
