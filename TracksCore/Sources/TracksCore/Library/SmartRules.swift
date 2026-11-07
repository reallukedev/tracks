import Foundation

/// What a smart playlist's songs have to be: where they come from, the conditions they meet,
/// in what order, and how many.
public struct SmartRules: Codable, Sendable, Hashable {
    /// Where its songs come from.
    public enum Source: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Songs downloaded to this iPhone, and your own files: what plays with no connection.
        case downloaded
        /// Everything in your music, files and servers.
        case yourMusic

        public var id: String { rawValue }
    }

    /// Whether a song has to meet every condition, or any one.
    public enum Match: String, Codable, Sendable, CaseIterable, Identifiable {
        case all, any

        public var id: String { rawValue }
    }

    public enum Order: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Shuffled, and shuffled again each day.
        case random
        case mostPlayed, leastPlayed, recentlyPlayed, recentlyAdded, title, artist

        public var id: String { rawValue }
    }

    public var source: Source
    public var match: Match
    public var conditions: [Condition]
    public var order: Order
    /// At most this many songs, taken in its order; `nil` for every one that matches.
    public var limit: Int?

    public init(source: Source = .downloaded, match: Match = .all, conditions: [Condition] = [], order: Order = .random, limit: Int? = nil) {
        self.source = source
        self.match = match
        self.conditions = conditions
        self.order = order
        self.limit = limit
    }

    /// One thing a song has to be.
    public struct Condition: Codable, Sendable, Hashable, Identifiable {
        public var id: UUID
        public var field: Field
        public var comparison: Comparison
        /// For a field of words: what it's compared with.
        public var text: String
        /// For a field of numbers, the number; for dates, a number of days.
        public var number: Int

        public init(id: UUID = UUID(), field: Field, comparison: Comparison? = nil, text: String = "", number: Int? = nil) {
            self.id = id
            self.field = field
            self.comparison = comparison ?? field.comparisons[0]
            self.text = text
            self.number = number ?? field.defaultNumber
        }

        /// Whether it says anything yet: a condition on words with none is left out, rather
        /// than matching everything or nothing while it's being written.
        public var isComplete: Bool {
            field.kind != .text || !text.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    public enum Field: String, Codable, Sendable, CaseIterable, Identifiable {
        case title, artist, album, genre
        case year, plays
        case lastPlayed, dateAdded
        case quality

        public var id: String { rawValue }

        public enum Kind: Sendable { case text, number, days, quality }

        public var kind: Kind {
            switch self {
            case .title, .artist, .album, .genre: .text
            case .year, .plays: .number
            case .lastPlayed, .dateAdded: .days
            case .quality: .quality
            }
        }

        /// The comparisons that make sense for it, the likeliest first.
        public var comparisons: [Comparison] {
            switch kind {
            case .text: [.contains, .is, .isNot, .doesNotContain, .beginsWith]
            case .number: [.atLeast, .atMost, .is, .isNot]
            case .days: [.inTheLast, .notInTheLast]
            case .quality: [.isLossless, .isHiRes, .isNotLossless]
            }
        }

        public var defaultNumber: Int {
            switch self {
            case .year: Calendar(identifier: .gregorian).component(.year, from: .now)
            case .plays: 1
            case .lastPlayed, .dateAdded: 30
            default: 0
            }
        }
    }

    public enum Comparison: String, Codable, Sendable, CaseIterable, Identifiable {
        case contains, `is`, isNot, doesNotContain, beginsWith
        case atLeast, atMost
        case inTheLast, notInTheLast
        case isLossless, isHiRes, isNotLossless

        public var id: String { rawValue }
    }

    // MARK: - Matching

    /// Whether a song meets the rules' conditions. With none complete, every song does.
    /// - Parameter facts: what's known of the song's plays, `nil` for one never played.
    public func matches(_ track: LocalTrack, facts: SongFacts?, now: Date = .now) -> Bool {
        let complete = conditions.filter(\.isComplete)
        guard !complete.isEmpty else { return true }
        switch match {
        case .all: return complete.allSatisfy { $0.matches(track, facts: facts, now: now) }
        case .any: return complete.contains { $0.matches(track, facts: facts, now: now) }
        }
    }

    /// The playlist's songs from the ones given: those that match, each song once, in its
    /// order, as many as it takes.
    /// - Parameters:
    ///   - tracks: the songs it can take from, already narrowed to its source.
    ///   - facts: what's known of each song's plays, by identity.
    ///   - seed: for a random order, so it stays put through the day and changes the next.
    public func songs(from tracks: [LocalTrack], facts: [String: SongFacts], now: Date = .now, seed: UInt64) -> [LocalTrack] {
        var seen = Set<String>()
        let matching = tracks.filter { track in
            matches(track, facts: facts[track.identity], now: now) && seen.insert(track.identity).inserted
        }
        let ordered = sorted(matching, facts: facts, seed: seed)
        guard let limit else { return ordered }
        return Array(ordered.prefix(max(0, limit)))
    }

    private func sorted(_ tracks: [LocalTrack], facts: [String: SongFacts], seed: UInt64) -> [LocalTrack] {
        func plays(_ track: LocalTrack) -> Int { facts[track.identity]?.plays ?? 0 }
        switch order {
        case .random:
            return FreshShuffle.order(tracks, artist: \.artistKey, seed: seed)
        case .mostPlayed:
            return tracks.sorted { (plays($0), $1.title) > (plays($1), $0.title) }
        case .leastPlayed:
            return tracks.sorted { (plays($0), $0.title) < (plays($1), $1.title) }
        case .recentlyPlayed:
            return tracks.sorted {
                (facts[$0.identity]?.lastHeard ?? .distantPast) > (facts[$1.identity]?.lastHeard ?? .distantPast)
            }
        case .recentlyAdded:
            return tracks.sorted { $0.addedAt > $1.addedAt }
        case .title:
            return tracks.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist:
            return tracks.sorted { lhs, rhs in
                let artist = lhs.albumArtistName.localizedStandardCompare(rhs.albumArtistName)
                if artist != .orderedSame { return artist == .orderedAscending }
                let album = (lhs.album ?? "").localizedStandardCompare(rhs.album ?? "")
                if album != .orderedSame { return album == .orderedAscending }
                return (lhs.discNumber ?? 1, lhs.trackNumber ?? 0) < (rhs.discNumber ?? 1, rhs.trackNumber ?? 0)
            }
        }
    }
}

extension SmartRules.Condition {
    public func matches(_ track: LocalTrack, facts: SongFacts?, now: Date = .now) -> Bool {
        switch field {
        case .title: return compare(words: [track.title])
        case .artist: return compare(words: [track.artist, track.albumArtist].compactMap(\.self))
        case .album: return compare(words: [track.album ?? ""])
        case .genre: return compare(words: [track.genre ?? ""])
        case .year:
            guard let year = track.year else { return comparison == .isNot }
            return compare(year)
        case .plays: return compare(facts?.plays ?? 0)
        case .lastPlayed:
            // Never played is "not in the last" any number of days.
            guard let last = facts?.lastHeard else { return comparison == .notInTheLast }
            return within(last, now: now)
        case .dateAdded: return within(track.addedAt, now: now)
        case .quality:
            let format = track.format
            switch comparison {
            case .isHiRes: return format?.isHiRes == true
            case .isNotLossless: return format?.isLossless != true
            default: return format?.isLossless == true
            }
        }
    }

    /// Words compared without regard to case or accents. For an artist, the song matches if
    /// either its artist or its album's does, as Music's own smart playlists have it.
    private func compare(words: [String]) -> Bool {
        let wanted = StatsCalculator.folded(text.trimmingCharacters(in: .whitespaces))
        let folded = words.map(StatsCalculator.folded)
        switch comparison {
        case .is: return folded.contains(wanted)
        case .isNot: return !folded.contains(wanted)
        case .doesNotContain: return !folded.contains { $0.contains(wanted) }
        case .beginsWith: return folded.contains { $0.hasPrefix(wanted) }
        default: return folded.contains { $0.contains(wanted) }
        }
    }

    private func compare(_ value: Int) -> Bool {
        switch comparison {
        case .atLeast: value >= number
        case .atMost: value <= number
        case .isNot: value != number
        default: value == number
        }
    }

    private func within(_ date: Date, now: Date) -> Bool {
        let inside = now.timeIntervalSince(date) <= TimeInterval(max(0, number)) * 24 * 60 * 60
        return comparison == .notInTheLast ? !inside : inside
    }
}
