import Testing
import Foundation
@testable import TracksCore

/// A fixed UTC calendar, so results don't depend on the machine's time zone.
private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 1
    return calendar
}()

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute
    ))!
}

private func capture(
    _ songKey: String,
    artist: String = "An Artist",
    at when: Date,
    station: String? = nil
) -> CaptureStat {
    CaptureStat(
        songKey: songKey,
        title: songKey,
        artistName: artist,
        capturedAt: when,
        stationName: station
    )
}

@Suite("Statistics")
struct StatsCalculatorTests {

    /// A song first heard last year isn't new this week, which is why the calculator gets
    /// the whole history.
    @Test("first time heard is judged against all history, not the range")
    func firstHearingSpansAllHistory() {
        let captures = [
            capture("old-song", at: date(2025, 3, 1)),
            capture("old-song", at: date(2026, 9, 8)),
            capture("new-song", at: date(2026, 9, 8)),
        ]
        let summary = StatsCalculator.summary(
            range: .week,
            captures: captures,
            sessions: [],
            calendar: calendar,
            now: date(2026, 9, 8)
        )
        #expect(summary.captureCount == 2)
        #expect(summary.firstTimeHeardCount == 1)
        #expect(summary.firstTimeHeardRate == 0.5)
    }

    /// 0% would read as "you discovered nothing".
    @Test("an empty range has no rate rather than a zero one")
    func emptyRangeHasNoRate() {
        let summary = StatsCalculator.summary(
            range: .week,
            captures: [],
            sessions: [],
            calendar: calendar,
            now: date(2026, 9, 8)
        )
        #expect(summary.firstTimeHeardRate == nil)
        #expect(summary.isEmpty)
    }

    @Test("a session straddling the boundary is clipped, not double counted")
    func sessionsAreClipped() {
        // Two hours, half of it before this month began.
        let session = SessionStat(
            startedAt: date(2026, 8, 31, 23),
            finishedAt: date(2026, 9, 1, 1),
            stationName: "Apple Music 1"
        )
        let summary = StatsCalculator.summary(
            range: .month,
            captures: [],
            sessions: [session],
            calendar: calendar,
            now: date(2026, 9, 8)
        )
        #expect(summary.sessionCount == 1)
        #expect(summary.radioSessionSeconds == 3600)
    }

    @Test("all time counts a session whole")
    func allTimeCountsWholeSessions() {
        let session = SessionStat(
            startedAt: date(2026, 8, 31, 23),
            finishedAt: date(2026, 9, 1, 1),
            stationName: nil
        )
        let summary = StatsCalculator.summary(
            range: .allTime,
            captures: [],
            sessions: [session],
            calendar: calendar,
            now: date(2026, 9, 8)
        )
        #expect(summary.radioSessionSeconds == 7200)
    }

    @Test("the heat map is a full grid with the counts in the right cells")
    func heatMapIsComplete() throws {
        // 2026-09-08 is a Tuesday, which Calendar numbers 3.
        let captures = [
            capture("a", at: date(2026, 9, 8, 21)),
            capture("b", at: date(2026, 9, 8, 21, 30)),
            capture("c", at: date(2026, 9, 8, 9)),
        ]
        let summary = StatsCalculator.summary(
            range: .allTime,
            captures: captures,
            sessions: [],
            calendar: calendar,
            now: date(2026, 9, 8)
        )
        #expect(summary.heatMap.count == 7 * 24)
        let evening = try #require(summary.heatMap.first { $0.weekday == 3 && $0.hour == 21 })
        #expect(evening.count == 2)
        #expect(summary.busiestCell == evening)
        #expect(summary.heatMap.filter { $0.count == 0 }.count == 7 * 24 - 2)
    }

