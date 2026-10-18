import Foundation

extension LiveMix {
    /// Handpicked: a station made from songs you choose, as Music makes one from a song. Your
    /// picks play in it, and around them the songs most like them: yours by the same artists,
    /// in the same genres and decades, and by the artists you play alongside them, with new
    /// finds like them from outside the history. Picked one at a time, so what you skip steers
    /// it as it steers Tracks Radio.
    ///
    /// It keeps to what's like the picks: a song of yours that shares nothing with them never
    /// comes up, unless too few do, when the nearest of the rest make up the numbers. It never
    /// runs dry, since songs come round again once they've all been heard.
    /// - Parameters:
    ///   - picks: the songs chosen, in the order they were picked.
    ///   - newFinds: songs from outside the history, like the similar artists' own.
    ///   - newFindReasons: why each new find is there, by song identity, for the player to say.
    public static func handpicked(
        _ picks: [MixSong],
        from history: ListeningHistory,
        signals: ListeningSignals = ListeningSignals(),
        newFinds: [MixSong] = [],
        newFindReasons: [String: Reason] = [:],
        now: Date = .now,
        calendar: Calendar = .current,
        seed: UInt64
    ) -> LiveMix {
        let seeds = picks.map { pick in
            let metadata = history.songMetadata[pick.songIdentity]
            return AutoplaySeed(
                songIdentity: pick.songIdentity,
                artistName: pick.artistName,
                genre: pick.genre ?? metadata?.genre,
                releaseYear: metadata?.releaseYear
            )
        }
        let affinity = AutoplayAffinity(seeds: seeds, history: history)
        let picked = Set(picks.map(\.songIdentity))
        let taste = TasteGraph(history: history, now: now)
        let close = closeness(toSeeds: picked, in: taste)
        let rested = now.addingTimeInterval(-restPeriod)

        let scored: [(candidate: Candidate, likeness: Double)] = MixBuilder.aggregate(history, signals: signals, now: now, calendar: calendar)
            .compactMap { aggregate in
                guard !picked.contains(aggregate.identity) else { return nil }
                let metadata = history.songMetadata[aggregate.identity]
                // What you've played with the picks counts as much as what they share on paper.
                let likeness = affinity.likeness(artistName: aggregate.song.artistName, genre: metadata?.genre, releaseYear: metadata?.releaseYear)
                    + seedCloseness * (close[aggregate.identity] ?? 0)
                let candidate = Candidate(
                    song: aggregate.song,
                    weight: weight(plays: aggregate.dates.count, lastHeard: aggregate.lastHeard, now: now) * likeness,
                    isResting: aggregate.lastHeard >= rested,
                    genre: metadata?.genre,
                    releaseYear: metadata?.releaseYear
                )
                return (candidate, likeness)
            }
        let yours = closest(scored)

        // Each pick about as likely as a typical song close to them, so they come round now
        // and then without taking over.
        let typical = median(yours.map(\.weight)) ?? 1
        let picksAsCandidates = picks.map { pick in
            Candidate(song: pick, weight: typical, isResting: pick.lastHeard >= rested)
        }

        let known = picked.union(yours.map(\.song.songIdentity))
        let new = newFinds
            .filter { !known.contains($0.songIdentity) && !signals.excludes($0.songIdentity, now: now) }
            .map { song in
                Candidate(
                    song: song,
                    weight: affinity.likeness(artistName: song.artistName, genre: song.genre, releaseYear: nil),
                    isNew: true,
                    reason: newFindReasons[song.songIdentity] ?? .newFind
                )
            }
        let nearby = yours.count { $0.weight >= 0.5 }
        return LiveMix(
            candidates: picksAsCandidates + yours + new,
            newShare: nearby < handpickedFewClose ? 0.65 : 0.45,
            seed: seed
        )
        .following(history, now: now, graph: taste)
    }

    /// A song of yours at least this like the picks is close to them.
    static let handpickedCloseLikeness = 0.5
    /// Fewer songs of yours close to the picks than this and the nearest others make up the
    /// numbers, so a station from a genre you rarely play still has songs of yours in it.
    static let handpickedMinimum = 20
    /// Fewer close songs of yours than this and new finds take more of the picks.
    static let handpickedFewClose = 15

    /// The songs close to the picks, and if they're too few, the nearest of the rest that share
    /// anything with them at all.
    private static func closest(_ scored: [(candidate: Candidate, likeness: Double)]) -> [Candidate] {
        let close = scored.filter { $0.likeness >= handpickedCloseLikeness }
        guard close.count < handpickedMinimum else { return close.map(\.candidate) }
        let nearest = scored
            .filter { $0.likeness < handpickedCloseLikeness && $0.likeness > AutoplayAffinity.floor }
            .sorted { $0.likeness > $1.likeness }
            .prefix(handpickedMinimum - close.count)
        return (close + nearest).map(\.candidate)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

/// Songs from the history to pick Handpicked's songs from.
public enum HandpickedChoices {
    /// Each song once, the one heard last first.
    public static func recentlyPlayed(
        in history: ListeningHistory,
        signals: ListeningSignals = ListeningSignals(),
        limit: Int = 25,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [MixSong] {
        MixBuilder.aggregate(history, signals: signals, now: now, calendar: calendar)
            .sorted { $0.lastHeard > $1.lastHeard }
            .prefix(limit)
            .map(\.song)
    }

    /// The songs played most, over everything: the most first, the one heard last breaking a tie.
    public static func mostPlayed(
        in history: ListeningHistory,
        signals: ListeningSignals = ListeningSignals(),
        limit: Int = 25,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [MixSong] {
        MixBuilder.aggregate(history, signals: signals, now: now, calendar: calendar)
            .sorted { $0.dates.count == $1.dates.count ? $0.lastHeard > $1.lastHeard : $0.dates.count > $1.dates.count }
            .prefix(limit)
            .map(\.song)
    }
}
