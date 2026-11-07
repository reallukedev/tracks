import Foundation

/// A shuffle that sounds shuffled.
///
/// A plain random order clumps: three songs by one artist in a row happen all the time, and
/// people hear that as the shuffle being broken. This spreads each artist out as far as the
/// songs allow, and puts anything heard in the last few hours at the end, so pressing Shuffle
/// doesn't open with the song that just finished.
public enum FreshShuffle {
    /// - Parameters:
    ///   - artist: the key to spread apart, usually the folded artist name.
    ///   - recentlyHeard: whether an item was just played. Those go last, still spread out.
    ///   - seed: the same seed gives the same order, for tests and for a mix that shouldn't
    ///     reorder itself every time the page redraws.
    public static func order<Item>(
        _ items: [Item],
        artist: (Item) -> String,
        recentlyHeard: (Item) -> Bool = { _ in false },
        seed: UInt64
    ) -> [Item] {
        var random = SeededGenerator(seed: seed)
        var fresh: [Item] = []
        var stale: [Item] = []
        for item in items.shuffled(using: &random) {
            if recentlyHeard(item) { stale.append(item) } else { fresh.append(item) }
        }
        // The key is worked out once per song. The callers fold names, which is slow enough
        // that calling it inside the placing loop froze a 2,000 song shuffle for seconds.
        let keyedFresh = fresh.map { Keyed(item: $0, key: artist($0)) }
        let keyedStale = stale.map { Keyed(item: $0, key: artist($0)) }
        let freshOrder = spread(keyedFresh, artist: \.key, after: [])
        let tail = freshOrder.suffix(gap(for: keyedFresh, artist: \.key)).map(\.key)
        return (freshOrder + spread(keyedStale, artist: \.key, after: tail)).map(\.item)
    }

    private struct Keyed<Item> {
        let item: Item
        let key: String
    }

    /// Greedy: each place takes the first song whose artist isn't among the last few placed,
    /// or the first song left when every remaining one would repeat.
    static func spread<Item>(_ items: [Item], artist: (Item) -> String, after previous: [String]) -> [Item] {
        let window = gap(for: items, artist: artist)
        var remaining = items
        var placed: [Item] = []
        var recent = Array(previous.suffix(window))
        var counts = Dictionary(items.map { (artist($0), 1) }, uniquingKeysWith: +)
        placed.reserveCapacity(items.count)

        while !remaining.isEmpty {
            // Normally the first free song in the shuffled order. But an artist with more songs
            // left than the rest can separate has to go now, or it ends up in a clump at the end.
            var pick: Int?
            var crowded: (index: Int, left: Int)?
            // When no artist has enough left to crowd, the first free song is the answer and
            // the rest of the list needn't be read.
            let mayCrowd = (counts.values.max() ?? 0) * (window + 1) > remaining.count
            for index in remaining.indices {
                let name = artist(remaining[index])
                guard !recent.contains(name) else { continue }
                if pick == nil {
                    pick = index
                    if !mayCrowd { break }
                }
                let left = counts[name] ?? 0
                if left > (crowded?.left ?? 0) { crowded = (index, left) }
            }
            if let crowded, crowded.left * (window + 1) > remaining.count {
                pick = crowded.index
            }

            let item = remaining.remove(at: pick ?? remaining.startIndex)
            counts[artist(item), default: 1] -= 1
            placed.append(item)
            if window > 0 {
                recent.append(artist(item))
                if recent.count > window { recent.removeFirst() }
            }
        }
        return placed
    }

    /// How many places apart an artist is kept: two, or fewer when there aren't enough
    /// different artists, or one artist has too many songs for the rest to keep it apart.
    static func gap<Item>(for items: [Item], artist: (Item) -> String) -> Int {
        let counts = Dictionary(items.map { (artist($0), 1) }, uniquingKeysWith: +)
        guard let most = counts.values.max(), counts.count > 1 else { return 0 }
        // With `most` songs by one artist, the others fill `most - 1` gaps between them.
        let feasible = most > 1 ? (items.count - most) / (most - 1) : 2
        return max(0, min(2, counts.count - 1, feasible))
    }

    /// A seed that stays the same all day, so a mix keeps its order until tomorrow.
    public static func dailySeed(for date: Date, calendar: Calendar = .current, salt: String = "") -> UInt64 {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        let text = "\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)|\(salt)"
        // FNV-1a: stable across launches, unlike `hashValue`.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
