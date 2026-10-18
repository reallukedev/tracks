import Foundation

/// A song Autoplay follows on from: one of the last few the queue played.
public struct AutoplaySeed: Sendable, Equatable {
    public let songIdentity: String
    public let artistName: String
    /// Apple Music's genre, where the player knows it. The history's is used otherwise.
    public let genre: String?
    public let releaseYear: Int?

    public init(songIdentity: String, artistName: String, genre: String? = nil, releaseYear: Int? = nil) {
        self.songIdentity = songIdentity
        self.artistName = artistName
        self.genre = genre
        self.releaseYear = releaseYear
    }
}

extension LiveMix {
    /// Autoplay, as Music's ∞ plays once a queue runs out: songs like the last few played,
    /// picked one at a time so skips steer it as they steer Tracks Radio.
    ///
    /// "Like" is what the history can say: the same artists, their genres and decades, and the
    /// artists you play in the same sitting as them. Every other song of yours can still come
    /// up, far less often, so it never runs dry.
    /// - Parameter newFinds: songs from outside the history, like the similar artists' own.
    public static func autoplay(
        after seeds: [AutoplaySeed],
        from history: ListeningHistory,
        signals: ListeningSignals = ListeningSignals(),
        newFinds: [MixSong] = [],
        now: Date = .now,
        calendar: Calendar = .current,
        seed: UInt64
    ) -> LiveMix {
        let affinity = AutoplayAffinity(seeds: seeds, history: history)
        let seedIdentities = Set(seeds.map(\.songIdentity))
        let taste = TasteGraph(history: history, now: now)
        let close = closeness(toSeeds: seedIdentities, in: taste)
        let rested = now.addingTimeInterval(-restPeriod)
        let yours: [Candidate] = MixBuilder.aggregate(history, signals: signals, now: now, calendar: calendar).compactMap { aggregate in
            guard !seedIdentities.contains(aggregate.identity) else { return nil }
            let metadata = history.songMetadata[aggregate.identity]
            let likeness = affinity.likeness(artistName: aggregate.song.artistName, genre: metadata?.genre, releaseYear: metadata?.releaseYear)
            return Candidate(
                song: aggregate.song,
                weight: weight(plays: aggregate.dates.count, lastHeard: aggregate.lastHeard, now: now)
                    * likeness * (1 + seedCloseness * (close[aggregate.identity] ?? 0)),
                isResting: aggregate.lastHeard >= rested,
                genre: metadata?.genre,
                releaseYear: metadata?.releaseYear
            )
        }
        let known = Set(yours.map(\.song.songIdentity)).union(seedIdentities)
        let new: [Candidate] = newFinds
            .filter { !known.contains($0.songIdentity) && !signals.excludes($0.songIdentity, now: now) }
            .map { song in
                Candidate(song: song, weight: affinity.likeness(artistName: song.artistName, genre: song.genre, releaseYear: nil), isNew: true)
            }
        return LiveMix(candidates: yours + new, newShare: affinity.newShare(closeMatches: yours), seed: seed)
            .following(history, now: now, leaningToward: seeds.map(\.songIdentity), graph: taste)
    }
}

/// How like the seeds a song is, from what the history knows.
struct AutoplayAffinity: Sendable {
    /// Songs that share nothing with the seeds keep this much, so Autoplay never runs dry.
    static let floor = 0.04
    /// Captures further apart than this are separate sittings.
    static let sittingGap: TimeInterval = 45 * 60

    private let artists: Set<String>
    /// The share of seeds in each genre family and decade, 0 to 1.
    private let genres: [String: Double]
    private let decades: [Int: Double]
    /// How often each artist is played in the same sitting as the seeds' artists, 0 to 1.
    private let alongside: [String: Double]

    init(seeds: [AutoplaySeed], history: ListeningHistory) {
        let artists = Set(seeds.map { StatsCalculator.folded($0.artistName) })
        self.artists = artists
        var genres: [String: Double] = [:]
        var decades: [Int: Double] = [:]
        for seed in seeds {
            let metadata = history.songMetadata[seed.songIdentity]
            if let genre = (seed.genre ?? metadata?.genre).flatMap(LiveMix.genreKey) { genres[genre, default: 0] += 1 }
            if let year = seed.releaseYear ?? metadata?.releaseYear { decades[year / 10 * 10, default: 0] += 1 }
        }
        let count = Double(max(1, seeds.count))
        self.genres = genres.mapValues { $0 / count }
        self.decades = decades.mapValues { $0 / count }
        self.alongside = Self.alongside(artists, in: history)
    }

    /// Between ``floor`` and a little over 4: the same artist, the seeds' genres, the artists
    /// played with them, and their decades, in that order of weight.
    func likeness(artistName: String, genre: String?, releaseYear: Int?) -> Double {
        let artist = StatsCalculator.folded(artistName)
        var likeness = Self.floor
        if artists.contains(artist) { likeness += 0.9 }
        if let key = genre.flatMap(LiveMix.genreKey) { likeness += 1.6 * (genres[key] ?? 0) }
        likeness += 1.4 * (alongside[artist] ?? 0)
        if let year = releaseYear { likeness += 0.4 * (decades[year / 10 * 10] ?? 0) }
        return likeness
    }

    /// New finds for a quarter of the picks, or half when few of your songs are close.
    func newShare(closeMatches yours: [LiveMix.Candidate]) -> Double {
        let close = yours.count { $0.weight >= 0.5 }
        return close < 15 ? 0.5 : 0.25
    }

    /// Artists heard in the same sittings as `artists`, by how many sittings, the most 1.
    static func alongside(_ artists: Set<String>, in history: ListeningHistory) -> [String: Double] {
        guard !artists.isEmpty, !history.captures.isEmpty else { return [:] }
        let captures = history.captures.sorted { $0.capturedAt < $1.capturedAt }
        var counts: [String: Int] = [:]
        var sitting = Set<String>()
        var last = captures[0].capturedAt
        func close() {
            if !sitting.isDisjoint(with: artists) {
                for artist in sitting where !artists.contains(artist) { counts[artist, default: 0] += 1 }
            }
            sitting = []
        }
        for capture in captures {
            if capture.capturedAt.timeIntervalSince(last) > sittingGap { close() }
            sitting.insert(StatsCalculator.folded(capture.artistName))
            last = capture.capturedAt
        }
        close()
        guard let most = counts.values.max(), most > 0 else { return [:] }
        return counts.mapValues { Double($0) / Double(most) }
    }
}
