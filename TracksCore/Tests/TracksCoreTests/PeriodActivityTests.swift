import Testing
import Foundation
@testable import TracksCore

@Suite("Period activity")
struct PeriodActivityTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        calendar.firstWeekday = 1
        return calendar
    }()

    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func play(_ title: String, at date: Date, artist: String = "Artist", album: String? = nil) -> CaptureStat {
        CaptureStat(songKey: title, title: title, artistName: artist, albumTitle: album, capturedAt: date, kind: .onDemand)
    }

    /// Thursday 24 September 2026.
    var now: Date { date(2026, 9, 24, 21) }

    @Test("a week has a bar for each of its seven days, today's plays in today's bar")
    func week() {
        let history = ListeningHistory([
            play("A", at: date(2026, 9, 21)),
            play("B", at: date(2026, 9, 24, 9)),
            play("C", at: date(2026, 9, 24, 20)),
        ])
        let period = ChartPeriod.containing(now, span: .week, calendar: calendar)
        let activity = history.activity(in: period, now: now, calendar: calendar)
        #expect(activity.buckets.count == 7)
        #expect(activity.buckets.map(\.plays) == [0, 1, 0, 0, 2, 0, 0])
        #expect(activity.bucketSpan == .day)
        #expect(activity.plays == 3)
        #expect(activity.busiest == 2)
    }

    @Test("a day has an hour for each hour, and 23 on the day the clocks go forward")
    func dayHours() {
        let ordinary = ChartPeriod.containing(date(2026, 9, 24), span: .day, calendar: calendar)
        #expect(ListeningHistory([]).activity(in: ordinary, now: now, calendar: calendar).buckets.count == 24)
        let springForward = ChartPeriod.containing(date(2026, 3, 8), span: .day, calendar: calendar)
        #expect(ListeningHistory([]).activity(in: springForward, now: now, calendar: calendar).buckets.count == 23)
        #expect(ListeningHistory([]).activity(in: ordinary, now: now, calendar: calendar).bucketSpan == nil)
    }

    @Test("a month has its days and a year its months")
    func monthAndYear() {
        let history = ListeningHistory([])
        let february = ChartPeriod.containing(date(2028, 2, 10), span: .month, calendar: calendar)
        #expect(history.activity(in: february, now: now, calendar: calendar).buckets.count == 29)
        let year = ChartPeriod.containing(now, span: .year, calendar: calendar)
        let activity = history.activity(in: year, now: now, calendar: calendar)
        #expect(activity.buckets.count == 12)
        #expect(activity.bucketSpan == .month)
    }

    @Test("all time runs from the year of the first play to this one")
    func allTime() {
        let history = ListeningHistory([
            play("A", at: date(2023, 5, 1)),
            play("B", at: date(2026, 1, 3)),
        ])
        let period = ChartPeriod.containing(now, span: .allTime, calendar: calendar)
        let activity = history.activity(in: period, now: now, calendar: calendar)
        #expect(activity.buckets.map(\.plays) == [1, 0, 0, 1])
        #expect(activity.previousPlays == nil)
        #expect(ListeningHistory([]).activity(in: period, now: now, calendar: calendar).buckets.isEmpty)
    }

    @Test("counts songs, artists, albums and first hearings once each")
    func totals() {
        let history = ListeningHistory([
            play("Old", at: date(2026, 8, 1)),
            play("Old", at: date(2026, 9, 21), album: "One"),
            play("New", at: date(2026, 9, 22), artist: "Other", album: "Two"),
            play("New", at: date(2026, 9, 23), artist: "Other", album: "Two"),
        ])
        let period = ChartPeriod.containing(now, span: .week, calendar: calendar)
        let activity = history.activity(in: period, now: now, calendar: calendar)
        #expect(activity.plays == 3)
        #expect(activity.songs == 2)
        #expect(activity.artists == 2)
        #expect(activity.albums == 2)
        #expect(activity.newSongs == 1)
        #expect(activity.newArtists == [StatsCalculator.folded("Other")])
    }

    @Test("compares with the period before")
    func change() {
        let history = ListeningHistory([
            play("A", at: date(2026, 9, 15)),
            play("B", at: date(2026, 9, 16)),
            play("C", at: date(2026, 9, 22)),
            play("D", at: date(2026, 9, 22)),
            play("E", at: date(2026, 9, 23)),
        ])
        let period = ChartPeriod.containing(now, span: .week, calendar: calendar)
        let activity = history.activity(in: period, now: now, calendar: calendar)
        #expect(activity.previousPlays == 2)
        #expect(activity.change == 0.5)
        let quiet = ChartPeriod.containing(date(2026, 9, 1), span: .week, calendar: calendar)
        #expect(history.activity(in: quiet, now: now, calendar: calendar).change == nil)
    }

    /// Thursday evening against all of last week made every week look like a slump until
    /// Saturday. And three one-minute songs aren't more listening than two whole ones.
    @Test("a week under way is compared in listening time with last week up to the same point")
    func changeComparesListeningSoFar() throws {
        let monday = date(2026, 9, 14)
        let history = ListeningHistory([
            // Last week: three songs a minute apart, so 60, 60 and a typical song's seconds.
            play("A", at: monday),
            play("B", at: monday.addingTimeInterval(60)),
            play("C", at: monday.addingTimeInterval(120)),
            // Friday, later in the week than this one has reached.
            play("D", at: date(2026, 9, 18)),
            // This week: two whole songs.
            play("E", at: date(2026, 9, 22)),
            play("F", at: date(2026, 9, 23)),
        ])
        let period = ChartPeriod.containing(now, span: .week, calendar: calendar)
        let activity = history.activity(in: period, now: now, calendar: calendar)
        let song = ListeningEstimate.typicalSongSeconds
        #expect(activity.previousPlays == 3)
        #expect(activity.previousSeconds == 120 + song)
        let change = try #require(activity.change)
        #expect(abs(change - (2 * song - (120 + song)) / (120 + song)) < 0.000_1)

        // Once the week is over, it's compared with the whole week before it.
        let later = history.activity(in: period, now: date(2026, 10, 1), calendar: calendar)
        #expect(later.previousPlays == 4)
        #expect(later.previousSeconds == 120 + 2 * song)
    }
}
