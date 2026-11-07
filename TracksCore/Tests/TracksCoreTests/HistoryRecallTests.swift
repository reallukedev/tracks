import Testing
import Foundation
import TracksCore

/// Fixed clock and calendar: Thursday 15 October 2026, 2 PM, in UTC.
private enum Clock {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static let now = date(2026, 10, 15, 14)

    static func parse(_ text: String, stations: [String] = [], now: Date = now, calendar: Calendar = calendar) -> HistoryRecall {
        HistoryRecall.parse(text, stations: stations, now: now, calendar: calendar)
    }

    static func interval(_ start: Date, _ end: Date) -> DateInterval {
        DateInterval(start: start, end: end)
    }
}

@Suite("Reading what's remembered about a song")
struct HistoryRecallParsingTests {
    @Test("a plain search is left as it is, small words and all", arguments: ["the tides", "night drive", "march of the pigs", "summer rain", "may queen"])
    func plainSearch(text: String) {
        let recall = Clock.parse(text)
        #expect(!recall.hasFilters)
        #expect(recall.words == text.split(separator: " ").map(String.init))
    }

    @Test("days, and the parts of them", arguments: [
        ("today", Clock.interval(Clock.date(2026, 10, 15), Clock.date(2026, 10, 16))),
        ("yesterday", Clock.interval(Clock.date(2026, 10, 14), Clock.date(2026, 10, 15))),
        ("yesterday morning", Clock.interval(Clock.date(2026, 10, 14, 5), Clock.date(2026, 10, 14, 12))),
        ("this afternoon", Clock.interval(Clock.date(2026, 10, 15, 12), Clock.date(2026, 10, 15, 17))),
        ("tuesday evening", Clock.interval(Clock.date(2026, 10, 13, 17), Clock.date(2026, 10, 13, 22))),
        ("on tuesday in the evening", Clock.interval(Clock.date(2026, 10, 13, 17), Clock.date(2026, 10, 13, 22))),
        ("3 days ago", Clock.interval(Clock.date(2026, 10, 12), Clock.date(2026, 10, 13))),
    ])
    func days(text: String, expected: DateInterval) {
        let recall = Clock.parse(text)
        #expect(recall.interval == expected)
        #expect(recall.span == .day)
        #expect(recall.words.isEmpty)
    }

    @Test("a night runs from the evening into the small hours", arguments: [
        ("last night", Clock.date(2026, 10, 14, 18)),
        ("yesterday night", Clock.date(2026, 10, 14, 18)),
        ("tonight", Clock.date(2026, 10, 15, 18)),
        ("monday night", Clock.date(2026, 10, 12, 18)),
        ("monday late at night", Clock.date(2026, 10, 12, 18)),
    ])
    func nights(text: String, start: Date) {
        let recall = Clock.parse(text)
        #expect(recall.interval == DateInterval(start: start, duration: 11 * 3600))
        #expect(recall.span == .night)
    }

    @Test("a weekday is the latest one, today included unless it's the last one")
    func weekdays() {
        #expect(Clock.parse("thursday").interval?.start == Clock.date(2026, 10, 15))
        #expect(Clock.parse("last thursday").interval?.start == Clock.date(2026, 10, 8))
        #expect(Clock.parse("friday").interval?.start == Clock.date(2026, 10, 9))
        #expect(Clock.parse("tuesdays").weekday == 3)
        #expect(Clock.parse("tuesdays").interval == nil)
    }

