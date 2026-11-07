import Testing
import Foundation
import TracksCore

@Suite("Stats range periods")
struct StatsRangeNavigationTests {
    static func calendar(_ zone: String = "UTC", firstWeekday: Int = 1) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    static let zones = ["UTC", "America/Chicago"]

    let utc = Self.calendar()

    func date(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0,
        in calendar: Calendar? = nil
    ) -> Date {
        (calendar ?? utc).date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        ))!
    }

    // MARK: - The period containing a date

    @Test("a month runs from its first day to the next month's", arguments: [
        (2026, 2, 10, 28), (2028, 2, 10, 29), (2026, 1, 15, 31), (2026, 9, 8, 30),
    ])
    func month(year: Int, month: Int, day: Int, days: Int) throws {
        let interval = try #require(StatsRange.month.interval(containing: date(year, month, day, 12), calendar: utc))
        #expect(interval.start == date(year, month, 1))
        #expect(interval.duration == Double(days) * 86_400)
    }

    @Test("a month includes its first instant and excludes the next month's")
    func monthEdges() throws {
        let march = try #require(StatsRange.month.interval(containing: date(2026, 3, 31, 23, 59, 59), calendar: utc))
        #expect(march.start == date(2026, 3, 1))
        let april = try #require(StatsRange.month.interval(containing: date(2026, 4, 1), calendar: utc))
        #expect(april.start == date(2026, 4, 1))
        #expect(april.end == date(2026, 5, 1))
    }

    @Test("a week starts on the calendar's first weekday", arguments: [
        (1, 9, 9, 9, 6), (2, 9, 9, 9, 7), (2, 9, 6, 8, 31),
    ])
    func week(firstWeekday: Int, month: Int, day: Int, startMonth: Int, startDay: Int) throws {
        let calendar = Self.calendar(firstWeekday: firstWeekday)
        let interval = try #require(StatsRange.week.interval(containing: date(2026, month, day, 12), calendar: calendar))
        #expect(interval.start == date(2026, startMonth, startDay))
        #expect(interval.duration == 7 * 86_400)
    }

    @Test("a week spans the new year when it falls across it")
    func weekAcrossNewYear() throws {
        let interval = try #require(StatsRange.week.interval(containing: date(2026, 12, 30, 12), calendar: utc))
        #expect(interval.start == date(2026, 12, 27))
        #expect(interval.end == date(2027, 1, 3))
    }

    @Test("the week of a spring-forward change is an hour short and holds the whole Sunday")
    func weekAcrossDST() throws {
        let chicago = Self.calendar("America/Chicago")
        let interval = try #require(StatsRange.week.interval(containing: date(2026, 3, 8, 12, in: chicago), calendar: chicago))
        #expect(interval.duration == 7 * 86_400 - 3_600)
        #expect(interval.contains(date(2026, 3, 8, 0, in: chicago)))
        #expect(interval.contains(date(2026, 3, 8, 23, 59, 59, in: chicago)))
    }

    @Test("a year runs from January to January")
    func year() throws {
        let interval = try #require(StatsRange.year.interval(containing: date(2026, 7, 1), calendar: utc))
        #expect(interval.start == date(2026, 1, 1))
        #expect(interval.end == date(2027, 1, 1))
    }

    @Test("all time has no period")
    func allTime() {
        #expect(StatsRange.allTime.interval(containing: date(2026, 7, 1), calendar: utc) == nil)
        #expect(StatsRange.allTime.previousInterval(before: DateInterval(start: date(2026, 1, 1), end: date(2026, 2, 1)), calendar: utc) == nil)
    }

    // MARK: - The period before

    @Test("the month before follows the calendar", arguments: [
        (2026, 3, 2026, 2, 28), (2026, 1, 2025, 12, 31),
    ])
    func previousMonth(year: Int, month: Int, previousYear: Int, previousMonth: Int, days: Int) throws {
        let current = try #require(StatsRange.month.interval(containing: date(year, month, 10), calendar: utc))
        let previous = try #require(StatsRange.month.previousInterval(before: current, calendar: utc))
        #expect(previous.start == date(previousYear, previousMonth, 1))
        #expect(previous.duration == Double(days) * 86_400)
    }

    @Test("the week before the first week of a year is the last of the year before")
    func previousWeek() throws {
        let current = try #require(StatsRange.week.interval(containing: date(2027, 1, 1, 12), calendar: utc))
        let previous = try #require(StatsRange.week.previousInterval(before: current, calendar: utc))
        #expect(previous.start == date(2026, 12, 20))
        #expect(previous.end == current.start)
    }

    @Test("the year before 2026 is 2025")
    func previousYear() throws {
        let current = try #require(StatsRange.year.interval(containing: date(2026, 5, 1), calendar: utc))
        let previous = try #require(StatsRange.year.previousInterval(before: current, calendar: utc))
        #expect(previous.start == date(2025, 1, 1))
        #expect(previous.end == date(2026, 1, 1))
    }

    @Test("each period before ends where the current one starts", arguments: zones, [1, 2])
    func previousAdjoins(zone: String, firstWeekday: Int) throws {
        let calendar = Self.calendar(zone, firstWeekday: firstWeekday)
        let instants = [date(2026, 3, 9, 12, in: calendar), date(2026, 11, 2, 12, in: calendar), date(2027, 1, 1, 12, in: calendar)]
        for range in [StatsRange.week, .month, .year] {
            for instant in instants {
                let current = try #require(range.interval(containing: instant, calendar: calendar))
                let previous = try #require(range.previousInterval(before: current, calendar: calendar))
                #expect(previous.end == current.start, "\(range) at \(instant)")
                #expect(previous.start < previous.end)
            }
        }
    }

    // MARK: - The end of a period some steps away

    @Test("the current period and all time have no end to page to")
    func noPeriodEnd() {
        #expect(StatsRange.month.periodEnd(offset: 0, from: date(2026, 3, 10), calendar: utc) == nil)
        for offset in [-3, -1, 0, 1] {
            #expect(StatsRange.allTime.periodEnd(offset: offset, from: date(2026, 3, 10), calendar: utc) == nil)
        }
    }

    @Test("the last second of the period that many steps away", arguments: [
        (StatsRange.month, -1, 2026, 3, 31, 2026, 2, 28),
        (.month, -2, 2026, 3, 15, 2026, 1, 31),
        (.month, -1, 2026, 1, 10, 2025, 12, 31),
        (.year, -1, 2026, 6, 1, 2025, 12, 31),
        (.month, 1, 2026, 3, 10, 2026, 4, 30),
    ])
    func periodEnd(range: StatsRange, offset: Int, year: Int, month: Int, day: Int, endYear: Int, endMonth: Int, endDay: Int) {
        let end = range.periodEnd(offset: offset, from: date(year, month, day, 12), calendar: utc)
        #expect(end == date(endYear, endMonth, endDay, 23, 59, 59))
    }

    @Test("a week back ends a second before this week starts", arguments: [1, 2])
    func lastWeekEnd(firstWeekday: Int) throws {
        let calendar = Self.calendar(firstWeekday: firstWeekday)
        let from = date(2026, 9, 9, 12)
        let thisWeek = try #require(StatsRange.week.interval(containing: from, calendar: calendar))
        #expect(StatsRange.week.periodEnd(offset: -1, from: from, calendar: calendar) == thisWeek.start.addingTimeInterval(-1))
    }

    @Test("a period end lies in the period that many steps away, one second before its end", arguments: zones)
    func periodEndRoundTrips(zone: String) throws {
        let calendar = Self.calendar(zone)
        let from = date(2026, 3, 31, 12, in: calendar)
        for range in [StatsRange.week, .month, .year] {
            var expected = try #require(range.interval(containing: from, calendar: calendar))
            for offset in 1...14 {
                expected = try #require(range.previousInterval(before: expected, calendar: calendar))
                let end = try #require(range.periodEnd(offset: -offset, from: from, calendar: calendar))
                let interval = try #require(range.interval(containing: end, calendar: calendar))
                #expect(interval == expected, "\(range) \(-offset)")
                #expect(interval.end == end.addingTimeInterval(1), "\(range) \(-offset)")
            }
        }
    }

    @Test("across a daylight saving change, last month still ends at 23:59:59 local time")
    func periodEndAfterDST() throws {
        let chicago = Self.calendar("America/Chicago")
        let april = date(2026, 4, 15, 12, in: chicago)
        #expect(StatsRange.month.periodEnd(offset: -1, from: april, calendar: chicago) == date(2026, 3, 31, 23, 59, 59, in: chicago))
        let december = date(2026, 12, 15, 12, in: chicago)
        #expect(StatsRange.month.periodEnd(offset: -1, from: december, calendar: chicago) == date(2026, 11, 30, 23, 59, 59, in: chicago))
    }
}
