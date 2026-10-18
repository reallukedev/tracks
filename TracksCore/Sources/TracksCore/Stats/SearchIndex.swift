import Foundation

/// Every song, artist and album in the history, tallied and folded once, ready to search.
///
/// Searching used to tally the whole history on every keystroke, three times over. With a
/// hundred and fifty thousand plays that was a couple of hundred milliseconds a letter. The
/// tallies only change when the history does, so build one of these per history and each
/// search is a pass over the tallies' prepared text.
public struct SearchIndex: Sendable {
    private struct Entry<Item: Sendable>: Sendable {
        let item: Item
        /// Folded, so a search only has to fold what was typed.
        let text: String
    }

    private let songs: [Entry<SongTally>]
    private let artists: [Entry<ArtistTally>]
    private let albums: [Entry<AlbumTally>]
    private let history: ListeningHistory
    /// Each song's name, artist, album and genre as ``SearchFolding`` has them, by identity,
    /// for words left over from a ``HistoryRecall``.
    private let recallText: [String: String]
    /// The stations in the history, by name, most recently heard first.
    public let stations: [String]

    public init(history: ListeningHistory) {
        self.history = history
        let all = history.captures.indices
        var recallText: [String: String] = [:]
        songs = StatsCalculator.tallySongs(all, in: history).map { song in
            let genre = history.songMetadata[song.id]?.genre ?? ""
            let text = "\(song.title) \(song.artistName) \(song.albumTitle ?? "") \(genre)"
            recallText[song.id] = SearchFolding.fold(text)
            return Entry(item: song, text: StatsCalculator.folded(text))
        }
        self.recallText = recallText
        artists = StatsCalculator.tallyArtists(all, in: history).map { Entry(item: $0, text: $0.id) }
        albums = StatsCalculator.tallyAlbums(all, in: history).map {
            Entry(item: $0, text: StatsCalculator.folded("\($0.title) \($0.artistName)"))
        }
        var seen = Set<String>()
        stations = history.captures.reversed().compactMap { capture in
            guard let name = capture.stationName, !name.isEmpty, seen.insert(name).inserted else { return nil }
            return name
        }
    }

    /// The most played artists of all time, for suggestions before anything is typed.
    public func topArtists(limit: Int) -> [ArtistTally] {
        artists.prefix(limit).map(\.item)
    }

    /// The most played albums of all time.
    public func topAlbums(limit: Int) -> [AlbumTally] {
        albums.prefix(limit).map(\.item)
    }

    /// Matches every typed word, ignoring case and accents ("mara sol" finds Mara Solís).
    /// Songs match on their genre too, so "jazz" finds the jazz you've played. Most played
    /// first in each group. When nothing matches, words a letter off match too, so "driftwod"
    /// still finds Driftwood.
    public func search(_ text: String, limit: Int = 25) -> SearchResults {
        let words = StatsCalculator.folded(text).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return .empty }

        func firstMatches<Item>(_ entries: [Entry<Item>], _ matches: (Entry<Item>) -> Bool) -> [Item] {
            var found: [Item] = []
            for entry in entries where matches(entry) {
                found.append(entry.item)
                if found.count == limit { break }
            }
            return found
        }
        func exactly<Item>(_ entry: Entry<Item>) -> Bool {
            words.allSatisfy { entry.text.contains($0) }
        }
        let exact = SearchResults(
            songs: firstMatches(songs, exactly),
            artists: firstMatches(artists, exactly),
            albums: firstMatches(albums, exactly)
        )
        guard exact.isEmpty else { return exact }