    /// Ties break by name so the list doesn't reshuffle between renders.
    @Test("rankings are ordered by count then name")
    func rankingIsStable() {
        let ranked = StatsCalculator.rank(["Beta", "Alpha", "Beta", "Alpha", "Gamma"], limit: 5)
        #expect(ranked == [
            NamedCount(name: "Alpha", count: 2),
            NamedCount(name: "Beta", count: 2),
            NamedCount(name: "Gamma", count: 1),
        ])
    }

    @Test("blank names are not ranked and not counted as artists")
    func blankNamesAreIgnored() {
        let captures = [
            capture("a", artist: "Real Artist", at: date(2026, 9, 8)),
            capture("b", artist: "   ", at: date(2026, 9, 8)),
            capture("c", artist: "", at: date(2026, 9, 8)),
        ]
        let summary = StatsCalculator.summary(
            range: .allTime,
            captures: captures,
            sessions: [],
            calendar: calendar,
            now: date(2026, 9, 8)
        )
        #expect(summary.uniqueArtistCount == 1)
        #expect(summary.topArtists.map(\.name) == ["Real Artist"])
        #expect(summary.topArtists.map(\.count) == [1])
    }

    /// On a real database 13 of 15 captures had no station, so the chart showed one bar of 2
    /// under a headline of 15 songs.
    @Test("captures with no station are counted, not dropped")
    func stationsRankedAndUnattributedCounted() {
        let captures = [
            capture("a", at: date(2026, 9, 8), station: "Apple Music 1"),
            capture("b", at: date(2026, 9, 8), station: "Apple Music 1"),
            capture("c", at: date(2026, 9, 8), station: nil),
            capture("d", at: date(2026, 9, 8), station: "   "),
        ]
        let summary = StatsCalculator.summary(
            range: .allTime,
            captures: captures,
            sessions: [],
            calendar: calendar,
            now: date(2026, 9, 8)
        )
        #expect(summary.topStations == [NamedCount(name: "Apple Music 1", count: 2)])
        #expect(summary.captureCount == 4)
        // A blank station name counts as no station.
        #expect(summary.capturesWithoutStation == 2)
    }
    
    @Test("week range covers 7 days")
    func weekInterval() throws {
        let interval = try #require(StatsRange.week.interval(containing: date(2026, 9, 8), calendar: calendar))
        #expect(interval.duration == 7 * 24 * 3600)
        #expect(interval.contains(date(2026, 9, 8)))
    }

    @Test("month range covers 30 days")
    func monthInterval() throws {
        let interval = try #require(StatsRange.month.interval(containing: date(2026, 9, 8), calendar: calendar))
        #expect(interval.duration == 30 * 24 * 3600)
        #expect(interval.contains(date(2026, 9, 8)))
    }

    @Test("all time has no interval")
    func allTimeIsUnbounded() {
        #expect(StatsRange.allTime.interval(containing: .now, calendar: calendar) == nil)
    }

    /// 5,000 captures is years of heavy listening, which the summary has to get right before
    /// anyone cares how fast it is.
    @Test("a heavy history is summarised correctly")
    func summarisesAHeavyHistory() {
        let (captures, sessions) = Self.heavyHistory()
        let summary = StatsCalculator.summary(
            range: .allTime,
            captures: captures,
            sessions: sessions,
            calendar: calendar,
            now: date(2026, 9, 8)
        )

        #expect(summary.captureCount == 5_000)
        #expect(summary.uniqueSongCount == 1_200)
        #expect(summary.firstTimeHeardCount == 1_200)
    }

    /// Decides whether ``StatsSnapshot``'s cache is needed. 5,000 captures (years of heavy
    /// listening) take single-digit milliseconds, so nothing is cached for now.
    ///
    /// Wall-clock timing, so it is off by default: in a normal run every suite executes in
    /// parallel and a loaded machine can take many times longer than the code needs. Run it
    /// on its own, and without the parallel runner for a number worth reading:
    ///
    /// ```sh
    /// TRACKS_PERF_TESTS=1 swift test --no-parallel --filter computesFastEnoughToSkipCaching
    /// ```
    @Test(
        "a heavy history computes fast enough to need no cache",
        .tags(.performance),
        .enabled(
            if: ProcessInfo.processInfo.environment["TRACKS_PERF_TESTS"] != nil,
            "Timing test; set TRACKS_PERF_TESTS=1 to run it"
        )
    )
    func computesFastEnoughToSkipCaching() {
        let (captures, sessions) = Self.heavyHistory()

        // The best of a few runs, so one descheduled moment doesn't decide it.
        let clock = ContinuousClock()
        let fastest = (0..<5).map { _ in
            clock.measure {
                _ = StatsCalculator.summary(
                    range: .allTime,
                    captures: captures,
                    sessions: sessions,
                    calendar: calendar,
                    now: date(2026, 9, 8)
                )
            }
        }.min()!

        // Loose, so a busy CI machine doesn't fail it.
        #expect(fastest < .milliseconds(500), "took \(fastest)")
    }

    /// 5,000 captures of 1,200 songs by 300 artists, half an hour apart, and 500 sessions.
    private static func heavyHistory() -> (captures: [CaptureStat], sessions: [SessionStat]) {
        let start = date(2020, 1, 1)
        let captures = (0..<5_000).map { index in
            capture(
                "song-\(index % 1_200)",
                artist: "artist-\(index % 300)",
                at: start.addingTimeInterval(Double(index) * 1_800),
                station: "station-\(index % 7)"
            )
        }
        let sessions = (0..<500).map { index in
            SessionStat(
                startedAt: start.addingTimeInterval(Double(index) * 18_000),
                finishedAt: start.addingTimeInterval(Double(index) * 18_000 + 3_600),
                stationName: "station-\(index % 7)"
            )
        }
        return (captures, sessions)
    }
}

