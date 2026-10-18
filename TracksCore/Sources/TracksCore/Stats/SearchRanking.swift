import Foundation

/// What a search's Top Result is: the one card above the rest, as Music shows it.
public enum SearchTopKind: Sendable, Equatable {
    case artist, album, song
}

public enum SearchRanking {
    /// The best match for what was typed, given the name of the first artist, album and song
    /// each search found, or nil when there's nothing to show.
    ///
    /// Each is scored by how well its name matches: typed in full, then being typed from its
    /// start ("mara so" for Mara Solis, "midn" for Midnight Bakery), then a later word being
    /// typed from three letters ("sol", "bake"). The best wins, an artist before an album and
    /// an album before a song when they match as well. So "tides" finds the album Tides rather
    /// than the artist Tidesman, and "midn" the album Midnight Bakery over a song that only has
    /// it in its artist's name. With no name matching, the first song.
    public static func topKind(for query: String, artist: String?, album: String?, song: String?) -> SearchTopKind? {
        let term = SearchFolding.fold(query)
        guard !term.isEmpty else { return nil }
        let candidates: [(SearchTopKind, Match)] = [
            (.artist, match(artist, term, allowsMoreAfter: true)),
            (.album, match(album, term)),
            (.song, match(song, term)),
        ]
        // `max` keeps the last of equals, so the first of the best is found by hand.
        var best: (kind: SearchTopKind, match: Match)?
        for (kind, match) in candidates where match > .none && match > (best?.match ?? .none) {
            best = (kind, match)
        }
        if let best { return best.kind }
        return song == nil ? nil : .song
    }

    /// How well a name matches what was typed, worst first.
    enum Match: Int, Comparable {
        case none, laterWord, start, whole

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// - Parameter allowsMoreAfter: an artist's name typed with more after it ("mara solis
    ///   live") still matches from the start.
    static func match(_ name: String?, _ term: String, allowsMoreAfter: Bool = false) -> Match {
        guard let name = name.map(SearchFolding.fold), !name.isEmpty else { return .none }
        if name == term { return .whole }
        if name.hasPrefix(term) || (allowsMoreAfter && term.hasPrefix(name + " ")) { return .start }
        if term.count >= 3, name.split(separator: " ").dropFirst().contains(where: { $0.hasPrefix(term) }) {
            return .laterWord
        }
        return .none
    }
}

/// What was searched for lately, kept as lines in one stored string, newest first.
public enum RecentSearches {
    /// How many are kept.
    public static let limit = 8

    public static func list(_ storage: String) -> [String] {
        storage.split(separator: "\n").map(String.init)
    }

    /// The storage with a search added at the front, each search once whatever its case.
    public static func adding(_ query: String, to storage: String) -> String {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !term.isEmpty else { return storage }
        let kept = [term] + list(storage).filter { $0.caseInsensitiveCompare(term) != .orderedSame }
        return kept.prefix(limit).joined(separator: "\n")
    }

    /// The storage without one search, whatever its case, as adding treats it.
    public static func removing(_ query: String, from storage: String) -> String {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return list(storage).filter { $0.caseInsensitiveCompare(term) != .orderedSame }.joined(separator: "\n")
    }
}
