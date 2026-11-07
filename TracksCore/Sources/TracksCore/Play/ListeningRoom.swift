import Foundation

/// What your history holds of one mood or one genre, for its page: every song of yours in it
/// and what its plays say about it. The history knows each song's genre, year and when it was
/// played, and nothing about its tempo or feel, so everything here comes from those.
public struct ListeningRoom: Sendable {
    /// One song of yours in the room.
    public struct Song: Sendable, Identifiable, Equatable {
        public let song: MixSong
        public let plays: Int
        public let firstHeard: Date
        public var lastHeard: Date { song.lastHeard }
        /// Plays in the last 30 days.
        public let recentPlays: Int
        /// Plays in the 30 days before those.
        public let earlierPlays: Int
        /// Plays on the day it was played most.
        public let bestDay: Int
        /// How many months it was played in.
        public let months: Int
        /// Plays in each part of the day, by ``DayPart`` raw value.
        public let partPlays: [Int]
        /// Plays heard inside a drive Tracks noticed.
        public let drivePlays: Int
        public let genre: String?
        public let releaseYear: Int?

        public var id: String { song.id }

        /// How bright its genre plays, from 0, calm, to 1, bright, where its genre says.
        public var energy: Double? { RadioMoment.energy(ofGenre: genre) }

        /// The share of its plays in these parts of the day.
        public func share(in parts: Set<DayPart>) -> Double {
            guard plays > 0 else { return 0 }
            return Double(parts.reduce(0) { $0 + partPlays[$1.rawValue] }) / Double(plays)
        }
    }

    /// Every song of yours in it, the most played first, the one heard last breaking a tie.
    public let songs: [Song]
    public let now: Date

    /// Every play of a song in it.
    public var plays: Int { songs.reduce(0) { $0 + $1.plays } }

    public var isEmpty: Bool { songs.isEmpty }

    /// The song you heard first in it.
    public var first: Song? { songs.min { $0.firstHeard < $1.firstHeard } }

    /// When you play it most: a part of the day holding at least two in five of its plays,
    /// once there are enough to tell.
    public var peak: DayPart? {
        guard plays >= Self.enoughToTell else { return nil }
        var byPart = [Int](repeating: 0, count: DayPart.allCases.count)
        for song in songs {
            for (index, count) in song.partPlays.enumerated() { byPart[index] += count }
        }
        guard let best = byPart.indices.max(by: { byPart[$0] < byPart[$1] }),
              Double(byPart[best]) / Double(plays) >= 0.4
        else { return nil }
        return DayPart(rawValue: best)
    }

    static let enoughToTell = 12

    public init(songs: [Song], now: Date) {
        self.songs = songs
        self.now = now
    }

    /// The songs of yours whose genre `matches`.
    public init(
        matching matches: (String) -> Bool,
        in history: ListeningHistory,
        signals: ListeningSignals = ListeningSignals(),
        drives: DriveLog = DriveLog(),
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        let month: TimeInterval = 30 * 24 * 60 * 60
        let recent = now.addingTimeInterval(-month)
        let earlier = now.addingTimeInterval(-2 * month)
        var matchesTag: [String: Bool] = [:]
        let songs: [Song] = MixBuilder.aggregate(history, signals: signals, now: now, calendar: calendar).compactMap { aggregate in
            let metadata = history.songMetadata[aggregate.identity]
            guard let genre = metadata?.genre else { return nil }
            let fits: Bool
            if let known = matchesTag[genre] {
                fits = known
            } else {
                fits = matches(genre)
                matchesTag[genre] = fits
            }
            guard fits else { return nil }
            var parts = [Int](repeating: 0, count: DayPart.allCases.count)
            for slot in aggregate.slots { parts[Int(slot) / 2] += 1 }
            var days: [Date: Int] = [:]
            var months = Set<DateComponents>()
            for date in aggregate.dates {
                days[calendar.startOfDay(for: date), default: 0] += 1
                months.insert(calendar.dateComponents([.year, .month], from: date))
            }
            return Song(
                song: MixSong(
                    songIdentity: aggregate.song.songIdentity,
                    songID: aggregate.song.songID,
                    title: aggregate.song.title,
                    artistName: aggregate.song.artistName,
                    albumTitle: aggregate.song.albumTitle,
                    artworkURL: aggregate.song.artworkURL,
                    plays: aggregate.dates.count,
                    lastHeard: aggregate.lastHeard,
                    genre: genre
                ),
                plays: aggregate.dates.count,
                firstHeard: aggregate.firstHeard,
                recentPlays: aggregate.dates.count { $0 >= recent },
                earlierPlays: aggregate.dates.count { $0 >= earlier && $0 < recent },
                bestDay: days.values.max() ?? 0,
                months: months.count,
                partPlays: parts,
                drivePlays: drives.isEmpty ? 0 : aggregate.dates.count { drives.contains($0) },
                genre: genre,
                releaseYear: metadata?.releaseYear
            )
        }
        self.init(
            songs: songs.sorted { $0.plays == $1.plays ? $0.lastHeard > $1.lastHeard : $0.plays > $1.plays },
            now: now
        )
    }

    /// A mood's songs of yours: the ones whose genre suits it.
    public static func mood(
        _ mood: Mood,
        in history: ListeningHistory,
        signals: ListeningSignals = ListeningSignals(),
        drives: DriveLog = DriveLog(),
        now: Date = .now,
        calendar: Calendar = .current
    ) -> ListeningRoom {
        ListeningRoom(matching: mood.suits(genre:), in: history, signals: signals, drives: drives, now: now, calendar: calendar)
    }