extension Tag {
    /// Wall-clock measurements. Off unless `TRACKS_PERF_TESTS` is set, since timings taken
    /// alongside hundreds of parallel tests say more about the machine than the code.
    @Tag static var performance: Self
}

/// The charts and the sentences. Mostly about what gets left out, like a one-bar chart or a
/// "busiest hour" from three captures.
@Suite("Statistics charts and insights")
struct StatsChartTests {

    @Test("A week's timeline has one bucket per day, gaps included")
    func timelineKeepsEmptyDays() {
        // Sunday-first week of 2025-06-01.
        let captures = [
            capture("a", at: date(2025, 6, 2, 9)),
            capture("b", at: date(2025, 6, 2, 10)),
            capture("c", at: date(2025, 6, 5, 20)),
        ]
        let summary = StatsCalculator.summary(
            range: .week, captures: captures, sessions: [],
            calendar: calendar, now: date(2025, 6, 3)
        )

        #expect(summary.timelineUnit == .day)
        #expect(summary.timeline.count == 7)
        #expect(summary.timeline.map(\.count) == [0, 2, 0, 0, 1, 0, 0])
        #expect(summary.timelineIsInformative)
    }

    @Test("A year is bucketed by month")
    func yearBucketsByMonth() {
        let summary = StatsCalculator.summary(
            range: .year,
            captures: [capture("a", at: date(2025, 2, 3)), capture("b", at: date(2025, 11, 9))],
            sessions: [], calendar: calendar, now: date(2025, 6, 3)
        )

        #expect(summary.timelineUnit == .month)
        #expect(summary.timeline.count == 12)
        #expect(summary.timeline[1].count == 1)
        #expect(summary.timeline[10].count == 1)
    }

    /// Someone's first day. Hiding the chart left the Listening card an empty box.
    @Test("A single day of listening still gets a chart")
    func oneBucketIsCharted() {
        let summary = StatsCalculator.summary(
            range: .week,
            captures: (0..<6).map { capture("s\($0)", at: date(2025, 6, 2, 9 + $0)) },
            sessions: [], calendar: calendar, now: date(2025, 6, 3)
        )

        #expect(summary.timeline.count == 7)
        #expect(summary.timelineIsInformative)
    }

    /// A history a day old used to be one bar, so the All Time card had no chart at all.
    @Test("All time charts at least the last week")
    func allTimeSpansAWeek() {
        let summary = StatsCalculator.summary(
            range: .allTime,
            captures: [capture("a", at: date(2025, 6, 3, 21)), capture("b", at: date(2025, 6, 3, 22))],
            sessions: [], calendar: calendar, now: date(2025, 6, 3, 23)
        )

        #expect(summary.timelineUnit == .day)
        #expect(summary.timeline.map(\.count) == [0, 0, 0, 0, 0, 0, 2])
        #expect(summary.timeline.first?.start == date(2025, 5, 28, 0))
        #expect(summary.timelineIsInformative)
    }

    @Test("A range with nothing played has no chart")
    func emptyRangeIsNotCharted() {
        let summary = StatsCalculator.summary(
            range: .week,
            captures: [capture("old", at: date(2025, 5, 1, 9))],
            sessions: [], calendar: calendar, now: date(2025, 6, 3)
        )

        #expect(!summary.timelineIsInformative)
    }

