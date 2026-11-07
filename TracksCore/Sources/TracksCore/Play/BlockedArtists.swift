import Foundation

/// Artists the person never wants to hear: Tracks leaves them out of every mix, Tracks Radio,
/// Autoplay and suggestion, and skips a song of theirs that arrives anyway, from a station or
/// an album. The history and the stats keep what was played before.
///
/// A song is theirs when its artist credits them anywhere: blocking Mara Solis leaves out
/// "Umbra feat. Mara Solis" too. Names are matched whole, ignoring case and accents, so
/// blocking "Air" never touches "Blair".
public struct BlockedArtists: Sendable, Equatable {
    /// The names as they were blocked, for showing: first blocked first.
    public private(set) var names: [String]
    /// The same names, folded, for matching.
    public private(set) var keys: Set<String>

    public init(_ names: [String] = []) {
        var seen = Set<String>()
        self.names = names.filter { name in
            let key = StatsCalculator.folded(name)
            return !key.isEmpty && seen.insert(key).inserted
        }
        keys = seen
    }

    public var isEmpty: Bool { keys.isEmpty }

    /// Whether the artist is blocked, by name alone: only the whole name, not who it credits.
    public func contains(artist name: String) -> Bool {
        keys.contains(StatsCalculator.folded(name))
    }

    /// Whether a song credited to `artist` is by someone blocked.
    public func blocks(songBy artist: String) -> Bool {
        guard !keys.isEmpty else { return false }
        return !keys.isDisjoint(with: LocalTrack.creditedArtists(of: artist))
    }

    /// Whether the song with this identity, as ``HistoryImport/key(title:artistName:)`` makes
    /// it, is by someone blocked.
    public func blocks(songIdentity identity: String) -> Bool {
        guard !keys.isEmpty, let artist = Self.artist(ofIdentity: identity) else { return false }
        return blocks(songBy: artist)
    }

    /// Blocks the artist. Returns false when they already were.
    @discardableResult
    public mutating func block(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = StatsCalculator.folded(trimmed)
        guard !key.isEmpty, keys.insert(key).inserted else { return false }
        names.append(trimmed)
        return true
    }

    /// Unblocks the artist, however their name was cased when blocked.
    public mutating func unblock(_ name: String) {
        let key = StatsCalculator.folded(name)
        guard keys.remove(key) != nil else { return }
        names.removeAll { StatsCalculator.folded($0) == key }
    }

    /// Who a song is by, for blocking from it: its first artist, so a song by "Umbra feat.
    /// Mara Solis" or "Umbra & Mara Solis" offers to block Umbra.
    public static func leadArtist(of credit: String) -> String {
        ArtistCredits.lead(of: credit)
    }

    /// The artist part of a song identity: what follows its separator.
    static func artist(ofIdentity identity: String) -> String? {
        guard let separator = identity.lastIndex(of: "\u{1F}") else { return nil }
        let artist = identity[identity.index(after: separator)...]
        return artist.isEmpty ? nil : String(artist)
    }
}
