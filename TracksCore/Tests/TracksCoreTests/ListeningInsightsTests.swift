import Testing
import Foundation
@testable import TracksCore

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2
    return calendar
}()

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private func play(
    _ title: String,
    by artist: String = "Mara Solis",
    album: String? = nil,
    at when: Date,
    kind: CaptureKind = .onDemand,
    key: String? = nil
) -> CaptureStat {
    CaptureStat(
        songKey: key ?? title,
        title: title,
        artistName: artist,
        albumTitle: album,
        capturedAt: when,
        kind: kind
    )
}

@Suite("Listening estimate")
struct ListeningEstimateTests {
    @Test func `a song lasts until the next one starts`() {
        let seconds = ListeningEstimate.seconds(for: [
            play("a", at: date(2026, 9, 7, 9, 0)),
            play("b", at: date(2026, 9, 7, 9, 4)),
        ])
        #expect(seconds == [240, ListeningEstimate.typicalSongSeconds])
    }

    @Test func `a long gap means the music stopped`() {
        let seconds = ListeningEstimate.seconds(for: [
            play("a", at: date(2026, 9, 7, 9)),
            play("b", at: date(2026, 9, 7, 13)),
        ])
        #expect(seconds[0] == ListeningEstimate.typicalSongSeconds)
    }

    @Test func `imported songs are not measured against each other`() {
        let found = date(2026, 9, 7, 9)
        let seconds = ListeningEstimate.seconds(for: [
            play("a", at: found, kind: .imported),
            play("b", at: found, kind: .imported),
            play("c", at: found.addingTimeInterval(1), kind: .imported),
        ])
        #expect(seconds.allSatisfy { $0 == ListeningEstimate.typicalSongSeconds })
    }

    @Test func `the next song can be outside the range`() {
        // Sunday 23:58 then Monday 00:01: the Sunday song still gets three minutes.
        let captures = [
            play("late", at: date(2026, 9, 6, 23, 58)),
            play("early", at: date(2026, 9, 7, 0, 1)),
        ]
        let summary = StatsCalculator.summary(
            range: .week, captures: captures, sessions: [],
            calendar: calendar, now: date(2026, 9, 6, 23, 59)
        )
        #expect(summary.captureCount == 1)
        #expect(summary.listeningSeconds == 180)
    }
}

@Suite("Comparing periods")
struct ComparisonTests {
    @Test func `this week is compared with the same days of last week`() {
        // Wednesday 9 September 2026. Last week had two songs on Tuesday and five on Friday.
        var captures = (0..<2).map { play("tue\($0)", at: date(2026, 9, 1, 10 + $0)) }
        captures += (0..<5).map { play("fri\($0)", at: date(2026, 9, 4, 10 + $0)) }
        captures += (0..<3).map { play("now\($0)", at: date(2026, 9, 8, 10 + $0)) }

        let summary = StatsCalculator.summary(
            range: .week, captures: captures, sessions: [],
            calendar: calendar, now: date(2026, 9, 9, 18)
        )
        #expect(summary.captureCount == 3)
        // Friday hasn't happened yet this week, so it isn't counted last week either.
        #expect(summary.previousCaptureCount == 2)
        #expect(summary.captureCountDelta == 1)
    }

    @Test func `last month means the calendar month`() {
        let september = StatsRange.month.interval(containing: date(2026, 9, 15), calendar: calendar)!
        let august = StatsRange.month.previousInterval(before: september, calendar: calendar)
        #expect(august?.start == date(2026, 8, 1, 0))
        #expect(august?.end == date(2026, 9, 1, 0))
    }

    @Test func `no comparison without earlier history`() {
        let summary = StatsCalculator.summary(
            range: .week,
            captures: [play("a", at: date(2026, 9, 8))],
            sessions: [], calendar: calendar, now: date(2026, 9, 9)
        )
        #expect(summary.previousCaptureCount == nil)
        #expect(summary.listeningChange == nil)
    }

    @Test func `the daily average only counts days that have happened`() {
        // Two hours on Monday, and it is now Tuesday: an hour a day, not 17 minutes.
        let captures = (0..<40).map { play("s\($0)", at: date(2026, 9, 7, 9).addingTimeInterval(Double($0) * 180)) }
        let summary = StatsCalculator.summary(
            range: .week, captures: captures, sessions: [],
            calendar: calendar, now: date(2026, 9, 8, 12)
        )
        let expected = (39 * 180 + ListeningEstimate.typicalSongSeconds) / 2
        #expect(summary.dailyAverageSeconds == expected)
    }
}

@Suite("Recent days")
struct RecentDaysTests {
    @Test func `seven days, today last, empty days kept`() {
        let history = ListeningHistory([
            play("a", at: date(2026, 9, 3, 9)),
            play("b", at: date(2026, 9, 9, 9)),
            play("c", at: date(2026, 9, 9, 10)),
        ])
        let days = StatsCalculator.recentDays(7, history: history, calendar: calendar, now: date(2026, 9, 9, 18))
        #expect(days.count == 7)
        #expect(days.last?.start == date(2026, 9, 9, 0))
        #expect(days.map(\.count) == [1, 0, 0, 0, 0, 0, 2])
    }
}

