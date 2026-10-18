import Foundation

/// Your Party Mix: the songs you play most that suit the party, from the history or from your
/// own music.
public enum PartyMix {
    /// Fewer than this isn't a party's worth, and the page leaves the mix out.
    public static let minimumSongs = 8
    /// About three hours of music.
    public static let length = 50

    /// Songs from the history that suit the party, the most played and most recent, then
    /// sequenced for the day so no artist plays twice in a row. Leaves out songs suggested less
    /// and anything whose genre hasn't been looked up.
    public static func songs(
        for vibe: PartyVibe,
        in history: ListeningHistory,
        signals: ListeningSignals = ListeningSignals(),
        limit: Int = length,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [MixSong] {
        guard !history.isEmpty else { return [] }
        let scored: [(song: MixSong, score: Double)] = MixBuilder.aggregate(history, signals: signals, now: now, calendar: calendar)
            .compactMap { aggregate in
                let metadata = history.songMetadata[aggregate.identity]
                guard vibe.suits(genre: metadata?.genre, year: metadata?.releaseYear, now: now, calendar: calendar) else { return nil }
                return (aggregate.song, LiveMix.weight(plays: aggregate.dates.count, lastHeard: aggregate.lastHeard, now: now))
            }
        let top = scored
            .sorted { $0.score == $1.score ? $0.song.id < $1.song.id : $0.score > $1.score }
            .prefix(limit)
            .map(\.song)
        return FreshShuffle.order(
            Array(top),
            artist: \.artistKey,
            seed: FreshShuffle.dailySeed(for: now, calendar: calendar, salt: "party.\(vibe.rawValue)")
        )
    }

    /// Your own songs that suit the party: the ones you play most, then ones you haven't
    /// played yet, one of each song, sequenced for the day.
    /// - Parameter tracks: the songs that can play now.
    public static func tracks(
        for vibe: PartyVibe,
        from tracks: [LocalTrack],
        history: ListeningHistory,
        signals: ListeningSignals = ListeningSignals(),
        limit: Int = length,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [LocalTrack] {
        let played = Dictionary(
            MixBuilder.aggregate(history, signals: signals, now: now, calendar: calendar).map { ($0.identity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen = Set<String>()
        let scored: [(track: LocalTrack, score: Double)] = tracks
            // A file before a server's copy of the same song.
            .sorted { !$0.isFromServer && $1.isFromServer }
            .compactMap { track in
                let metadata = history.songMetadata[track.identity]
                guard vibe.suits(genre: track.genre ?? metadata?.genre, year: track.year ?? metadata?.releaseYear, now: now, calendar: calendar),
                      !signals.excludes(track.identity, now: now),
                      seen.insert(track.identity).inserted
                else { return nil }
                guard let aggregate = played[track.identity] else { return (track, 0) }
                return (track, LiveMix.weight(plays: aggregate.dates.count, lastHeard: aggregate.lastHeard, now: now))
            }
        let mostPlayed = scored
            .filter { $0.score > 0 }
            .sorted { $0.score == $1.score ? $0.track.id < $1.track.id : $0.score > $1.score }
            .map(\.track)
        // The rest in a fresh order each day, rather than the same few by name.
        let unplayed = FreshShuffle.order(
            scored.filter { $0.score == 0 }.map(\.track).sorted { $0.id < $1.id },
            artist: \.artistKey,
            seed: FreshShuffle.dailySeed(for: now, calendar: calendar, salt: "party.unplayed.\(vibe.rawValue)")
        )
        let top = (mostPlayed + unplayed).prefix(limit)
        return FreshShuffle.order(
            Array(top),
            artist: \.artistKey,
            seed: FreshShuffle.dailySeed(for: now, calendar: calendar, salt: "party.local.\(vibe.rawValue)")
        )
    }
}
