import Testing
import Foundation
@testable import TracksCore

/// Top Charts for any day, week, month or year: which plays a period holds, how it steps to
/// the periods either side, how entries rank, and how they moved since the period before.
@Suite("Charts through time")
struct ChartPeriodTests {
    private func calendar(zone: String = "UTC", firstWeekday: Int = 1) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func date(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0,
        in calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func play(_ title: String, at when: Date, source: PlaySource = .appleMusic) -> CaptureStat {
        CaptureStat(songKey: title, title: title, artistName: "An Artist", capturedAt: when, kind: .onDemand, source: source)
    }

    // MARK: - Periods

    @Test("the day the clocks go forward is 23 hours, and a late play still belongs to it")
    func daylightSavingDay() throws {
        let calendar = calendar(zone: "America/New_York")
        let spring = ChartPeriod.containing(date(2026, 3, 8, in: calendar), span: .day, calendar: calendar)
        let interval = try #require(spring.interval)

        #expect(interval.duration == 23 * 3_600)
        #expect(spring.contains(date(2026, 3, 8, 23, 30, in: calendar)))
        #expect(!spring.contains(date(2026, 3, 9, 0, 0, in: calendar)))

        let nextDay = try #require(spring.next(calendar: calendar))
        #expect(nextDay.interval?.start == date(2026, 3, 9, 0, in: calendar))
        #expect(nextDay.previous(calendar: calendar) == spring)
    }

    @Test("a week starts on the calendar's first weekday", arguments: [(1, 20), (2, 14)])
    func weekStartFollowsCalendar(firstWeekday: Int, startDay: Int) throws {
        let calendar = calendar(firstWeekday: firstWeekday)
        // Sunday, September 20, 2026.
        let week = ChartPeriod.containing(date(2026, 9, 20, in: calendar), span: .week, calendar: calendar)
        let interval = try #require(week.interval)

        #expect(interval.start == date(2026, 9, startDay, 0, in: calendar))
        #expect(interval.duration == 7 * 86_400)
    }

    @Test("a week over New Year is one week, and January steps back to December")
    func yearBoundaries() throws {
        let calendar = calendar()
        let newYearsWeek = ChartPeriod.containing(date(2026, 1, 1, in: calendar), span: .week, calendar: calendar)
        let week = try #require(newYearsWeek.interval)
        #expect(week.start == date(2025, 12, 28, 0, in: calendar))
        #expect(week.end == date(2026, 1, 4, 0, in: calendar))

        let january = ChartPeriod.containing(date(2026, 1, 15, in: calendar), span: .month, calendar: calendar)
        let december = try #require(january.previous(calendar: calendar))
        #expect(december.interval?.start == date(2025, 12, 1, 0, in: calendar))

        let year2025 = ChartPeriod.containing(date(2025, 6, 1, in: calendar), span: .year, calendar: calendar)
        #expect(year2025.next(calendar: calendar)?.interval?.start == date(2026, 1, 1, 0, in: calendar))
    }

    @Test("all time holds everything and has nothing either side")
    func allTime() {
        let calendar = calendar()
        let allTime = ChartPeriod.containing(.now, span: .allTime, calendar: calendar)
        #expect(allTime.interval == nil)
        #expect(allTime.contains(.distantPast))
        #expect(allTime.previous(calendar: calendar) == nil)
        #expect(allTime.next(calendar: calendar) == nil)
        #expect(ListeningHistory([]).period(before: allTime, calendar: calendar) == nil)
    }

    // MARK: - Stepping over empty periods

    @Test("going back passes over empty days to the last one with plays")
    func backSkipsEmptyDays() throws {
        let calendar = calendar()
        let history = ListeningHistory([
            play("a", at: date(2026, 9, 10, in: calendar)),
            play("b", at: date(2026, 9, 18, 23, 59, in: calendar)),
        ])
        let today = ChartPeriod.containing(date(2026, 9, 24, in: calendar), span: .day, calendar: calendar)

        let back = try #require(history.period(before: today, calendar: calendar))
        #expect(back.interval?.start == date(2026, 9, 18, 0, in: calendar))

        let further = try #require(history.period(before: back, calendar: calendar))
        #expect(further.interval?.start == date(2026, 9, 10, 0, in: calendar))

        #expect(history.period(before: further, calendar: calendar) == nil)
    }

    @Test("going forward passes over empty days, and ends at today even when it's empty")
    func forwardSkipsEmptyDays() throws {
        let calendar = calendar()
        let now = date(2026, 9, 24, 9, in: calendar)
        let history = ListeningHistory([
            play("a", at: date(2026, 9, 10, in: calendar)),
            play("b", at: date(2026, 9, 18, in: calendar)),
        ])
        let tenth = ChartPeriod.containing(date(2026, 9, 10, in: calendar), span: .day, calendar: calendar)

        let forward = try #require(history.period(after: tenth, now: now, calendar: calendar))
        #expect(forward.interval?.start == date(2026, 9, 18, 0, in: calendar))

        let today = try #require(history.period(after: forward, now: now, calendar: calendar))
        #expect(today.isCurrent(now: now))
        #expect(history.playCount(in: today) == 0)

        #expect(history.period(after: today, now: now, calendar: calendar) == nil)
    }

    // MARK: - Ranking

    @Test("equal counts share a rank, in the same order however the plays arrive")
    func tiesAreStable() {
        let calendar = calendar()
        let when = date(2026, 9, 22, 10, in: calendar)
        let plays = [
            play("zulu", at: when), play("alpha", at: when), play("mike", at: when),
            play("alpha", at: when.addingTimeInterval(-60)),
        ]
        let day = ChartPeriod.containing(when, span: .day, calendar: calendar)

        let forwards = StatsCalculator.songChart(in: day, history: ListeningHistory(plays), calendar: calendar)
        let backwards = StatsCalculator.songChart(in: day, history: ListeningHistory(plays.reversed()), calendar: calendar)

        #expect(forwards.map(\.rank) == [1, 2, 2])
        #expect(forwards.map(\.item.title) == ["alpha", "mike", "zulu"])
        #expect(backwards.map(\.item.title) == forwards.map(\.item.title))
    }

    @Test("movement is against the day before: up, down, new")
    func movementAgainstPreviousDay() throws {
        let calendar = calendar()
        let monday = date(2026, 9, 21, 9, in: calendar)
        let tuesday = date(2026, 9, 22, 9, in: calendar)
        let history = ListeningHistory([
            play("first", at: monday), play("first", at: monday), play("second", at: monday),
            play("second", at: tuesday), play("second", at: tuesday), play("first", at: tuesday),
            play("fresh", at: tuesday.addingTimeInterval(-60)),
        ])
        let day = ChartPeriod.containing(tuesday, span: .day, calendar: calendar)

        let chart = StatsCalculator.songChart(in: day, history: history, calendar: calendar)
        let movements = Dictionary(uniqueKeysWithValues: chart.map { ($0.item.title, $0.movement) })

        #expect(movements["second"] == .up(1))
        #expect(movements["first"] == .down(1))
        #expect(movements["fresh"] == .new)
    }

    @Test("with nothing the day before, nothing is marked as moving")
    func noMovementAfterEmptyDay() {
        let calendar = calendar()
        let when = date(2026, 9, 22, in: calendar)
        let history = ListeningHistory([play("only", at: when)])
        let day = ChartPeriod.containing(when, span: .day, calendar: calendar)

        let chart = StatsCalculator.songChart(in: day, history: history, calendar: calendar)
        #expect(chart.map(\.movement) == [ChartMovement.none])
    }

    @Test("an empty day has an empty chart, whatever came before")
    func emptyDay() {
        let calendar = calendar()
        let history = ListeningHistory([play("a", at: date(2026, 9, 20, in: calendar))])
        let empty = ChartPeriod.containing(date(2026, 9, 21, in: calendar), span: .day, calendar: calendar)

        #expect(StatsCalculator.songChart(in: empty, history: history, calendar: calendar).isEmpty)
        #expect(StatsCalculator.artistChart(in: empty, history: history, calendar: calendar).isEmpty)
        #expect(history.playCount(in: empty) == 0)
    }
}