    @Test("weeks, weekends, months and years", arguments: [
        ("this week", Clock.interval(Clock.date(2026, 10, 11), Clock.date(2026, 10, 18))),
        ("last week", Clock.interval(Clock.date(2026, 10, 4), Clock.date(2026, 10, 11))),
        ("two weeks ago", Clock.interval(Clock.date(2026, 9, 27), Clock.date(2026, 10, 4))),
        ("last weekend", Clock.interval(Clock.date(2026, 10, 10), Clock.date(2026, 10, 12))),
        ("2 weekends ago", Clock.interval(Clock.date(2026, 10, 3), Clock.date(2026, 10, 5))),
        ("last month", Clock.interval(Clock.date(2026, 9, 1), Clock.date(2026, 10, 1))),
        ("in march", Clock.interval(Clock.date(2026, 3, 1), Clock.date(2026, 4, 1))),
        ("last march", Clock.interval(Clock.date(2026, 3, 1), Clock.date(2026, 4, 1))),
        ("november", Clock.interval(Clock.date(2025, 11, 1), Clock.date(2025, 12, 1))),
        ("may 2025", Clock.interval(Clock.date(2025, 5, 1), Clock.date(2025, 6, 1))),
        ("2024", Clock.interval(Clock.date(2024, 1, 1), Clock.date(2025, 1, 1))),
        ("last year", Clock.interval(Clock.date(2025, 1, 1), Clock.date(2026, 1, 1))),
        ("last summer", Clock.interval(Clock.date(2026, 6, 1), Clock.date(2026, 9, 1))),
        ("in the winter", Clock.interval(Clock.date(2025, 12, 1), Clock.date(2026, 3, 1))),
        ("this autumn", Clock.interval(Clock.date(2026, 9, 1), Clock.date(2026, 12, 1))),
    ])
    func longerSpans(text: String, expected: DateInterval) {
        #expect(Clock.parse(text).interval == expected)
    }

    @Test("on a weekend or in the month itself, \"last\" means the one before")
    func lastWhileItsOn() {
        let sunday = Clock.date(2026, 10, 11, 12)
        #expect(Clock.parse("this weekend", now: sunday).interval?.start == Clock.date(2026, 10, 10))
        #expect(Clock.parse("last weekend", now: sunday).interval?.start == Clock.date(2026, 10, 3))
        #expect(Clock.parse("last october").interval?.start == Clock.date(2025, 10, 1))
        #expect(Clock.parse("in october").interval?.start == Clock.date(2026, 10, 1))
        let july = Clock.date(2026, 7, 20)
        #expect(Clock.parse("last summer", now: july).interval?.start == Clock.date(2025, 6, 1))
    }

    @Test("summer comes at the end of the year in the southern hemisphere")
    func southernSeasons() {
        var calendar = Clock.calendar
        calendar.locale = Locale(identifier: "en_AU")
        #expect(Clock.parse("last summer", calendar: calendar).interval?.start == Clock.date(2025, 12, 1))
    }

    @Test("years that can't be when you listened stay words", arguments: ["1989", "2027", "12345"])
    func impossibleYears(text: String) {
        #expect(!Clock.parse(text).hasFilters)
    }

    @Test("a part of the day on its own needs saying as a time")
    func partsOfDay() {
        #expect(Clock.parse("evenings").partOfDay == .evening)
        #expect(Clock.parse("at night").partOfDay == .night)
        #expect(Clock.parse("late night").partOfDay == .night)
        #expect(Clock.parse("in the morning").partOfDay == .morning)
        #expect(Clock.parse("evenings").interval == nil)
        let week = Clock.parse("last week at night")
        #expect(week.partOfDay == .night)
        #expect(week.span == .week)
    }

    @Test("the radio, a station by name, and an era")
    func whereAndEra() {
        let stations = ["Late Night Jazz Radio", "Chill Station"]
        let radio = Clock.parse("jazz on the radio", stations: stations)
        #expect(radio.radioOnly)
        #expect(radio.words == ["jazz"])

        let station = Clock.parse("late night jazz radio yesterday", stations: stations)
        #expect(station.station == "Late Night Jazz Radio")
        #expect(station.partOfDay == nil)
        #expect(station.span == .day)

        #expect(Clock.parse("90s").decade == 1990)
        #expect(Clock.parse("the 2000s").decade == 2000)
        #expect(Clock.parse("’80s rock").decade == 1980)
        #expect(Clock.parse("10s").decade == 2010)
        #expect(!Clock.parse("45s").hasFilters)
    }

