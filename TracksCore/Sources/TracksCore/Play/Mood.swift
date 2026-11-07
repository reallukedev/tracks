import Foundation

/// What someone's in the mood for: Apple Music's Moods, with a mix from their own history
/// alongside Apple's playlists and stations for it.
public enum Mood: String, CaseIterable, Sendable, Identifiable {
    case feelGood, energy, workout, focus, chill, love, drive, party, sleep, heartbreak

    public var id: String { rawValue }

    /// What to search Apple Music's catalog for.
    public var searchTerm: String {
        switch self {
        case .feelGood: "Feel Good"
        case .energy: "Energy"
        case .workout: "Workout"
        case .focus: "Focus"
        case .chill: "Chill"
        case .love: "Love Songs"
        case .drive: "Driving"
        case .heartbreak: "Heartbreak"
        case .party: "Party"
        case .sleep: "Sleep"
        }
    }

    /// Parts of Apple Music genre names that suit the mood. The history knows each song's
    /// genre and nothing about its feel, so this is the honest reach of a mood from it.
    var genreHints: [String] {
        switch self {
        case .feelGood: ["pop", "funk", "soul", "disco", "reggae", "k-pop", "motown"]
        case .energy: ["rock", "alternative", "punk", "metal", "hip-hop", "rap", "dance", "electronic"]
        case .workout: ["hip-hop", "rap", "dance", "electronic", "house", "edm", "metal", "hard rock", "drum"]
        case .focus: ["classical", "ambient", "instrumental", "soundtrack", "new age", "lo-fi", "jazz", "piano"]
        case .chill: ["ambient", "lo-fi", "jazz", "r&b", "soul", "singer/songwriter", "acoustic", "chill", "indie"]
        case .love: ["r&b", "soul", "singer/songwriter", "pop", "latin", "k-pop", "vocal"]
        case .drive: ["rock", "alternative", "indie", "country", "hip-hop", "rap", "synth", "electronic", "americana"]
        case .heartbreak: ["singer/songwriter", "alternative", "r&b", "country", "folk", "indie", "blues"]
        case .party: ["dance", "pop", "hip-hop", "rap", "latin", "house", "electronic", "reggaeton", "disco"]
        case .sleep: ["ambient", "classical", "new age", "piano", "sleep", "meditation"]
        }
    }

    func suits(genre: String) -> Bool {
        let folded = StatsCalculator.folded(genre)
        return genreHints.contains { folded.contains($0) }
    }
}

public enum MoodMix {
    /// Under this many songs of your own, a mood leans on new finds.
    public static let fewSongs = 12

    /// Songs from the history in genres that suit the mood, the most played and most recent
    /// first, then sequenced for the day. Leaves out skipped and suggested-less songs, and
    /// anything whose genre hasn't been looked up.
    public static func songs(
        for mood: Mood,
        in history: ListeningHistory,
        signals: ListeningSignals = ListeningSignals(),
        limit: Int = MixBuilder.mixLength,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [MixSong] {
        let top = scored(for: mood, in: history, signals: signals, now: now, calendar: calendar)
            .sorted { $0.score == $1.score ? $0.song.id < $1.song.id : $0.score > $1.score }
            .prefix(limit)
            .map(\.song)
        return FreshShuffle.order(
            Array(top),
            artist: \.artistKey,
            seed: FreshShuffle.dailySeed(for: now, calendar: calendar, salt: "mood.\(mood.rawValue)")
        )
    }

    /// Every song of yours that suits the mood, scored by plays and how recently it was heard.
    static func scored(
        for mood: Mood,
        in history: ListeningHistory,
        signals: ListeningSignals,
        now: Date,
        calendar: Calendar = .current
    ) -> [(song: MixSong, score: Double)] {
        guard !history.isEmpty else { return [] }
        let halfLife: TimeInterval = 120 * 24 * 60 * 60
        return MixBuilder.aggregate(history, signals: signals, now: now, calendar: calendar).compactMap { aggregate in
            guard let genre = history.songMetadata[aggregate.identity]?.genre, mood.suits(genre: genre) else { return nil }
            let recency = pow(0.5, max(0, now.timeIntervalSince(aggregate.lastHeard)) / halfLife)
            return (aggregate.song, log2(1 + Double(aggregate.dates.count)) * (0.5 + recency))
        }
    }
}
