import Foundation

/// What someone asked Siri to play, read the way Tracks reads it: where to play it from, and
/// whether it names one of Tracks' own mixes, a mood or a genre rather than something to search.
public enum SpokenMedia {
    /// Where music can come from. Raw values match the app's music source.
    public enum Source: String, Sendable, CaseIterable {
        case appleMusic
        case yourMusic

        public var other: Source { self == .appleMusic ? .yourMusic : .appleMusic }
    }

    /// Splits where to play from off what was asked for: "Bad Guy on Apple Music" is "Bad Guy"
    /// from Apple Music, "Blue from my music" is "Blue" from your own. Siri often leaves these
    /// words in the name. A name that is only the source ("Apple Music") comes back empty.
    public static func source(in name: String) -> (name: String, source: Source?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for (phrase, source) in sourcePhrases {
            if StatsCalculator.folded(trimmed) == phrase { return ("", source) }
            for joiner in [" on ", " from ", " in ", " using ", " with ", " off "] {
                // Matched on the name itself, so what's kept is cut where the words begin
                // whatever folding would have done to the letters before them.
                guard let range = trimmed.range(of: joiner + phrase, options: [.caseInsensitive, .diacriticInsensitive, .anchored, .backwards]) else { continue }
                let kept = trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                return (kept, source)
            }
        }
        return (trimmed, nil)
    }

    /// The sources to look in, in order. One asked for by name is the only one. Otherwise the
    /// one playing goes first, then the other when there's one to switch to, so a song that's
    /// only on Apple Music still plays while your own music is on, and the other way round.
    public static func order(current: Source, asked: Source?, otherAvailable: Bool) -> [Source] {
        if let asked { return [asked] }
        return otherAvailable ? [current, current.other] : [current]
    }

    /// One of Tracks' own mixes by name, however Siri spelled it, as the raw value of the
    /// app's play choice. Only whole names count: "my mix" is a mix, "my mixtape" isn't.
    public static func choice(named name: String) -> String? {
        let folded = StatsCalculator.folded(name)
            .replacingOccurrences(of: "’", with: "'")
        return choiceNames[folded]
    }

    /// A mood heard in what was asked for, as the raw value of the app's play choice, matched
    /// at the start of a word: "something chill", "relaxing music", "a workout playlist". Only
    /// at a word's start, so "unhappy" isn't happy and "brunch" isn't a run.
    public static func mood(in name: String) -> String? {
        let words = StatsCalculator.folded(name).split { !$0.isLetter }
        guard !words.isEmpty else { return nil }
        let spoken = " " + words.joined(separator: " ")
        // The mood said first wins: "sad then happy" is sad.
        return moodStarts
            .compactMap { start, mood in spoken.range(of: " " + start).map { ($0.lowerBound, mood) } }
            .min { $0.0 < $1.0 }?.1
    }

    /// A genre Play has a page for, when that's all that was asked for: "jazz", "some hip hop",
    /// "classical music", "country songs".
    public static func genre(named name: String) -> MusicGenre? {
        var words = StatsCalculator.folded(name)
            .split { $0 == " " || $0 == "-" }
            .map(String.init)
        if words.first == "some" { words.removeFirst() }
        if let last = words.last, ["music", "songs", "tunes"].contains(last) { words.removeLast() }
        guard !words.isEmpty, words.count <= 3 else { return nil }
        let joined = words.joined(separator: "-")
        return MusicGenre.all.first { $0.id == joined || $0.families.contains(joined) }
            ?? MusicGenre.all.first { StatsCalculator.folded($0.name) == words.joined(separator: " ") }
    }

    // MARK: - Words

    private static let sourcePhrases: [(String, Source)] = [
        ("apple music", .appleMusic),
        ("my music", .yourMusic), ("your music", .yourMusic), ("my own music", .yourMusic),
        ("my files", .yourMusic), ("my server", .yourMusic), ("my servers", .yourMusic),
        ("my music server", .yourMusic), ("my downloads", .yourMusic),
    ]

    private static let choiceNames: [String: String] = [
        "tracks radio": "station", "tracks station": "station", "my station": "station", "my radio": "station",
        "my mix": "forYou", "my tracks mix": "forYou",
        "discover": "discover", "something new": "discover", "new music for me": "discover",
        "on repeat": "onRepeat", "my on repeat": "onRepeat",
        "all-time favorites": "favorites", "all time favorites": "favorites", "my favorites": "favorites", "my favourites": "favorites",
        "my favourite songs": "favorites", "my favorite songs": "favorites",
        "deep cuts": "deepCuts", "radio finds": "radioFinds",
        "feel good music": "feelGood", "something upbeat": "feelGood", "energy": "energy",
        "workout music": "workout", "focus music": "focus", "something to focus": "focus",
        "chill music": "chill", "something chill": "chill", "love songs": "love",
        "sad songs": "heartbreak", "heartbreak songs": "heartbreak", "party music": "party",
        "sleep music": "sleep", "something to sleep to": "sleep",
        "driving music": "drive", "something to drive to": "drive", "road trip music": "drive",
    ]

    private static let moodStarts: [(String, String)] = [
        ("chill", "chill"), ("relax", "chill"), ("calm", "chill"), ("mellow", "chill"),
        ("focus", "focus"), ("study", "focus"), ("concentrat", "focus"),
        ("workout", "workout"), ("work out", "workout"), ("gym", "workout"), ("running", "workout"), ("exercis", "workout"),
        ("party", "party"), ("danc", "party"),
        ("sleep", "sleep"), ("bedtime", "sleep"),
        ("love", "love"), ("romantic", "love"),
        ("sad", "heartbreak"), ("heartbr", "heartbreak"), ("breakup", "heartbreak"),
        ("happy", "feelGood"), ("feel good", "feelGood"), ("upbeat", "feelGood"), ("cheerful", "feelGood"),
        ("energ", "energy"), ("pump", "energy"), ("hype", "energy"),
        ("driv", "drive"), ("road trip", "drive"), ("roadtrip", "drive"),
    ]
}