@Suite("Streaks")
struct StreakTests {
    @Test func `a streak survives until a whole day is missed`() {
        let history = ListeningHistory([
            play("a", at: date(2026, 9, 5)),
            play("b", at: date(2026, 9, 6)),
            play("c", at: date(2026, 9, 7)),
        ])
        // Tuesday morning, nothing played yet today.
        let streak = StatsCalculator.streak(in: history, calendar: calendar, now: date(2026, 9, 8, 8))
        #expect(streak.current == 3)
        #expect(streak.currentStart == date(2026, 9, 5, 0))
    }

    @Test func `a missed day ends it`() {
        let history = ListeningHistory([
            play("a", at: date(2026, 9, 1)),
            play("b", at: date(2026, 9, 2)),
            play("c", at: date(2026, 9, 3)),
            play("d", at: date(2026, 9, 5)),
        ])
        let streak = StatsCalculator.streak(in: history, calendar: calendar, now: date(2026, 9, 7))
        #expect(streak.current == 0)
        #expect(streak.longest == 3)
    }
}

@Suite("Charts")
struct ChartTests {
    @Test func `one song heard on two devices is one entry`() {
        // The iPhone keys by catalog id, the Mac by title and artist.
        let history = ListeningHistory([
            play("Saltwater", at: date(2026, 9, 7, 9), key: "1440833098"),
            play("Saltwater", at: date(2026, 9, 7, 20), key: "saltwater\u{1F}mara solis"),
            play("saltwater ", at: date(2026, 9, 8, 9), key: "other"),
        ])
        let chart = StatsCalculator.songChart(range: .week, history: history, calendar: calendar, now: date(2026, 9, 8))
        #expect(chart.count == 1)
        #expect(chart.first?.item.count == 3)
    }

    @Test func `ties share a rank`() {
        #expect(StatsCalculator.competitionRanks([9, 5, 5, 5, 2]) == [1, 2, 2, 2, 5])
    }

    @Test func `movement is measured against last week's chart`() {
        let lastWeek = [
            play("A", at: date(2026, 8, 31)), play("A", at: date(2026, 8, 31)), play("A", at: date(2026, 9, 1)),
            play("B", at: date(2026, 9, 1)), play("B", at: date(2026, 9, 2)),
        ]
        let thisWeek = [
            play("B", at: date(2026, 9, 7)), play("B", at: date(2026, 9, 7)), play("B", at: date(2026, 9, 8)),
            play("A", at: date(2026, 9, 8)),
            play("C", at: date(2026, 9, 8)), play("C", at: date(2026, 9, 8, 13)),
        ]
        let chart = StatsCalculator.songChart(
            range: .week, history: ListeningHistory(lastWeek + thisWeek),
            calendar: calendar, now: date(2026, 9, 9)
        )
        #expect(chart.map(\.item.title) == ["B", "C", "A"])
        #expect(chart[0].movement == .up(1))
        #expect(chart[1].movement == .new)
        #expect(chart[2].movement == .down(2))
    }

    @Test func `all time has no movement`() {
        let chart = StatsCalculator.artistChart(
            range: .allTime,
            history: ListeningHistory([play("A", at: date(2026, 9, 1))]),
            calendar: calendar, now: date(2026, 9, 9)
        )
        #expect(chart.first?.movement == ChartMovement.none)
    }

    @Test func `albums need an album name`() {
        let history = ListeningHistory([
            play("One", album: "Home", at: date(2026, 9, 7)),
            play("Two", album: "Home", at: date(2026, 9, 7, 13)),
            play("Three", at: date(2026, 9, 7, 14)),
            play("Four", by: "Juniper Lane", album: "Home", at: date(2026, 9, 7, 15)),
        ])
        let albums = StatsCalculator.albumChart(range: .allTime, history: history, calendar: calendar, now: date(2026, 9, 8))
        #expect(albums.map(\.item.count) == [2, 1])
        #expect(albums.first?.item.songCount == 2)
    }
}

@Suite("Highlights")
struct HighlightTests {
    private func summary(_ captures: [CaptureStat], range: StatsRange = .month, now: Date = date(2026, 9, 20)) -> StatsSummary {
        StatsCalculator.summary(range: range, captures: captures, sessions: [], calendar: calendar, now: now)
    }

    @Test func `the thousandth song is a milestone`() {
        let start = date(2026, 9, 1)
        let captures = (0..<1_010).map { play("s\($0 % 300)", by: "a\($0 % 20)", at: start.addingTimeInterval(Double($0) * 600)) }
        let milestone = summary(captures).insights.first { $0.id == "milestone" }
        #expect(milestone == .milestone(count: 1_000, reachedOn: captures[999].capturedAt))
    }

