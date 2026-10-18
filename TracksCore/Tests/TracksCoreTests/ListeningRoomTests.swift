import Foundation
import Testing
@testable import TracksCore

struct ListeningRoomTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    struct Play {
        var title: String
        var genre: String
        var year: Int? = nil
        /// Days before now, and the hour it was played.
        var daysAgo: Double
        var hour: Int = 20
    }

    func history(_ plays: [Play]) -> ListeningHistory {
        var stats: [CaptureStat] = []
        var metadata: [String: SongMetadata] = [:]
        for play in plays {
            let day = calendar.startOfDay(for: now.addingTimeInterval(-play.daysAgo * 86_400))
            let date = day.addingTimeInterval(Double(play.hour) * 3_600)
            stats.append(CaptureStat(songKey: play.title, songID: play.title, title: play.title, artistName: "Artist", capturedAt: date))
            metadata[HistoryImport.key(title: play.title, artistName: "Artist")] = SongMetadata(genre: play.genre, releaseYear: play.year)
        }
        return ListeningHistory(stats).with(artistArtwork: [:], songMetadata: metadata)
    }

    @Test("a mood holds your songs whose genre suits it, the most played first")
    func moodSongs() {
        let room = ListeningRoom.mood(.chill, in: history([
            Play(title: "Calm", genre: "Ambient", daysAgo: 1),
            Play(title: "Calm", genre: "Ambient", daysAgo: 2),
            Play(title: "Smooth", genre: "Jazz", daysAgo: 3),
            Play(title: "Loud", genre: "Metal", daysAgo: 1),
        ]), now: now, calendar: calendar)
        #expect(room.songs.map(\.song.title) == ["Calm", "Smooth"])
        #expect(room.plays == 3)
    }

    @Test("when you play it most is said only once one part of the day stands out")
    func peak() {
        let evenings = (0..<12).map { Play(title: "Song \($0 % 4)", genre: "Jazz", daysAgo: Double($0), hour: 19) }
        #expect(ListeningRoom.genre(MusicGenre.all.first { $0.id == "jazz" }!, in: history(evenings), now: now, calendar: calendar).peak == .evening)
        let few = Array(evenings.prefix(5))
        #expect(ListeningRoom.genre(MusicGenre.all.first { $0.id == "jazz" }!, in: history(few), now: now, calendar: calendar).peak == nil)
    }

    @Test("Wind Down keeps evening songs and runs from brighter genres to calmer")
    func windDown() {
        let room = ListeningRoom.mood(.chill, in: history([
            Play(title: "Morning", genre: "Ambient", daysAgo: 1, hour: 8),
            Play(title: "Ambient", genre: "Ambient", daysAgo: 1),
            Play(title: "Indie", genre: "Indie Rock", daysAgo: 2),
            Play(title: "Soul", genre: "Soul", daysAgo: 3),
        ]), now: now, calendar: calendar)
        let order = room.windDown().map(\.song.title)
        #expect(!order.contains("Morning"))
        #expect(order.last == "Ambient")
    }

    @Test("a section with fewer than three songs says too little to show")
    func fewest() {
        let room = ListeningRoom.mood(.heartbreak, in: history([
            Play(title: "Again", genre: "Blues", daysAgo: 1),
            Play(title: "Again", genre: "Blues", daysAgo: 1),
            Play(title: "Again", genre: "Blues", daysAgo: 1),
        ]), now: now, calendar: calendar)
        #expect(room.overAndOver().isEmpty)
    }

    @Test("over and over finds songs played three times or more in one day")
    func overAndOver() {
        let plays = ["A", "B", "C"].flatMap { title in (0..<3).map { _ in Play(title: title, genre: "Blues", daysAgo: 4) } }
            + [Play(title: "Once", genre: "Blues", daysAgo: 1)]
        let room = ListeningRoom.mood(.heartbreak, in: history(plays), now: now, calendar: calendar)
        #expect(Set(room.overAndOver().map(\.song.title)) == ["A", "B", "C"])
        #expect(room.overAndOver().allSatisfy { $0.bestDay == 3 })
    }

    @Test("rising holds songs played more in the last 30 days than the 30 before")
    func rising() {
        let plays = ["Up", "Up2", "Up3"].flatMap { title in [Play(title: title, genre: "Rap", daysAgo: 2), Play(title: title, genre: "Rap", daysAgo: 5)] }
            + [Play(title: "Down", genre: "Rap", daysAgo: 40), Play(title: "Down", genre: "Rap", daysAgo: 45), Play(title: "Down", genre: "Rap", daysAgo: 3)]
        let room = ListeningRoom.genre(MusicGenre.all.first { $0.id == "hip-hop" }!, in: history(plays), now: now, calendar: calendar)
        #expect(Set(room.rising().map(\.song.title)) == ["Up", "Up2", "Up3"])
    }

    @Test("decades show only once your songs span two or more")
    func decades() {
        let ninetiesOnly = ListeningRoom.genre(MusicGenre.all.first { $0.id == "rock" }!, in: history([
            Play(title: "A", genre: "Rock", year: 1991, daysAgo: 1),
            Play(title: "B", genre: "Rock", year: 1997, daysAgo: 1),
        ]), now: now, calendar: calendar)
        #expect(ninetiesOnly.decades().isEmpty)

        let spread = ListeningRoom.genre(MusicGenre.all.first { $0.id == "rock" }!, in: history([
            Play(title: "A", genre: "Rock", year: 1991, daysAgo: 1),
            Play(title: "B", genre: "Rock", year: 2004, daysAgo: 1),
            Play(title: "C", genre: "Rock", daysAgo: 1),
        ]), now: now, calendar: calendar)
        #expect(spread.decades().map(\.start) == [1990, 2000])
    }

    @Test("songs heard on the road are the ones played inside a drive")
    func onTheRoad() {
        let titles = ["A", "B", "C", "D"]
        let plays = titles.map { Play(title: $0, genre: "Indie Rock", daysAgo: 1, hour: 18) }
        let day = calendar.startOfDay(for: now.addingTimeInterval(-86_400))
        let drive = DateInterval(start: day.addingTimeInterval(17.5 * 3_600), duration: 3_600)
        let room = ListeningRoom.mood(.drive, in: history(plays), drives: DriveLog(drives: [drive]), now: now, calendar: calendar)
        #expect(room.onTheRoad().count == 4)
        let withoutDrives = ListeningRoom.mood(.drive, in: history(plays), now: now, calendar: calendar)
        #expect(withoutDrives.onTheRoad().isEmpty)
    }
}