    @Test("All twenty-four hours are present")
    func hourlyIsComplete() {
        let summary = StatsCalculator.summary(
            range: .week,
            captures: [capture("a", at: date(2025, 6, 2, 14)), capture("b", at: date(2025, 6, 3, 14))],
            sessions: [], calendar: calendar, now: date(2025, 6, 3)
        )

        #expect(summary.hourly.count == 24)
        #expect(summary.hourly.map(\.hour) == Array(0...23))
        #expect(summary.hourly[14].count == 2)
        #expect(summary.hourly.reduce(0) { $0 + $1.count } == summary.captureCount)
    }

    @Test("Nothing is claimed from a handful of captures")
    func insightsStaySilentOnThinData() {
        let summary = StatsCalculator.summary(
            range: .week,
            captures: [capture("a", at: date(2025, 6, 2, 9))],
            sessions: [], calendar: calendar, now: date(2025, 6, 3)
        )

        #expect(summary.insights.isEmpty)
    }

    @Test("A lone station is not called dominant")
    func singleStationIsNotAnInsight() {
        let captures = (0..<8).map {
            capture("s\($0)", at: date(2025, 6, 2, 9 + $0), station: "Chill")
        }
        let summary = StatsCalculator.summary(
            range: .week, captures: captures, sessions: [],
            calendar: calendar, now: date(2025, 6, 3)
        )

        #expect(!summary.insights.contains { $0.id == "dominantStation" })
    }

    @Test("A station carrying most of the listening is called out")
    func dominantStationIsAnInsight() {
        var captures = (0..<7).map {
            capture("s\($0)", at: date(2025, 6, 2, 9 + $0), station: "Chill")
        }
        captures.append(capture("other", at: date(2025, 6, 3, 9), station: "Hits"))

        let summary = StatsCalculator.summary(
            range: .week, captures: captures, sessions: [],
            calendar: calendar, now: date(2025, 6, 3)
        )

        #expect(summary.insights.contains {
            if case .dominantStation(let name, let count, _) = $0 { return name == "Chill" && count == 7 }
            return false
        })
    }

    @Test("A song heard twice is called out; songs heard once are not")
    func repeatsAreCalledOut() {
        let once = (0..<5).map { capture("s\($0)", at: date(2025, 6, 2, 9 + $0)) }
        #expect(!summary(for: once).insights.contains { $0.id == "repeatedSong" })

        let twice = once + [capture("s0", at: date(2025, 6, 3, 11))]
        #expect(summary(for: twice).insights.contains {
            if case .repeatedSong(_, _, let count) = $0 { return count == 2 }
            return false
        })
    }

    @Test("A single day's listening is never called a weekday habit")
    func busiestDayNeedsMoreThanOneDate() {
        let captures = (0..<8).map { capture("s\($0)", at: date(2025, 6, 2, 9 + $0)) }
        let summary = StatsCalculator.summary(
            range: .month, captures: captures, sessions: [],
            calendar: calendar, now: date(2025, 6, 3)
        )

        #expect(!summary.insights.contains { $0.id == "busiestDay" })
    }

    @Test("Played-back captures are reported")
    func playedBackIsReported() {
        var captures = (0..<4).map { capture("s\($0)", at: date(2025, 6, 2, 9 + $0)) }
        captures[0] = CaptureStat(
            songKey: "s0", title: "s0", artistName: "An Artist",
            capturedAt: date(2025, 6, 2, 9), playedBackAt: date(2025, 6, 2, 18)
        )

        #expect(summary(for: captures).insights.contains {
            if case .playedBack(let count, let total) = $0 { return count == 1 && total == 4 }
            return false
        })
    }

    /// A week's chart already shows its days.
    @Test("Busiest weekday is reserved for ranges wider than a week")
    func busiestDayOnlyBeyondAWeek() {
        // Mondays across three weeks, plus one Wednesday.
        let captures = (0..<6).map { capture("s\($0)", at: date(2025, 6, 2 + ($0 % 3) * 7, 9)) }
            + [capture("odd", at: date(2025, 6, 4, 9))]

        #expect(!summary(for: captures).insights.contains { $0.id == "busiestDay" })
        #expect(
            StatsCalculator.summary(
                range: .month, captures: captures, sessions: [],
                calendar: calendar, now: date(2025, 6, 3)
            ).insights.contains { $0.id == "busiestDay" }
        )
    }

    private func summary(for captures: [CaptureStat]) -> StatsSummary {
        StatsCalculator.summary(
            range: .week, captures: captures, sessions: [],
            calendar: calendar, now: date(2025, 6, 3)
        )
    }
}

