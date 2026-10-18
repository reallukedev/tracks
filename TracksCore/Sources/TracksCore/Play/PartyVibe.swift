import Foundation

/// The kind of party someone's having, for finding it a playlist. Party is still a ``Mood`` for
/// Siri, CarPlay and the mood mixes; its page asks which party first.
public enum PartyVibe: String, CaseIterable, Sendable, Identifiable {
    case danceFloor, houseParty, pregame, dinnerParty, backyard, throwback, hipHop, latinNight, allAges

    public var id: String { rawValue }

    /// What to search Apple Music's catalog for, the likeliest first.
    public var searchTerms: [String] {
        switch self {
        case .danceFloor: ["dance party", "party hits", "club hits"]
        case .houseParty: ["house party", "party anthems", "party mix"]
        case .pregame: ["pregame", "pre-party", "turn up"]
        case .dinnerParty: ["dinner party", "cocktail party", "dinner jazz"]
        case .backyard: ["bbq", "summer party", "backyard"]
        case .throwback: ["throwback party", "80s party", "90s party", "2000s party"]
        case .hipHop: ["hip-hop party", "rap party", "hip-hop hits"]
        case .latinNight: ["latin party", "reggaeton party", "fiesta latina"]
        case .allAges: ["kids party", "family party", "clean party"]
        }
    }

    /// Parts of Apple Music genre names that suit the party, as ``Mood`` has them: the history
    /// knows each song's genre and nothing about its feel.
    var genreHints: [String] {
        switch self {
        case .danceFloor: ["dance", "house", "electronic", "edm", "disco", "pop"]
        case .houseParty: ["pop", "dance", "hip-hop", "rap", "r&b", "electronic", "reggaeton", "k-pop"]
        case .pregame: ["hip-hop", "rap", "edm", "dance", "electronic", "trap", "house"]
        case .dinnerParty: ["jazz", "soul", "r&b", "bossa", "vocal", "lounge", "easy listening", "funk", "singer/songwriter"]
        case .backyard: ["reggae", "country", "funk", "soul", "americana", "pop", "rock"]
        case .throwback: ["pop", "dance", "disco", "rock", "r&b", "soul", "funk", "hip-hop", "rap", "new wave"]
        case .hipHop: ["hip-hop", "rap", "trap", "r&b"]
        case .latinNight: ["latin", "reggaeton", "salsa", "bachata", "cumbia", "merengue", "urbano"]
        case .allAges: ["pop", "children", "kids", "soundtrack", "disney", "dance", "k-pop"]
        }
    }

    /// Throwback is about when a song came out as much as what it is: ten years or more.
    public static let throwbackYears = 10

    /// Whether a song suits the party, by its genre and, for Throwback, its year.
    public func suits(genre: String?, year: Int?, now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard let genre else { return false }
        let folded = StatsCalculator.folded(genre)
        guard genreHints.contains(where: { folded.contains($0) }) else { return false }
        guard self == .throwback else { return true }
        guard let year else { return false }
        return year <= calendar.component(.year, from: now) - Self.throwbackYears
    }

    /// Words in a playlist's name that say it's for this party.
    var nameWords: Set<String> {
        Set(searchTerms.flatMap(PartyNames.words)).union(["party"])
    }
}

/// Reading what a playlist's name says about it.
public enum PartyNames {
    /// Words that say a playlist of your own is for a party of some kind.
    static let partyWords: Set<String> = [
        "party", "parties", "dance", "dancing", "club", "pregame", "bbq", "barbecue", "cookout",
        "fiesta", "dinner", "throwback", "throwbacks", "celebration", "birthday", "wedding", "disco",
        "rave", "bangers", "anthems", "hype", "turnup",
    ]

    /// Words that say a playlist is fit for children.
    static let familyWords: Set<String> = ["clean", "family", "kids", "kid", "children", "disney"]

    /// Lowercased words, without accents or punctuation: "Hip-Hop Party (Clean)" is
    /// hip, hop, party, clean.
    static func words(_ name: String) -> [String] {
        StatsCalculator.folded(name)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// Whether a playlist's name says it's for a party.
    public static func looksLikeParty(_ name: String) -> Bool {
        let words = Set(words(name))
        return !words.isDisjoint(with: partyWords) || StatsCalculator.folded(name).lowercased().contains("turn up")
    }

    /// How many of the party's own words the name has.
    public static func score(_ name: String, for vibe: PartyVibe) -> Int {
        Set(words(name)).intersection(vibe.nameWords).count
    }

    static func isClean(_ name: String) -> Bool {
        words(name).contains("clean")
    }

    static func isFamily(_ name: String) -> Bool {
        !Set(words(name)).isDisjoint(with: familyWords)
    }

    /// The name without the words that mark a clean version, so a playlist and its clean twin
    /// come out the same.
    static func twinKey(_ name: String) -> String {
        words(name).filter { !["clean", "version", "edit", "edition"].contains($0) }.joined(separator: " ")
    }
}