// MARK: - Bucketing and sections

extension ListeningRoomTests {
    static let day: TimeInterval = 86_400

    struct At {
        var title: String
        var genre: String? = "Jazz"
        var date: Date
    }

    func room(_ plays: [At], calendar: Calendar? = nil) -> ListeningRoom {
        var stats: [CaptureStat] = []
        var metadata: [String: SongMetadata] = [:]
        for play in plays {
            stats.append(CaptureStat(songKey: play.title, songID: play.title, title: play.title, artistName: "Artist", capturedAt: play.date))
            if let genre = play.genre {
                metadata[HistoryImport.key(title: play.title, artistName: "Artist")] = SongMetadata(genre: genre, releaseYear: nil)
            }
        }
        let history = ListeningHistory(stats).with(artistArtwork: [:], songMetadata: metadata)
        return ListeningRoom(matching: { _ in true }, in: history, now: now, calendar: calendar ?? self.calendar)
    }

    func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    func plays(_ title: String, _ count: Int, genre: String? = "Jazz", at date: Date) -> [At] {
        (0..<count).map { At(title: title, genre: genre, date: date.addingTimeInterval(Double(-$0))) }
    }

    func song(_ title: String, in room: ListeningRoom) throws -> ListeningRoom.Song {
        try #require(room.songs.first { $0.song.title == title })
    }

    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0, in calendar: Calendar? = nil) -> Date {
        (calendar ?? self.calendar).date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test("the last 30 days include their first instant; the 30 before end just short of it")
    func recentAndEarlier() throws {
        let room = room([
            At(title: "Edge", date: ago(30 * Self.day)),
            At(title: "Before", date: ago(30 * Self.day + 1)),
            At(title: "Before", date: ago(60 * Self.day)),
            At(title: "Before", date: ago(60 * Self.day + 1)),
        ])
        let edge = try song("Edge", in: room)
        #expect(edge.recentPlays == 1)
        #expect(edge.earlierPlays == 0)
        let before = try song("Before", in: room)
        #expect(before.recentPlays == 0)
        #expect(before.earlierPlays == 2)
    }

    @Test("months count each calendar month once, across month and year ends")
    func months() throws {
        let room = room([
            At(title: "Turn", date: date(2025, 1, 31, 23)),
            At(title: "Turn", date: date(2025, 2, 1, 0, 30)),
            At(title: "Years", date: date(2024, 12, 10)),
            At(title: "Years", date: date(2025, 12, 10)),
            At(title: "Years", date: date(2025, 12, 20)),
        ])
        #expect(try song("Turn", in: room).months == 2)
        #expect(try song("Years", in: room).months == 2)
    }

    @Test("the best day is the busiest calendar day")
    func bestDay() throws {
        let room = room([
            At(title: "Late", date: date(2025, 3, 10, 23)),
            At(title: "Late", date: date(2025, 3, 10, 23, 30)),
            At(title: "Late", date: date(2025, 3, 11, 0, 10)),
        ])
        #expect(try song("Late", in: room).bestDay == 2)
    }

    @Test("plays are counted by part of the day, at the calendar's local hour")
    func partPlays() throws {
        let hours = [4, 22, 5, 12, 17]
        let room = room(hours.map { At(title: "Parts", date: date(2025, 3, 10, $0)) })
        let parts = try song("Parts", in: room).partPlays
        #expect(parts[DayPart.night.rawValue] == 2)
        #expect(parts[DayPart.morning.rawValue] == 1)
        #expect(parts[DayPart.afternoon.rawValue] == 1)
        #expect(parts[DayPart.evening.rawValue] == 1)
    }

    @Test("parts of the day and months follow the calendar passed in, not the machine's")
    func timeZone() throws {
        var plusTen = Calendar(identifier: .gregorian)
        plusTen.timeZone = TimeZone(secondsFromGMT: 10 * 3_600)!
        let plays = [
            At(title: "Zone", date: date(2026, 1, 31, 20)),
            At(title: "Zone", date: date(2026, 2, 1, 3)),
        ]
        let inUTC = try song("Zone", in: room(plays))
        #expect(inUTC.months == 2)
        #expect(inUTC.partPlays[DayPart.evening.rawValue] == 1)
        #expect(inUTC.partPlays[DayPart.night.rawValue] == 1)

        let inPlusTen = try song("Zone", in: room(plays, calendar: plusTen))
        #expect(inPlusTen.months == 1)
        #expect(inPlusTen.partPlays[DayPart.morning.rawValue] == 1)
        #expect(inPlusTen.partPlays[DayPart.afternoon.rawValue] == 1)
    }

    @Test("songs without a genre are left out, and the rest run most played, then most recent")
    func roomOrder() {
        let room = room(
            plays("Unknown", 9, genre: nil, at: ago(Self.day))
                + plays("Older", 2, at: ago(10 * Self.day))
                + plays("Newer", 2, at: ago(2 * Self.day))
                + plays("Most", 3, at: ago(20 * Self.day))
        )
        #expect(room.songs.map(\.song.title) == ["Most", "Newer", "Older"])
    }

    @Test("this month: two or more plays in the last 30 days, most recent plays first")
    func thisMonth() {
        let room = room(
            plays("Three", 3, at: ago(Self.day))
                + plays("TwoMany", 2, at: ago(2 * Self.day)) + plays("TwoMany", 50, at: ago(100 * Self.day))
                + plays("TwoFew", 2, at: ago(3 * Self.day)) + plays("TwoFew", 1, at: ago(100 * Self.day))
                + plays("One", 1, at: ago(Self.day)) + plays("One", 20, at: ago(200 * Self.day))
        )
        #expect(room.thisMonth().map(\.song.title) == ["Three", "TwoMany", "TwoFew"])
        #expect(room.thisMonth(limit: 1).map(\.song.title) == ["Three"])
    }

    @Test("this month needs three qualifying songs")
    func thisMonthFewest() {
        let room = room(plays("A", 2, at: ago(Self.day)) + plays("B", 2, at: ago(Self.day)) + plays("C", 1, at: ago(Self.day)))
        #expect(room.thisMonth().isEmpty)
    }

    @Test("month after month: three or more months, the most months first, then the most plays")
    func monthAfterMonth() {
        func monthsAgo(_ months: Int) -> Date { calendar.date(byAdding: .month, value: -months, to: now)! }
        let room = room(
            (0..<4).flatMap { plays("Four", 1, at: monthsAgo($0)) }
                + (0..<3).flatMap { plays("FiveInThree", $0 == 0 ? 3 : 1, at: monthsAgo($0)) }
                + (0..<3).flatMap { plays("FourInThree", $0 == 0 ? 2 : 1, at: monthsAgo($0)) }
                + (0..<3).flatMap { plays("Three", 1, at: monthsAgo($0)) }
                + plays("TenInTwo", 5, at: monthsAgo(0)) + plays("TenInTwo", 5, at: monthsAgo(1))
        )
        #expect(room.monthAfterMonth().map(\.song.title) == ["Four", "FiveInThree", "FourInThree", "Three"])
    }

    @Test("throwbacks: first heard over a year ago and played in the last three months")
    func throwbacks() {
        let room = room(
            plays("Long", 2, at: ago(500 * Self.day)) + plays("Long", 1, at: ago(30 * Self.day))
                + plays("Year", 1, at: ago(400 * Self.day)) + plays("Year", 1, at: ago(10 * Self.day))
                + plays("EdgeLast", 1, at: ago(366 * Self.day)) + plays("EdgeLast", 1, at: ago(90 * Self.day))
                + [At(title: "EdgeFirst", date: ago(365 * Self.day)), At(title: "EdgeFirst", date: ago(Self.day))]
                + plays("Lapsed", 1, at: ago(400 * Self.day)) + [At(title: "Lapsed", date: ago(90 * Self.day + 1))]
        )
        #expect(room.throwbacks().map(\.song.title) == ["Long", "Year", "EdgeLast"])
    }

    @Test("instrumental genres are told by their name, ignoring case and accents", arguments: [
        ("Classical", true), ("Neo-Classical", true), ("Ambient", true), ("Soundtrack", true),
        ("Original Score", true), ("New Age", true), ("Piano", true), ("Chamber Music", true),
        ("Baroque", true), ("CLÁSSICAL", true), ("Orchestral", true), ("Instrumental Hip-Hop", true),
        ("Hip-Hop/Rap", false), ("Pop", false), ("Jazz", false), ("", false),
    ])
    func isInstrumental(genre: String, expected: Bool) {
        #expect(ListeningRoom.isInstrumental(genre) == expected)
    }

    /// Product decision pinned: a hint anywhere in the name counts.
    @Test("a hint inside a longer name counts too", arguments: ["Chamber Pop", "Underscore"])
    func isInstrumentalSubstring(genre: String) {
        #expect(ListeningRoom.isInstrumental(genre))
    }

    @Test("instrumental first: instrumental songs in room order, then the rest")
    func instrumentalFirst() {
        let room = room(
            plays("Pop5", 5, genre: "Pop", at: ago(Self.day))
                + plays("Piano3", 3, genre: "Piano", at: ago(Self.day))
                + plays("Rock4", 4, genre: "Rock", at: ago(Self.day))
                + plays("Ambient2", 2, genre: "Ambient", at: ago(Self.day))
                + plays("Score1", 1, genre: "Soundtrack", at: ago(Self.day))
        )
        #expect(room.instrumentalFirst().map(\.song.title) == ["Piano3", "Ambient2", "Score1", "Pop5", "Rock4"])
        #expect(room.instrumentalFirst(limit: 4).map(\.song.title) == ["Piano3", "Ambient2", "Score1", "Pop5"])
    }

    @Test("instrumental first needs three instrumental songs")
    func instrumentalFirstFewest() {
        let room = room(
            plays("Piano", 3, genre: "Piano", at: ago(Self.day))
                + plays("Ambient", 2, genre: "Ambient", at: ago(Self.day))
                + plays("Pop", 5, genre: "Pop", at: ago(Self.day))
                + plays("Rock", 4, genre: "Rock", at: ago(Self.day))
        )
        #expect(room.instrumentalFirst().isEmpty)
    }

    @Test("instrumental first with a small limit keeps only instrumental songs")
    func instrumentalFirstLimit() {
        let room = room(
            (1...5).flatMap { plays("Piano\($0)", 6 - $0, genre: "Piano", at: ago(Self.day)) }
                + plays("Pop", 9, genre: "Pop", at: ago(Self.day))
        )
        #expect(room.instrumentalFirst(limit: 2).map(\.song.title) == ["Piano1", "Piano2"])
    }

    func atHour(_ title: String, _ hour: Int, _ count: Int) -> [At] {
        (0..<count).map { At(title: title, date: date(2026, 1, 10, hour, $0 % 60)) }
    }

    @Test("late night: at least half the plays between 22:00 and 04:59")
    func lateNight() {
        let room = room(
            atHour("Half", 23, 1) + atHour("Half", 19, 1)
                + atHour("Night", 2, 3)
                + atHour("Late", 22, 2)
                + atHour("Almost", 23, 49) + atHour("Almost", 19, 51)
        )
        #expect(Set(room.lateNight().map(\.song.title)) == ["Half", "Night", "Late"])
    }

    @Test("mornings: at least half the plays between 05:00 and 11:59")
    func mornings() {
        let room = room(
            atHour("Half", 5, 1) + atHour("Half", 13, 1)
                + atHour("Early", 11, 3)
                + atHour("Mid", 8, 2)
                + atHour("Almost", 9, 49) + atHour("Almost", 13, 51)
        )
        #expect(Set(room.mornings().map(\.song.title)) == ["Half", "Early", "Mid"])
    }
}