    @Test("what played after or before a song, with any time kept apart")
    func around() {
        let recall = Clock.parse("the song after Driftwood last week")
        #expect(recall.relation == .after("driftwood"))
        #expect(recall.span == .week)
        #expect(recall.words.isEmpty)
        #expect(Clock.parse("before open ocean").relation == .before("open ocean"))
        #expect(!Clock.parse("after").hasFilters)
    }

    @Test("a feel counts beside a time or a word like songs, and is a name on its own")
    func feel() {
        let summer = Clock.parse("something chill from last summer")
        #expect(summer.mood == .chill)
        #expect(summer.span == .season(.summer))
        #expect(summer.words.isEmpty)
        #expect(Clock.parse("sad songs").mood == .heartbreak)
        #expect(Clock.parse("feel good stuff").mood == .feelGood)
        #expect(Clock.parse("upbeat last week").mood == .feelGood)
        #expect(Clock.parse("chill radio", stations: ["Chill Station"]).mood == nil)
        #expect(Clock.parse("chill songs yesterday", stations: ["Chill Station"]).mood == .chill)

        let happy = Clock.parse("happy")
        #expect(!happy.hasFilters)
        #expect(happy.words == ["happy"])
    }

    @Test("played a lot, on repeat, over and over", arguments: [
        "played a lot last night", "on repeat last night", "last night over and over",
    ])
    func repeats(text: String) {
        let recall = Clock.parse(text)
        #expect(recall.prefersMostPlayed)
        #expect(recall.span == .night)
        #expect(recall.words.isEmpty)
    }
}

@Suite("Finding songs by what's remembered")
struct HistoryRecallSearchTests {
    struct Play {
        var title: String
        var artist = "Mara Solís"
        var at: Date
        var kind: CaptureKind = .onDemand
        var station: String?
    }

    func index(_ plays: [Play], years: [String: Int] = [:], genres: [String: String] = [:]) -> SearchIndex {
        let captures = plays.map {
            CaptureStat(
                songKey: $0.title, title: $0.title, artistName: $0.artist, albumTitle: "Tides",
                capturedAt: $0.at, stationName: $0.station, kind: $0.kind
            )
        }
        var metadata = years.reduce(into: [String: SongMetadata]()) { result, entry in
            result[HistoryImport.key(title: entry.key, artistName: "Mara Solís")] = SongMetadata(genre: "Jazz", releaseYear: entry.value)
        }
        for (title, genre) in genres {
            metadata[HistoryImport.key(title: title, artistName: "Mara Solís")] = SongMetadata(genre: genre, releaseYear: nil)
        }
        return SearchIndex(history: ListeningHistory(captures).with(artistArtwork: [:], songMetadata: metadata))
    }

    func recall(_ text: String, in index: SearchIndex) -> RecallResults {
        index.recall(Clock.parse(text, stations: index.stations), calendar: Clock.calendar)
    }

    @Test("a day is a timeline, newest first, without plays whose time isn't known")
    func timeline() {
        let index = index([
            Play(title: "Driftwood", at: Clock.date(2026, 10, 14, 20)),
            Play(title: "Open Ocean", at: Clock.date(2026, 10, 14, 21)),
            Play(title: "Recovered", at: Clock.date(2026, 10, 14, 21, 30), kind: .imported),
            Play(title: "Driftwood", at: Clock.date(2026, 10, 14, 22)),
            Play(title: "Too Early", at: Clock.date(2026, 10, 14, 9)),
            Play(title: "Today", at: Clock.date(2026, 10, 15, 9)),
        ])
        let results = recall("yesterday evening", in: index)
        #expect(results.layout == .timeline)
        #expect(results.plays.map(\.capture.title) == ["Open Ocean", "Driftwood"])
        #expect(recall("last night", in: index).plays.map(\.capture.title) == ["Driftwood", "Open Ocean", "Driftwood"])
    }

