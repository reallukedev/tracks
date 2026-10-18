import Foundation

/// What a library item is put in order and found by: its names, its dates and your plays.
/// Made from an Apple Music item or a song of your own, so the library's pages sort and filter
/// the same way whatever the music is.
public struct LibrarySortKeys: Sendable, Equatable {
    public var title: String
    public var artist: String
    public var album: String
    /// When it came into the library.
    public var added: Date?
    /// When it was last played, as the library knows it.
    public var played: Date?
    /// When it came out.
    public var released: Date?
    /// Seconds; zero when it isn't known.
    public var duration: TimeInterval
    /// Your plays, from Tracks’ history.
    public var plays: Int

    public init(
        title: String,
        artist: String = "",
        album: String = "",
        added: Date? = nil,
        played: Date? = nil,
        released: Date? = nil,
        duration: TimeInterval = 0,
        plays: Int = 0
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.added = added
        self.played = played
        self.released = released
        self.duration = duration
        self.plays = plays
    }
}

/// The order a library page is in: a field, and which way. Stored as "title.ascending".
public struct LibraryOrder: Hashable, Sendable, RawRepresentable {
    public enum Field: String, CaseIterable, Sendable {
        case title, artist, album, time, plays, added, played, year

        /// Names read A to Z; everything else starts from the biggest or newest.
        public var isName: Bool {
            switch self {
            case .title, .artist, .album: true
            case .time, .plays, .added, .played, .year: false
            }
        }
    }

    public var field: Field
    public var ascending: Bool

    public init(_ field: Field, ascending: Bool) {
        self.field = field
        self.ascending = ascending
    }

    /// The order a field starts in when it's first chosen: names A to Z, numbers and dates
    /// biggest and newest first.
    public static func natural(_ field: Field) -> LibraryOrder {
        LibraryOrder(field, ascending: field.isName)
    }

    public static let title = LibraryOrder.natural(.title)

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ".").map(String.init)
        guard parts.count == 2, let field = Field(rawValue: parts[0]) else { return nil }
        self.init(field, ascending: parts[1] == "ascending")
    }

    public var rawValue: String { "\(field.rawValue).\(ascending ? "ascending" : "descending")" }
}

/// How names are put in order and indexed, as Music does: without case or accents, leading
/// "The", "A" and "An" set aside ("The Beatles" under B), numbers in numeric order, and
/// names that don't start with a letter after Z, under #.
public enum LibraryCollation {
    /// The part of a name that decides its place.
    public static func key(_ name: String) -> String {
        let folded = name
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for article in ["the ", "a ", "an "] where folded.hasPrefix(article) {
            let rest = folded.dropFirst(article.count).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
        }
        return folded
    }

    /// The letter a name is indexed under: "B" for The Beatles, "#" for 1999 or 東京.
    public static func indexLetter(_ name: String) -> String {
        indexLetter(forKey: key(name))
    }

    static func indexLetter(forKey key: String) -> String {
        guard let first = key.unicodeScalars.first, ("a"..."z").contains(first) else { return "#" }
        return String(first).uppercased()
    }

    /// Whether one key comes before another: letters before everything else, then numeric
    /// order, so "Track 2" comes before "Track 10".
    static func precedes(_ lhs: String, _ rhs: String) -> Bool? {
        let (left, right) = (isLettered(lhs), isLettered(rhs))
        if left != right { return left }
        switch lhs.compare(rhs, options: [.numeric]) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return nil
        }
    }

    private static func isLettered(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first else { return false }
        return ("a"..."z").contains(first)
    }
}

/// A run of items under one index letter, for a list with Music's A to Z index.
public struct LibraryLetterSection<Item>: Identifiable {
    public let letter: String
    public let items: [Item]
    public var id: String { letter }
}

extension LibraryLetterSection: Sendable where Item: Sendable {}

