import Foundation

/// Songs picked for you from a music server, starting from a few artists: some of each one's
/// own songs, then songs like them. A server like Octo answers with songs it can find as well
/// as the ones it has, so a mix works with an empty library and no listening history, as long
/// as there are artists to start from.
public enum ServerMix {
    /// How many artists a mix starts from.
    public static let seedCount = 5

    /// The artists a mix starts from. What you play leads, so the picks follow your taste as it
    /// moves. The artists you picked fill what your listening can't yet, and once it can, keep
    /// one place. Past the three you play most, which of the rest take the remaining places
    /// changes with `rotation`, so a mix wanders around your taste rather than sitting on its
    /// top. Your library's artists fill anything left. Each artist once, however it's cased or
    /// accented.
    /// - Parameter played: the artists you play, most first.
    public static func seeds(picked: [String], played: [String], library: [String], limit: Int = seedCount, rotation: UInt64 = 0) -> [String] {
        func unique(_ names: [String]) -> [String] {
            var seen = Set<String>()
            return names.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && seen.insert(StatsCalculator.folded($0)).inserted }
        }
        let played = unique(played)
        let picked = unique(picked)
        // Enough listening to fill all but one place: the picks keep one; otherwise what's missing.
        let pickedPlaces = picked.isEmpty ? 0 : max(1, limit - played.count)
        let lead = Array(played.prefix(3))
        var random = SeededGenerator(seed: rotation)
        let rest = Array(played.dropFirst(3).prefix(10)).shuffled(using: &random)
        let ordered = unique(lead + picked.prefix(pickedPlaces) + rest + picked + library)
        return Array(ordered.prefix(limit))
    }

    /// Songs you have and new ones woven together, so a list shows both from its first rows:
    /// about one of yours for every two new, as long as both last, then whatever's left. Each
    /// list keeps its own order.
    /// - Parameter ownedShare: the share of the first rows that are yours, from 0 to 1.
    public static func blend<Item>(owned: [Item], new: [Item], ownedShare: Double = 1.0 / 3) -> [Item] {
        guard !owned.isEmpty, !new.isEmpty else { return owned + new }
        let share = min(max(ownedShare, 0.05), 0.95)
        var result: [Item] = []
        var (o, n) = (0, 0)
        while o < owned.count || n < new.count {
            let placed = Double(o) / Double(max(1, o + n))
            if o < owned.count && (n >= new.count || placed <= share) {
                result.append(owned[o]); o += 1
            } else {
                result.append(new[n]); n += 1
            }
        }
        return result
    }

    /// The artists your library has most songs by, most first.
    public static func libraryArtists(_ tracks: [LocalTrack]) -> [String] {
        Dictionary(grouping: tracks, by: \.artistKey)
            .sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
            .compactMap { $0.value.first?.albumArtistName }
    }

    /// One mix from what each artist brought: songs you haven't heard, each once, spread so
    /// the same artist doesn't play twice running, in the same order all day.
    /// - Parameters:
    ///   - found: the songs found for each seed artist, in the order of the seeds.
    ///   - heard: whether you've played a song, by its ``LocalTrack/identity``.
    ///   - seed: the same seed gives the same order.
    public static func mix(_ found: [[LocalTrack]], heard: (String) -> Bool, seed: UInt64, limit: Int = 40) -> [LocalTrack] {
        var seen = Set<String>()
        let fresh = found.joined().filter { !heard($0.identity) && seen.insert($0.identity).inserted }
        return Array(FreshShuffle.order(fresh, artist: \.artistKey, seed: seed).prefix(limit))
    }
}