    @Test func `a song played three times in a day is on repeat`() {
        var captures = (0..<3).map { play("Loop", at: date(2026, 9, 14, 9 + $0)) }
        captures += [play("Other", at: date(2026, 9, 15))]
        #expect(summary(captures).insights.contains {
            if case .onRepeat(let title, _, 3, _) = $0 { return title == "Loop" }
            return false
        })
        #expect(!summary(captures).insights.contains { $0.id == "repeatedSong" })
    }

    /// Dictionary order changes from one launch to the next, so a tie decided by it showed a
    /// different song each time.
    @Test(arguments: 0..<12)
    func `a tie on repeat goes to the same song every time`(pair: Int) throws {
        let day = date(2026, 9, 14)
        let captures = ["b", "a"].flatMap { side in
            (0..<3).map { play("loop \(pair)\(side)", at: day.addingTimeInterval(Double($0) * 3_600 + (side == "a" ? 600 : 0))) }
        }
        let onRepeat = try #require(summary(captures).insights.first { $0.id == "onRepeat" })
        guard case .onRepeat(let title, _, 3, _) = onRepeat else {
            Issue.record("expected a song on repeat, got \(onRepeat)")
            return
        }
        #expect(title == "loop \(pair)a")
    }

    /// A six hour session that began the evening before the month counts its two hours in
    /// it, as the listening totals do.
    @Test func `the longest session only counts its time in the range`() {
        let captures = (0..<4).map { play("s\($0)", at: date(2026, 9, 1, 1).addingTimeInterval(Double($0) * 600)) }
        let session = SessionStat(startedAt: date(2026, 8, 31, 20), finishedAt: date(2026, 9, 1, 2), stationName: "Apple Music 1")
        let summary = StatsCalculator.summary(
            range: .month, captures: captures, sessions: [session], calendar: calendar, now: date(2026, 9, 20)
        )
        #expect(summary.insights.contains(.longestSession(minutes: 120)))
    }

    @Test func `nothing counts as new in someone's first week`() {
        let captures = (0..<12).map { play("s\($0)", by: "artist \($0)", at: date(2026, 9, 14, 8 + $0)) }
        let insights = summary(captures).insights
        #expect(!insights.contains { $0.id == "newArtists" || $0.id == "allNew" || $0.id == "mostlyNew" })
    }

    @Test func `new artists are counted once there's history`() {
        var captures = [play("old", by: "Juniper Lane", at: date(2026, 7, 1))]
        captures += (0..<4).map { play("s\($0)", by: "artist \($0)", at: date(2026, 9, 14, 8 + $0)) }
        #expect(summary(captures).insights.contains(.newArtists(count: 4)))
    }

    @Test func `late listening makes a night owl`() {
        let captures = (0..<24).map { index in
            play("s\(index)", at: date(2026, 9, 1 + index % 12, index.isMultiple(of: 2) ? 23 : 14))
        }
        #expect(summary(captures).insights.contains { $0.id == "persona" })
    }

    @Test func `a big swing in listening is a trend`() {
        // Two hours on the 1st of August, an hour on the 1st of September.
        let august = (0..<40).map { play("a\($0)", at: date(2026, 8, 1, 9).addingTimeInterval(Double($0) * 180)) }
        let september = (0..<20).map { play("s\($0)", at: date(2026, 9, 1, 9).addingTimeInterval(Double($0) * 180)) }
        let trend = summary(august + september, now: date(2026, 9, 1, 20)).insights.first { $0.id == "listeningTrend" }
        guard case .listeningTrend(let percent, .month) = trend else {
            Issue.record("expected a trend, got \(String(describing: trend))")
            return
        }
        #expect(percent < -40)
    }
}

@Suite("Profiles and search")
struct ProfileTests {
    let history = ListeningHistory([
        play("Saltwater", album: "Tides", at: date(2026, 9, 1)),
        play("Saltwater", album: "Tides", at: date(2026, 9, 2)),
        play("Undertow", album: "Tides", at: date(2026, 9, 3)),
        play("Paper Moon", by: "Juniper Lane", at: date(2026, 9, 3)),
    ])

    @Test func `an artist page has their songs and rank`() throws {
        let profile = try #require(StatsCalculator.artistProfile(id: "mara solis", history: history, calendar: calendar, now: date(2026, 9, 5)))
        #expect(profile.artist.count == 3)
        #expect(profile.songs.map(\.title) == ["Saltwater", "Undertow"])
        #expect(profile.allTimeRank == 1)
        #expect(profile.share == 0.75)
    }

    @Test func `a song page lists every play, newest first`() throws {
        let id = HistoryImport.key(title: "Saltwater", artistName: "Mara Solis")
        let profile = try #require(StatsCalculator.songProfile(id: id, history: history, calendar: calendar, now: date(2026, 9, 5)))
        #expect(profile.plays == [date(2026, 9, 2), date(2026, 9, 1)])
        #expect(profile.artistID == "mara solis")
        #expect(profile.timelineUnit == .weekOfYear)
        #expect(profile.timeline.reduce(0) { $0 + $1.count } == 2)
    }

    @Test func `search ignores case, accents and word order`() {
        let results = StatsCalculator.search("tides MARÁ", in: history)
        #expect(results.songs.map(\.title) == ["Saltwater", "Undertow"])
        #expect(results.albums.map(\.title) == ["Tides"])
        #expect(StatsCalculator.search("   ", in: history).isEmpty)
    }
}