/// Putting library items in order, finding them by name, and indexing them by letter. Pure,
/// so a page can do it off the main actor over thousands of songs.
public enum LibrarySort {
    /// Items in `order`. Ties go by title, then artist, then the order they came in, so the
    /// same library always reads the same way. Missing dates go last, whichever way.
    public static func sorted<Item>(_ items: [Item], by order: LibraryOrder, keys: (Item) -> LibrarySortKeys) -> [Item] {
        // Keys are worked out once per item, not once per comparison.
        let decorated = items.enumerated().map { index, item in
            Decorated(index: index, keys: keys(item), field: order.field)
        }
        let ordered = decorated.sorted { lhs, rhs in
            if let decided = compare(lhs, rhs, by: order) { return decided }
            if let byTitle = LibraryCollation.precedes(lhs.titleKey, rhs.titleKey) { return byTitle }
            if let byArtist = LibraryCollation.precedes(lhs.artistKey, rhs.artistKey) { return byArtist }
            return lhs.index < rhs.index
        }
        return ordered.map { items[$0.index] }
    }

    /// The items whose title, artist or album hold every word of `query`, ignoring case and
    /// accents. All of them when the query is blank.
    public static func filtered<Item>(_ items: [Item], matching query: String, keys: (Item) -> LibrarySortKeys) -> [Item] {
        let words = fold(query).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return items }
        return items.filter { item in
            let keys = keys(item)
            let text = fold("\(keys.title) \(keys.artist) \(keys.album)")
            return words.allSatisfy { text.contains($0) }
        }
    }

    /// Items already in name order, gathered under their index letters, # last.
    public static func sections<Item>(_ items: [Item], name: (Item) -> String) -> [LibraryLetterSection<Item>] {
        var sections: [LibraryLetterSection<Item>] = []
        var letter: String?
        var run: [Item] = []
        for item in items {
            let next = LibraryCollation.indexLetter(name(item))
            if next != letter, let letter, !run.isEmpty {
                sections.append(LibraryLetterSection(letter: letter, items: run))
                run = []
            }
            letter = next
            run.append(item)
        }
        if let letter, !run.isEmpty {
            sections.append(LibraryLetterSection(letter: letter, items: run))
        }
        return sections
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private struct Decorated {
        let index: Int
        let titleKey: String
        let artistKey: String
        /// The chosen field's name, when it's a name other than title or artist.
        let albumKey: String
        let date: Date?
        let number: Double

        init(index: Int, keys: LibrarySortKeys, field: LibraryOrder.Field) {
            self.index = index
            titleKey = LibraryCollation.key(keys.title)
            artistKey = LibraryCollation.key(keys.artist)
            albumKey = field == .album ? LibraryCollation.key(keys.album) : ""
            date = switch field {
            case .added: keys.added
            case .played: keys.played
            case .year: keys.released
            default: nil
            }
            number = switch field {
            case .time: keys.duration
            case .plays: Double(keys.plays)
            default: 0
            }
        }
    }

    /// Nil when the chosen field can't tell the two apart.
    private static func compare(_ lhs: Decorated, _ rhs: Decorated, by order: LibraryOrder) -> Bool? {
        switch order.field {
        case .title:
            return LibraryCollation.precedes(lhs.titleKey, rhs.titleKey).map { $0 == order.ascending }
        case .artist:
            return LibraryCollation.precedes(lhs.artistKey, rhs.artistKey).map { $0 == order.ascending }
        case .album:
            return LibraryCollation.precedes(lhs.albumKey, rhs.albumKey).map { $0 == order.ascending }
        case .time, .plays:
            guard lhs.number != rhs.number else { return nil }
            return (lhs.number < rhs.number) == order.ascending
        case .added, .played, .year:
            switch (lhs.date, rhs.date) {
            case (nil, nil): return nil
            case (nil, _): return false
            case (_, nil): return true
            case let (left?, right?):
                guard left != right else { return nil }
                return (left < right) == order.ascending
            }
        }
    }
}