        func nearly<Item>(_ entry: Entry<Item>) -> Bool {
            words.allSatisfy { word in
                entry.text.contains(word)
                    || entry.text.split(whereSeparator: \.isWhitespace).contains { SearchFolding.isNear(word, $0) }
            }
        }
        return SearchResults(
            songs: firstMatches(songs, nearly),
            artists: firstMatches(artists, nearly),
            albums: firstMatches(albums, nearly)
        )
    }

    // MARK: - Remembering

    /// The plays that fit what was remembered, as ``HistoryRecall`` read it.
    ///
    /// A day or a night comes back as a timeline of its plays, newest first. Anything longer,
    /// or what played around a song, comes back as songs, most played first. Plays whose time
    /// isn't known, recovered from Recently Played, are left out wherever time matters.
    public func recall(_ recall: HistoryRecall, limit: Int = 200, calendar: Calendar = .current) -> RecallResults {
        guard recall.hasFilters else { return .empty }
        let captures = history.captures

        var anchor: SongTally?
        let candidates: [Int]
        if let relation = recall.relation {
            guard let found = anchorSong(for: relation.anchor) else { return .empty }
            anchor = found
            candidates = neighbors(of: found.id, after: relation == .after(relation.anchor))
        } else {
            candidates = Array(history.indices(in: recall.interval))
        }

        let station = recall.station.map(StatsCalculator.folded)
        let decade = recall.decade.map { $0...($0 + 9) }
        let fitting = candidates.filter { index in
            let capture = captures[index]
            if recall.needsKnownTime, !capture.kind.timeIsKnown { return false }
            if recall.radioOnly || station != nil, capture.kind != .radio { return false }
            if let station, capture.stationName.map(StatsCalculator.folded) != station { return false }
            if recall.relation != nil, let interval = recall.interval, !interval.contains(capture.capturedAt) {
                return false
            }
            if let decade {
                guard let year = history.songMetadata[capture.songIdentity]?.releaseYear, decade.contains(year) else {
                    return false
                }
            }
            if recall.checksPartOfDay, let part = recall.partOfDay,
               !part.contains(hour: calendar.component(.hour, from: capture.capturedAt)) {
                return false
            }
            if let weekday = recall.weekday, calendar.component(.weekday, from: capture.capturedAt) != weekday {
                return false
            }
            if let mood = recall.mood {
                guard let genre = history.songMetadata[capture.songIdentity]?.genre, mood.suits(genre: genre) else {
                    return false
                }
            }
            return true
        }
        let matched = matching(recall.words, in: fitting)
        guard !matched.isEmpty else { return RecallResults(layout: .mostPlayed, plays: [], songs: [], artists: [], albums: [], anchor: anchor) }

        let songs = Array(StatsCalculator.tallySongs(matched, in: history).prefix(limit))
        // A few songs heard once each say more as when they played than as a chart of ones.
        let isFewOnce = matched.count <= Self.fewPlays && songs.allSatisfy { $0.count == 1 }
        let isTimeline = recall.relation == nil && !recall.prefersMostPlayed
            && ((recall.interval?.duration ?? .infinity) <= 36 * 3600 || isFewOnce)
        // What played around a song is about the songs, not who made them.
        let showsShelves = recall.relation == nil
        return RecallResults(
            layout: isTimeline ? .timeline : .mostPlayed,
            plays: isTimeline ? matched.reversed().prefix(limit).map { RecallPlay(id: $0, capture: captures[$0]) } : [],
            songs: songs,
            artists: showsShelves ? Array(StatsCalculator.tallyArtists(matched, in: history).prefix(10)) : [],
            albums: showsShelves ? Array(StatsCalculator.tallyAlbums(matched, in: history).prefix(10)) : [],
            anchor: anchor
        )
    }

    /// The plays among `indices` whose song, artist, album, genre or station has every word.
    /// When none has, a word may be a letter off ("jonny cash"), as a name half remembered is.
    private func matching(_ words: [String], in indices: [Int]) -> [Int] {
        guard !words.isEmpty else { return indices }
        let captures = history.captures
        func text(_ index: Int) -> (song: String, station: String) {
            (recallText[captures[index].songIdentity] ?? "", captures[index].stationName.map(SearchFolding.fold) ?? "")
        }
        let exact = indices.filter { index in
            let (song, station) = text(index)
            return words.allSatisfy { song.contains($0) || station.contains($0) }
        }
        guard exact.isEmpty else { return exact }
        var split: [String: [Substring]] = [:]
        return indices.filter { index in
            let (song, station) = text(index)
            let identity = captures[index].songIdentity
            let songWords = split[identity] ?? song.split(separator: " ")
            split[identity] = songWords
            return words.allSatisfy { word in
                song.contains(word) || station.contains(word)
                    || songWords.contains { SearchFolding.isNear(word, $0) }
                    || station.split(separator: " ").contains { SearchFolding.isNear(word, $0) }
            }
        }
    }

    /// The song "after driftwood" means: one named exactly that, or else the most played
    /// song every word matches, or nearly matches.
    private func anchorSong(for text: String) -> SongTally? {
        let words = text.split(separator: " ")
        guard !words.isEmpty else { return nil }
        let matching = songs.lazy.filter { entry in
            let folded = self.recallText[entry.item.id] ?? ""
            return words.allSatisfy { folded.contains($0) }
        }
        if let found = matching.first(where: { SearchFolding.fold($0.item.title) == text }) ?? matching.first {
            return found.item
        }
        return songs.first { entry in
            let folded = (self.recallText[entry.item.id] ?? "").split(separator: " ")
            return words.allSatisfy { word in folded.contains { $0.hasPrefix(word) || SearchFolding.isNear(word, $0) } }
        }?.item
    }

    /// The plays right after or before each play of a song, as long as one led into the
    /// other, not hours apart. The song repeating is skipped past.
    private func neighbors(of identity: String, after: Bool) -> [Int] {
        let captures = history.captures
        let step = after ? 1 : -1
        var found = Set<Int>()
        for index in captures.indices where captures[index].songIdentity == identity && captures[index].kind.timeIsKnown {
            var previous = index
            var next = index + step
            while captures.indices.contains(next), captures[next].kind.timeIsKnown,
                  abs(captures[next].capturedAt.timeIntervalSince(captures[previous].capturedAt)) <= Self.continuity {
                if captures[next].songIdentity != identity {
                    found.insert(next)
                    break
                }
                previous = next
                next += step
            }
        }
        return found.sorted()
    }

    private static let fewPlays = 25

    /// Longer than most songs, shorter than a break between listening.
    private static let continuity: TimeInterval = 20 * 60

    /// A few things to try remembering by, each with something to find, for before anything
    /// is typed. Phrases search understands, as they'd be typed.
    public func recallSuggestions(now: Date = .now, calendar: Calendar = .current) -> [String] {
        let hour = calendar.component(.hour, from: now)
        let lastMonth = calendar.date(byAdding: .month, value: -1, to: now).map {
            Self.englishMonthNames[calendar.component(.month, from: $0) - 1]
        }
        let candidates = [
            hour >= 11 ? "This Morning" : nil,
            "Last Night",
            "Yesterday Afternoon",
            "Last Weekend",
            stations.isEmpty ? nil : "Radio This Week",
            lastMonth.map { "In \($0)" },
            "Last Summer",
        ].compactMap(\.self)
        return candidates.filter { phrase in
            let parsed = HistoryRecall.parse(phrase, stations: stations, now: now, calendar: calendar)
            return !recall(parsed, limit: 1, calendar: calendar).isEmpty
        }
        .prefix(6)
        .map(\.self)
    }

    private static let englishMonthNames: [String] = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar.monthSymbols
    }()
}