    /// A genre's songs of yours.
    public static func genre(
        _ genre: MusicGenre,
        in history: ListeningHistory,
        signals: ListeningSignals = ListeningSignals(),
        now: Date = .now,
        calendar: Calendar = .current
    ) -> ListeningRoom {
        ListeningRoom(matching: { genre.contains(genre: $0) }, in: history, signals: signals, now: now, calendar: calendar)
    }

    // MARK: - Rooms within the room

    /// Fewer than this and a section says too little to show.
    public static let fewest = 3

    private func atLeastFew(_ songs: [Song], limit: Int) -> [Song] {
        songs.count >= Self.fewest ? Array(songs.prefix(limit)) : []
    }

    /// Songs you mostly play in the evening and at night, from the brightest genres down to the
    /// calmest, so the list settles as it goes.
    public func windDown(limit: Int = 20) -> [Song] {
        let evening = songs.filter { $0.share(in: [.evening, .night]) >= 0.5 }
        return atLeastFew(evening.sorted { lhs, rhs in
            let (left, right) = (lhs.energy ?? 0.5, rhs.energy ?? 0.5)
            return left == right ? lhs.plays > rhs.plays : left > right
        }, limit: limit)
    }

    /// Songs you mostly play late, after ten at night.
    public func lateNight(limit: Int = 20) -> [Song] {
        atLeastFew(songs.filter { $0.share(in: [.night]) >= 0.5 }, limit: limit)
    }

    /// Songs you mostly play in the morning.
    public func mornings(limit: Int = 20) -> [Song] {
        atLeastFew(songs.filter { $0.share(in: [.morning]) >= 0.5 }, limit: limit)
    }

    /// Songs in genres that are mostly instrumental, the most played first, then the rest.
    public func instrumentalFirst(limit: Int = 20) -> [Song] {
        let instrumental = songs.filter { $0.genre.map(Self.isInstrumental) ?? false }
        guard instrumental.count >= Self.fewest else { return [] }
        let ids = Set(instrumental.map(\.id))
        return Array((instrumental + songs.filter { !ids.contains($0.id) }).prefix(limit))
    }

    /// Whether a genre is one that's mostly without words.
    public static func isInstrumental(_ genre: String) -> Bool {
        let folded = StatsCalculator.folded(genre)
        return instrumentalHints.contains { folded.contains($0) }
    }

    static let instrumentalHints = ["classical", "ambient", "instrumental", "soundtrack", "score", "new age", "piano", "orchestral", "baroque", "chamber"]

    /// The songs you've played most in the last 30 days.
    public func thisMonth(limit: Int = 20) -> [Song] {
        atLeastFew(songs.filter { $0.recentPlays >= 2 }.sorted { $0.recentPlays == $1.recentPlays ? $0.plays > $1.plays : $0.recentPlays > $1.recentPlays }, limit: limit)
    }

    /// Songs you once played three times or more in a day, the most in a day first.
    public func overAndOver(limit: Int = 20) -> [Song] {
        atLeastFew(songs.filter { $0.bestDay >= 3 }.sorted { $0.bestDay == $1.bestDay ? $0.plays > $1.plays : $0.bestDay > $1.bestDay }, limit: limit)
    }

    /// Songs you've played in the most months, three or more.
    public func monthAfterMonth(limit: Int = 20) -> [Song] {
        atLeastFew(songs.filter { $0.months >= 3 }.sorted { $0.months == $1.months ? $0.plays > $1.plays : $0.months > $1.months }, limit: limit)
    }

    /// Songs first heard over a year ago that you've played in the last three months.
    public func throwbacks(limit: Int = 20) -> [Song] {
        let yearAgo = now.addingTimeInterval(-365 * 24 * 60 * 60)
        let lately = now.addingTimeInterval(-90 * 24 * 60 * 60)
        return atLeastFew(songs.filter { $0.firstHeard < yearAgo && $0.lastHeard >= lately }, limit: limit)
    }

    /// Songs heard on drives, the most heard on the road first.
    public func onTheRoad(limit: Int = 20) -> [Song] {
        atLeastFew(songs.filter { $0.drivePlays > 0 }.sorted { $0.drivePlays == $1.drivePlays ? $0.plays > $1.plays : $0.drivePlays > $1.drivePlays }, limit: limit)
    }

    /// Songs you've played more in the last 30 days than the 30 before, the biggest rise first.
    public func rising(limit: Int = 20) -> [Song] {
        atLeastFew(songs.filter { $0.recentPlays >= 2 && $0.recentPlays > $0.earlierPlays }.sorted {
            let (left, right) = ($0.recentPlays - $0.earlierPlays, $1.recentPlays - $1.earlierPlays)
            return left == right ? $0.plays > $1.plays : left > right
        }, limit: limit)
    }

    /// Your songs in it by the decade they came out, oldest first, the most played first in
    /// each. Empty unless they span two decades or more.
    public func decades() -> [Decade] {
        var byDecade: [Int: [Song]] = [:]
        for song in songs {
            guard let year = song.releaseYear, year > 1000 else { continue }
            byDecade[year / 10 * 10, default: []].append(song)
        }
        let decades = byDecade.keys.sorted().compactMap { decade -> Decade? in
            guard let songs = byDecade[decade] else { return nil }
            return Decade(start: decade, songs: songs)
        }
        return decades.count >= 2 ? decades : []
    }

    /// Ten years of songs, like the 1990s.
    public struct Decade: Sendable, Identifiable, Equatable {
        /// Its first year, like 1990.
        public let start: Int
        public let songs: [Song]
        public var id: Int { start }
    }
}