    @Test("a month is its songs, most played in it first, counting only its plays")
    func mostPlayed() {
        let index = index([
            Play(title: "Driftwood", at: Clock.date(2026, 3, 2)),
            Play(title: "Open Ocean", at: Clock.date(2026, 3, 3)),
            Play(title: "Open Ocean", at: Clock.date(2026, 3, 4)),
            Play(title: "Driftwood", at: Clock.date(2026, 5, 1)),
            Play(title: "Driftwood", at: Clock.date(2026, 5, 2)),
        ])
        let results = recall("that song i played a lot in march", in: index)
        #expect(results.layout == .mostPlayed)
        #expect(results.songs.map(\.title) == ["Open Ocean", "Driftwood"])
        #expect(results.songs.map(\.count) == [2, 1])
        #expect(results.artists.map(\.count) == [3])
    }

    @Test("a few songs heard once each over a longer span are a timeline too")
    func fewOnce() {
        let index = index([
            Play(title: "Driftwood", at: Clock.date(2026, 3, 2)),
            Play(title: "Open Ocean", at: Clock.date(2026, 3, 3)),
        ])
        let results = recall("in march", in: index)
        #expect(results.layout == .timeline)
        #expect(results.plays.map(\.capture.title) == ["Open Ocean", "Driftwood"])
    }

    @Test("the radio, a station, words that name a station, an era and a time of day")
    func filters() {
        let index = index([
            Play(title: "Driftwood", at: Clock.date(2026, 10, 13, 23), kind: .radio, station: "Late Night Jazz Radio"),
            Play(title: "Open Ocean", at: Clock.date(2026, 10, 13, 8), kind: .radio, station: "Chill Station"),
            Play(title: "Satellite", at: Clock.date(2026, 10, 13, 23, 10)),
        ], years: ["Driftwood": 1994, "Open Ocean": 2012, "Satellite": 1999])

        #expect(Set(recall("radio", in: index).songs.map(\.title)) == ["Driftwood", "Open Ocean"])
        #expect(recall("chill station", in: index).songs.map(\.title) == ["Open Ocean"])
        #expect(recall("chill radio", in: index).songs.map(\.title) == ["Open Ocean"])
        #expect(Set(recall("90s", in: index).songs.map(\.title)) == ["Driftwood", "Satellite"])
        #expect(Set(recall("late at night", in: index).songs.map(\.title)) == ["Driftwood", "Satellite"])
        #expect(recall("90s on the radio at night", in: index).songs.map(\.title) == ["Driftwood"])
        #expect(recall("tuesdays satellite", in: index).songs.map(\.title) == ["Satellite"])
        #expect(recall("wednesdays", in: index).isEmpty)
    }

    @Test("what played after or before a song, skipping its repeats and long gaps")
    func around() {
        let start = Clock.date(2026, 10, 10, 20)
        let index = index([
            Play(title: "Driftwood", at: start),
            Play(title: "Driftwood", at: start.addingTimeInterval(240)),
            Play(title: "Open Ocean", at: start.addingTimeInterval(480)),
            Play(title: "Satellite", at: start.addingTimeInterval(720)),
            // A day later, after a gap too long to have followed on.
            Play(title: "Driftwood", at: start.addingTimeInterval(86_400)),
            Play(title: "Horizon", at: start.addingTimeInterval(86_400 + 3 * 3600)),
            Play(title: "Driftwood", at: start.addingTimeInterval(2 * 86_400)),
            Play(title: "Open Ocean", at: start.addingTimeInterval(2 * 86_400 + 200)),
        ])
        let after = recall("after driftwood", in: index)
        #expect(after.anchor?.title == "Driftwood")
        #expect(after.songs.map(\.title) == ["Open Ocean"])
        #expect(after.songs.first?.count == 2)
        #expect(after.artists.isEmpty)
        #expect(recall("before satellite", in: index).songs.map(\.title) == ["Open Ocean"])
        #expect(recall("after zebra", in: index) == .empty)
    }

    @Test("a feel keeps the songs whose genre suits it, leaving out songs not looked up yet")
    func feel() {
        let index = index([
            Play(title: "Driftwood", at: Clock.date(2026, 7, 2)),
            Play(title: "Breaker", at: Clock.date(2026, 7, 3)),
            Play(title: "Unknown", at: Clock.date(2026, 7, 4)),
        ], genres: ["Driftwood": "Ambient", "Breaker": "Metal"])
        #expect(recall("something chill last summer", in: index).songs.map(\.title) == ["Driftwood"])
        #expect(recall("energetic songs", in: index).songs.map(\.title) == ["Breaker"])
        #expect(recall("sad songs", in: index).isEmpty)
    }