/// Santiago changes its clocks at midnight, so 7 September 2025 starts at 1 AM and is 23
/// hours long. Adding a day to it lands at 1 AM on the 8th, which isn't when the 8th starts.
@Suite("Days the clocks change at midnight")
struct MidnightClockChangeTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Santiago")!
        calendar.firstWeekday = 1
        return calendar
    }()

    func date(_ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2025, month: month, day: day, hour: hour))!
    }

    func plays(onDays days: ClosedRange<Int>, month: Int = 9) -> [CaptureStat] {
        days.map { capture("song \($0)", at: date(month, $0)) }
    }

    @Test("every day of the month has its own bar, after the change too")
    func timelineStepsByCalendarDay() {
        let summary = StatsCalculator.summary(
            range: .month,
            captures: plays(onDays: 1...30),
            sessions: [],
            calendar: calendar,
            now: date(9, 30, 20)
        )
        #expect(summary.timeline.count == 30)
        #expect(summary.timeline.map(\.count) == Array(repeating: 1, count: 30))
        #expect(summary.timeline.map(\.start) == (1...30).map { calendar.startOfDay(for: date(9, $0)) })
    }

    @Test("weekly bars start each week where the calendar does")
    func weeklyTimeline() {
        let history = ListeningHistory((0..<6).map { capture("song \($0)", at: date(8, 20 + 7 * $0)) })
        let span = DateInterval(start: date(8, 18), end: date(9, 27))
        let buckets = StatsCalculator.timeline(
            history.captures.indices, in: history, unit: .weekOfYear, span: span, calendar: calendar
        )
        #expect(buckets.map(\.count) == Array(repeating: 1, count: 6))
        #expect(buckets.map(\.start) == buckets.map { calendar.dateInterval(of: .weekOfYear, for: $0.start)?.start })
    }

    @Test("the last seven days are seven calendar days")
    func recentDays() {
        let history = ListeningHistory(plays(onDays: 4...10))
        let days = StatsCalculator.recentDays(7, history: history, calendar: calendar, now: date(9, 10, 20))
        #expect(days.map(\.count) == Array(repeating: 1, count: 7))
        #expect(days.map(\.start) == (4...10).map { calendar.startOfDay(for: date(9, $0)) })
    }

    @Test("a streak runs through the short day")
    func streakSpansTheChange() {
        let history = ListeningHistory(plays(onDays: 5...10))
        let streak = StatsCalculator.streak(in: history, calendar: calendar, now: date(9, 10, 20))
        #expect(streak.current == 6)
        #expect(streak.longest == 6)
        #expect(streak.currentStart == calendar.startOfDay(for: date(9, 5)))
    }

    /// The week starts on the short Sunday, at 1 AM.
    @Test("the days so far count a week that starts on the short day")
    func elapsedDaysCountTheShortDay() throws {
        let interval = try #require(calendar.dateInterval(of: .weekOfYear, for: date(9, 10)))
        let elapsed = StatsCalculator.elapsedDayCount(
            range: .week, interval: interval, history: ListeningHistory([]), calendar: calendar, now: date(9, 10, 20)
        )
        #expect(elapsed == 4)
    }

    @Test("weekday and weekend averages share the listening over every day so far")
    func dayTypeAveragesCountTheShortDay() throws {
        // Monday 1 to Wednesday 10 September: eight weekdays and two weekend days, the
        // Sunday the clocks changed on among them.
        let history = ListeningHistory(plays(onDays: 1...10))
        let interval = try #require(calendar.dateInterval(of: .month, for: date(9, 10)))
        let averages = StatsCalculator.dayTypeAverages(
            history.captures.indices, in: history, range: .month, interval: interval,
            calendar: calendar, now: date(9, 10, 20)
        )
        let song = ListeningEstimate.typicalSongSeconds
        #expect(averages.weekday == song * 8 / 8)
        #expect(averages.weekend == song * 2 / 2)
    }
}
