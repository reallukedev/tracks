import Testing
import Foundation
@testable import TracksCore

/// Paging Summary back through earlier weeks, months and years. An ended period is summed up
/// as it stood when it ended, so nothing after it leaks in.
@Suite("Statistics for an earlier period")
struct StatsPeriodTests {
    /// A fixed UTC calendar, so results don't depend on the machine's time zone.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 1
        return calendar
    }()

    /// Mid-September 2026.
    private var now: Date { date(2026, 9, 24) }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func capture(_ songKey: String, at when: Date) -> CaptureStat {
        CaptureStat(songKey: songKey, title: songKey, artistName: "An Artist", capturedAt: when)
    }

    private func summary(_ range: StatsRange, offset: Int, _ captures: [CaptureStat]) -> StatsSummary {
        StatsCalculator.summary(
            range: range,
            captures: captures,
            sessions: [],
            calendar: calendar,
            now: now,
            periodOffset: offset
        )
    }

    @Test("last month covers the whole of August and nothing from September")
    func lastMonthIsAugust() throws {
        let captures = [
            capture("july", at: date(2026, 7, 20)),
            capture("august-a", at: date(2026, 8, 1, 0)),
            capture("august-b", at: date(2026, 8, 31, 23)),
            capture("september", at: date(2026, 9, 2)),
        ]

        let august = summary(.month, offset: -1, captures)

        let interval = try #require(august.interval)
        #expect(interval.start == date(2026, 8, 1, 0))
        #expect(interval.end == date(2026, 9, 1, 0))
        #expect(august.captureCount == 2)
        #expect(august.periodOffset == -1)
        #expect(!august.isCurrentPeriod)
    }

    /// Comparing with "this time last month" only makes sense while a month is under way. An
    /// ended month is compared with the whole month before it.
    @Test("an ended month is compared with the whole month before")
    func endedMonthComparesWholeMonths() {
        let captures = [
            capture("july-early", at: date(2026, 7, 2)),
            capture("july-late", at: date(2026, 7, 30)),
            capture("august", at: date(2026, 8, 10)),
        ]

        let august = summary(.month, offset: -1, captures)

        #expect(august.previousCaptureCount == 2)
    }

    @Test("an earlier period is offered only while there's history before it")
    func earlierPeriodNeedsHistory() {
        let captures = [capture("august", at: date(2026, 8, 10)), capture("september", at: date(2026, 9, 2))]

        #expect(summary(.month, offset: 0, captures).hasEarlierPeriod)
        #expect(!summary(.month, offset: -1, captures).hasEarlierPeriod)
    }

    @Test("a later period than now is never shown")
    func futureIsClamped() {
        let captures = [capture("september", at: date(2026, 9, 2))]

        let clamped = summary(.month, offset: 2, captures)

        #expect(clamped.periodOffset == 0)
        #expect(clamped.captureCount == 1)
    }

    @Test("all time has no earlier period")
    func allTimeDoesNotPage() {
        let captures = [capture("july", at: date(2026, 7, 2))]

        let allTime = summary(.allTime, offset: -3, captures)

        #expect(allTime.periodOffset == 0)
        #expect(allTime.interval == nil)
        #expect(!allTime.hasEarlierPeriod)
    }

    @Test("a week back is the Sunday-to-Saturday week before this one")
    func lastWeek() throws {
        let interval = try #require(summary(.week, offset: -1, []).interval)

        #expect(interval.start == date(2026, 9, 13, 0))
        #expect(interval.end == date(2026, 9, 20, 0))
    }

    /// A streak says "in a row" about today, and a trend compares with "this time last
    /// month". Neither is true of a month that has ended.
    @Test("an ended period leaves out insights about now")
    func endedPeriodDropsInsightsAboutNow() {
        let days = (1...31).map { date(2026, 8, $0) }
        let captures = days.flatMap { day in (0..<3).map { capture("song-\($0)", at: day) } }
            + (1...5).map { capture("july-\($0)", at: date(2026, 7, $0)) }

        let august = summary(.month, offset: -1, captures)

        #expect(!august.insights.contains { !$0.isAboutEndedPeriod })
    }
}
