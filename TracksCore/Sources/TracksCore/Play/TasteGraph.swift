import Foundation

/// Which of your songs go together, learned from how you play them: songs heard in the same
/// sitting, a song or two apart, are neighbors, and the more sittings they share the closer they
/// are. It knows what a genre can't: that one song leads into another for you, or that two
/// songs in different genres belong to the same mood of yours.
///
/// Built from the history alone, on this device. Songs played with everything, like an all-time
/// favorite, count for less with each of them, so they don't become everyone's neighbor; songs
/// heard together on a station you didn't choose count for less than ones you played yourself;
/// and older sittings fade, so a pairing from years ago weighs less than one from last month.
public struct TasteGraph: Sendable {
    public struct Neighbor: Sendable, Equatable {
        public let identity: String
        /// How close, from just over 0 to 1 for the song's closest.
        public let closeness: Double
    }

    /// Each song's neighbors, closest first.
    private let neighbors: [String: [Neighbor]]
    /// How often each song has led straight into another, 0 to 1, by "from" then "to".
    private let leadsInto: [String: [String: Double]]

    public static let empty = TasteGraph(neighbors: [:], leadsInto: [:])

    private init(neighbors: [String: [Neighbor]], leadsInto: [String: [String: Double]]) {
        self.neighbors = neighbors
        self.leadsInto = leadsInto
    }

    public var isEmpty: Bool { neighbors.isEmpty }

    /// The song's neighbors, closest first. Empty for a song never heard alongside another.
    public func neighbors(of identity: String) -> [Neighbor] {
        neighbors[identity] ?? []
    }

    /// How close two songs are, 0 when they've never shared a sitting.
    public func closeness(_ identity: String, _ other: String) -> Double {
        neighbors[identity]?.first { $0.identity == other }?.closeness ?? 0
    }

    /// How often `song` has come straight after `previous`, 0 to 1: the flow you've made
    /// yourself, as when an album or a playlist of yours runs one into the next.
    public func leads(from previous: String, into song: String) -> Double {
        leadsInto[previous]?[song] ?? 0
    }

    /// Captures further apart than this are separate sittings.
    static let sittingGap: TimeInterval = 45 * 60
    /// How many songs on, within a sitting, still count as heard together.
    static let reach = 3
    /// Neighbors kept per song.
    static let mostNeighbors = 24
    /// How long it takes a sitting to count half as much.
    static let halfLife: TimeInterval = 365 * 24 * 60 * 60
    /// What a pairing heard on a station counts for, against one you played yourself.
    static let stationWeight = 0.35
    /// What two songs by the same artist count for together: the radio already knows they share
    /// an artist, and what it can't tell from that is worth more.
    static let sameArtistWeight = 0.5
    /// The least a pairing must add up to before it's kept: one sitting long ago isn't a habit.
    static let leastWeight = 0.6

    /// - Parameter keeping: when given, only songs it holds are kept, so a graph for a mix
    ///   carries nothing the mix can't pick.
    public init(history: ListeningHistory, keeping: Set<String>? = nil, now: Date = .now) {
        let captures = history.captures
        guard captures.count > 1 else {
            self = .empty
            return
        }
        // Songs by number, so pairs are cheap to count.
        var index: [String: Int32] = [:]
        var identities: [String] = []
        var artists: [String] = []
        func number(of capture: CaptureStat) -> Int32 {
            if let found = index[capture.songIdentity] { return found }
            let next = Int32(identities.count)
            index[capture.songIdentity] = next
            identities.append(capture.songIdentity)
            artists.append(capture.artistIdentity.isEmpty ? StatsCalculator.folded(capture.artistName) : capture.artistIdentity)
            return next
        }

        var pairs: [UInt64: Double] = [:]
        var leads: [UInt64: Double] = [:]
        var window: [(song: Int32, at: Date, weight: Double)] = []
        for capture in captures {
            if let keeping, !keeping.contains(capture.songIdentity) { continue }
            let song = number(of: capture)
            if let last = window.last, capture.capturedAt.timeIntervalSince(last.at) > Self.sittingGap {
                window.removeAll()
            }
            let age = max(0, now.timeIntervalSince(capture.capturedAt))
            let weight = pow(0.5, age / Self.halfLife) * (capture.kind == .radio ? Self.stationWeight : 1)
            for (distance, earlier) in window.reversed().enumerated() where earlier.song != song {
                let together = min(weight, earlier.weight)
                    / Double(distance + 1)
                    * (artists[Int(earlier.song)] == artists[Int(song)] ? Self.sameArtistWeight : 1)
                pairs[Self.key(earlier.song, song), default: 0] += together
                if distance == 0 { leads[Self.directed(earlier.song, song), default: 0] += together }
            }
            window.append((song, capture.capturedAt, weight))
            if window.count > Self.reach { window.removeFirst() }
        }

        // How much each song pairs in all, for weighing a pairing against how sociable both are.
        var reach = [Double](repeating: 0, count: identities.count)
        for (key, weight) in pairs where weight >= Self.leastWeight {
            reach[Int(key >> 32)] += weight
            reach[Int(key & 0xFFFF_FFFF)] += weight
        }
        var found = [[(Int32, Double)]](repeating: [], count: identities.count)
        for (key, weight) in pairs where weight >= Self.leastWeight {
            let a = Int32(key >> 32), b = Int32(key & 0xFFFF_FFFF)
            // Cosine: a pairing that's a big part of both songs' company is a close one.
            let score = weight / (reach[Int(a)] * reach[Int(b)]).squareRoot()
            found[Int(a)].append((b, score))
            found[Int(b)].append((a, score))
        }
        var neighbors: [String: [Neighbor]] = [:]
        for (song, list) in found.enumerated() where !list.isEmpty {
            let top = list.sorted { $0.1 == $1.1 ? identities[Int($0.0)] < identities[Int($1.0)] : $0.1 > $1.1 }
                .prefix(Self.mostNeighbors)
            guard let best = top.first?.1, best > 0 else { continue }
            neighbors[identities[song]] = top.map { Neighbor(identity: identities[Int($0.0)], closeness: $0.1 / best) }
        }

        var leadsInto: [String: [String: Double]] = [:]
        var leaving = [Double](repeating: 0, count: identities.count)
        for (key, weight) in leads { leaving[Int(key >> 32)] += weight }
        for (key, weight) in leads where weight >= Self.leastWeight {
            let from = Int(key >> 32), to = Int(key & 0xFFFF_FFFF)
            leadsInto[identities[from], default: [:]][identities[to]] = weight / leaving[from]
        }
        self.init(neighbors: neighbors, leadsInto: leadsInto)
    }

    private static func key(_ a: Int32, _ b: Int32) -> UInt64 {
        let (low, high) = a < b ? (a, b) : (b, a)
        return UInt64(UInt32(low)) << 32 | UInt64(UInt32(high))
    }

    private static func directed(_ from: Int32, _ to: Int32) -> UInt64 {
        UInt64(UInt32(from)) << 32 | UInt64(UInt32(to))
    }
}
