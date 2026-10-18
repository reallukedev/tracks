import Foundation

/// How Tracks Radio plays: how far it strays from what you know, the genres it leans into, and
/// whether it brings back songs you haven't heard in a while. The person's to set.
public struct RadioTuning: Codable, Sendable, Equatable {
    public enum Discovery: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Songs you love, with a new find now and then.
        case familiar
        /// About one new find in four.
        case balanced
        /// Half new finds.
        case adventurous

        public var id: String { rawValue }

        /// The share of picks that start out as new finds. What you skip moves it from there.
        public var newShare: Double {
            switch self {
            case .familiar: 0.08
            case .balanced: 0.25
            case .adventurous: 0.5
            }
        }
    }

    public var discovery: Discovery
    /// Genre names to lean into, as Apple Music spells them. Empty leans into nothing: the
    /// radio plays across everything.
    public var genres: Set<String>
    /// Songs not heard in three months come up more, recent ones a little less.
    public var bringsBackOldFavorites: Bool

    public init(discovery: Discovery = .balanced, genres: Set<String> = [], bringsBackOldFavorites: Bool = false) {
        self.discovery = discovery
        self.genres = genres
        self.bringsBackOldFavorites = bringsBackOldFavorites
    }

    public static let standard = RadioTuning()

    /// How much likelier a song is under this tuning. Leaning into genres makes the rest rarer
    /// rather than leaving them out, so the radio never runs dry.
    func factor(genre: String?, lastHeard: Date?, now: Date) -> Double {
        var factor = 1.0
        if !genres.isEmpty {
            factor *= genre.map { leansInto($0) } == true ? 4 : 0.2
        }
        if bringsBackOldFavorites, let lastHeard {
            factor *= isBringingBack(lastHeard: lastHeard, now: now) ? 2.5 : 0.7
        }
        return factor
    }

    /// Whether a song last heard then is an old favorite this tuning brings back.
    func isBringingBack(lastHeard: Date, now: Date) -> Bool {
        bringsBackOldFavorites && now.timeIntervalSince(lastHeard) > Self.oldFavoriteAge
    }

    /// How long unheard a song must be to count as an old favorite.
    static let oldFavoriteAge: TimeInterval = 90 * 24 * 60 * 60

    /// The genre picked that takes this one, as it was picked: "Hip-Hop" for "Hip-Hop/Rap".
    /// Nil when it's not one leaned into.
    func leaning(_ genre: String) -> String? {
        let folded = StatsCalculator.folded(genre)
        return genres.sorted().first { folded.contains(StatsCalculator.folded($0)) || StatsCalculator.folded($0).contains(folded) }
    }

    /// Matched by part and without case, so "Hip-Hop" takes "Hip-Hop/Rap".
    func leansInto(_ genre: String) -> Bool {
        leaning(genre) != nil
    }

    /// The genres to offer: the ones you play most, most played first.
    public static func genreChoices(in history: ListeningHistory, limit: Int = 12) -> [String] {
        var plays: [String: Int] = [:]
        var spelling: [String: String] = [:]
        for capture in history.captures {
            guard let genre = history.songMetadata[capture.songIdentity]?.genre, !genre.isEmpty, genre != "Music" else { continue }
            let key = StatsCalculator.folded(genre)
            plays[key, default: 0] += 1
            spelling[key] = genre
        }
        return plays
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .compactMap { spelling[$0.key] }
    }

    // MARK: - Storage

    /// As JSON, for a defaults key. Anything unreadable is the standard tuning.
    public var stored: String {
        (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? ""
    }

    public init(stored: String) {
        self = (try? JSONDecoder().decode(RadioTuning.self, from: Data(stored.utf8))) ?? .standard
    }
}