extension SearchResults {
    /// Whether a song, artist or album found is called exactly what was typed, so a song
    /// called "Yesterday" is found as itself rather than read as a day.
    public func hasName(matching text: String) -> Bool {
        let typed = SearchFolding.fold(text)
        return songs.contains { SearchFolding.fold($0.title) == typed }
            || artists.contains { SearchFolding.fold($0.name) == typed }
            || albums.contains { SearchFolding.fold($0.title) == typed }
    }
}

/// What a ``HistoryRecall`` found.
public struct RecallResults: Sendable, Equatable {
    public enum Layout: Sendable, Equatable {
        /// A day or a night, play by play.
        case timeline
        case mostPlayed
    }

    public let layout: Layout
    /// For a timeline, the plays, newest first.
    public let plays: [RecallPlay]
    /// The songs among the plays, most played first, counting only those plays.
    public let songs: [SongTally]
    public let artists: [ArtistTally]
    public let albums: [AlbumTally]
    /// The song others were played around, for "after driftwood".
    public let anchor: SongTally?

    public var isEmpty: Bool { plays.isEmpty && songs.isEmpty }

    public static let empty = RecallResults(layout: .mostPlayed, plays: [], songs: [], artists: [], albums: [], anchor: nil)
}

/// One play in a recalled timeline.
public struct RecallPlay: Sendable, Equatable, Identifiable {
    /// Its place in the history.
    public let id: Int
    public let capture: CaptureStat
}
