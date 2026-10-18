import Foundation

/// A playlist found for a party, as much as ranking it needs.
public struct PartyPlaylistCandidate: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    /// Made by Apple Music's editors rather than a person or a brand.
    public let isAppleCurated: Bool

    public init(id: String, name: String, isAppleCurated: Bool) {
        self.id = id
        self.name = name
        self.isAppleCurated = isAppleCurated
    }
}

/// Puts the playlists a party's searches found in the order to offer them: the first is the
/// Top Pick.
public enum PartyPlaylistRanking {
    /// - Parameters:
    ///   - results: each search's playlists, searches in the party's order and each search's
    ///     playlists in the order Apple Music gave them.
    ///   - allowsExplicit: the person's setting. With it on, a playlist's clean twin goes;
    ///     with it off, or for All Ages, the twin that isn't clean goes.
    /// - Returns: each playlist once. Apple Music's own first, then the ones more searches
    ///   found, then the ones whose names say more about the party, then as Apple Music
    ///   ordered them. For All Ages, names that say they're clean or for families lead.
    public static func rank(
        _ results: [[PartyPlaylistCandidate]],
        for vibe: PartyVibe,
        allowsExplicit: Bool
    ) -> [PartyPlaylistCandidate] {
        struct Entry {
            let candidate: PartyPlaylistCandidate
            let firstSeen: Int
            var hits: Int
            var bestPosition: Int
        }
        var entries: [String: Entry] = [:]
        var seen = 0
        for list in results {
            // A search that lists one playlist twice still found it once.
            var inThisSearch = Set<String>()
            for (position, candidate) in list.enumerated() where inThisSearch.insert(candidate.id).inserted {
                if var entry = entries[candidate.id] {
                    entry.hits += 1
                    entry.bestPosition = min(entry.bestPosition, position)
                    entries[candidate.id] = entry
                } else {
                    entries[candidate.id] = Entry(candidate: candidate, firstSeen: seen, hits: 1, bestPosition: position)
                    seen += 1
                }
            }
        }

        let prefersClean = vibe == .allAges || !allowsExplicit
        let candidates = entries.values.map(\.candidate)
        let cleanKeys = Set(candidates.filter { PartyNames.isClean($0.name) }.map { PartyNames.twinKey($0.name) })
        let otherKeys = Set(candidates.filter { !PartyNames.isClean($0.name) }.map { PartyNames.twinKey($0.name) })
        let kept = entries.values.filter { entry in
            let name = entry.candidate.name
            let key = PartyNames.twinKey(name)
            if PartyNames.isClean(name) {
                return prefersClean || !otherKeys.contains(key)
            }
            return !prefersClean || !cleanKeys.contains(key)
        }

        return kept.sorted { lhs, rhs in
            if vibe == .allAges {
                let (left, right) = (PartyNames.isFamily(lhs.candidate.name), PartyNames.isFamily(rhs.candidate.name))
                if left != right { return left }
            }
            if lhs.candidate.isAppleCurated != rhs.candidate.isAppleCurated { return lhs.candidate.isAppleCurated }
            if lhs.hits != rhs.hits { return lhs.hits > rhs.hits }
            let (left, right) = (PartyNames.score(lhs.candidate.name, for: vibe), PartyNames.score(rhs.candidate.name, for: vibe))
            if left != right { return left > right }
            if lhs.bestPosition != rhs.bestPosition { return lhs.bestPosition < rhs.bestPosition }
            return lhs.firstSeen < rhs.firstSeen
        }
        .map(\.candidate)
    }

    /// Your own playlists that look like they're for a party, the ones for this party first,
    /// then as they came (most recently changed first, as the library keeps them).
    public static func own<Item>(_ items: [Item], name: (Item) -> String, for vibe: PartyVibe) -> [Item] {
        var found: [(item: Item, order: Int, score: Int)] = []
        for (order, item) in items.enumerated() where PartyNames.looksLikeParty(name(item)) {
            found.append((item, order, PartyNames.score(name(item), for: vibe)))
        }
        found.sort { $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score }
        return found.map(\.item)
    }
}