    @Test("with nothing found, the closest search lets go of one clue at a time, never the time")
    func loosening() {
        let recall = Clock.parse("90s jazz on the radio tuesday evening")
        let steps = sequence(first: recall) { $0.loosened() }.map { ($0.words, $0.decade, $0.radioOnly) }
        #expect(steps.map(\.0) == [["jazz"], [], [], []])
        #expect(steps.map(\.1) == [1990, 1990, nil, nil])
        #expect(steps.map(\.2) == [true, true, true, false])
        #expect(recall.loosened()?.interval == recall.interval)
        #expect(Clock.parse("radio").loosened() == nil)
    }

    @Test("played a lot turns a night into its most played songs")
    func repeats() {
        let index = index([
            Play(title: "Driftwood", at: Clock.date(2026, 10, 14, 20)),
            Play(title: "Open Ocean", at: Clock.date(2026, 10, 14, 20, 5)),
            Play(title: "Driftwood", at: Clock.date(2026, 10, 14, 20, 10)),
        ])
        let results = recall("played a lot last night", in: index)
        #expect(results.layout == .mostPlayed)
        #expect(results.songs.map(\.title) == ["Driftwood", "Open Ocean"])
    }

    @Test("a name half remembered, a letter off, still finds what was remembered around it")
    func halfRemembered() {
        let index = index([
            Play(title: "Ring of Fire", artist: "Johnny Cash", at: Clock.date(2026, 10, 14, 9), kind: .radio, station: "Country Gold"),
            Play(title: "Driftwood", at: Clock.date(2026, 10, 14, 9, 5), kind: .radio, station: "Country Gold"),
            Play(title: "Open Ocean", at: Clock.date(2026, 10, 14, 9, 9)),
        ])
        #expect(recall("jonny cash on the radio", in: index).songs.map(\.title) == ["Ring of Fire"])
        #expect(recall("after drifwood", in: index).songs.map(\.title) == ["Open Ocean"])
        // An exact match anywhere wins over near ones.
        #expect(recall("driftwood yesterday", in: index).plays.map(\.capture.title) == ["Driftwood"])
    }

    @Test("a song's name typed a letter off still finds it, when nothing matches exactly")
    func nearMisses() {
        let index = index([
            Play(title: "Driftwood", at: Clock.date(2026, 10, 1)),
            Play(title: "Driftwod Again", at: Clock.date(2026, 10, 1)),
        ])
        #expect(index.search("drfitwood").songs.map(\.title) == ["Driftwood"])
        #expect(index.search("driftwod").songs.map(\.title) == ["Driftwod Again"])
        #expect(index.search("zzzz").isEmpty)
    }

    @Test("a song called what was typed is that song, not a time")
    func exactName() {
        let index = index([
            Play(title: "Yesterday", at: Clock.date(2026, 10, 1)),
            Play(title: "Yesterday's Gone", at: Clock.date(2026, 10, 14)),
        ])
        #expect(index.search("YESTERDAY").hasName(matching: "YESTERDAY"))
        #expect(!index.search("yesterdays").hasName(matching: "yesterdays"))
        #expect(!index.search("gone").hasName(matching: "gone"))
    }

    @Test("suggestions are only the phrases with something to find")
    func suggestions() {
        let index = index([
            Play(title: "Driftwood", at: Clock.date(2026, 10, 14, 23)),
            Play(title: "Open Ocean", at: Clock.date(2026, 9, 3)),
        ])
        let suggestions = index.recallSuggestions(now: Clock.now, calendar: Clock.calendar)
        #expect(suggestions == ["Last Night", "In September"])
        for phrase in suggestions {
            #expect(Clock.parse(phrase).hasFilters)
        }
    }
}
