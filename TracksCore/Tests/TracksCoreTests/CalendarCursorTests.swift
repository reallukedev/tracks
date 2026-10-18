import Foundation
import Testing
@testable import TracksCore

/// The cursors stand in for calendar calls in every statistic, so they must give exactly the
/// calendar's answers, including on the days the clocks change.
@Suite("Calendar shortcuts")
struct CalendarCursorTests {

    /// New York changes its clocks on 8 March and 1 November 2026. Sydney changes the other
    /// way, and Kathmandu is off by a quarter hour with no changes at all. Santiago changes at
    /// midnight, so on 7 September 2025 the day starts at 1 AM.
    static let zones = ["America/New_York", "Australia/Sydney", "Asia/Kathmandu", "America/Santiago", "UTC"]

    private static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.firstWeekday = 2
        return calendar
    }

    /// Every 17 minutes across the spring and autumn changes, in order, which is how history
    /// is walked.
    private static func datesAcrossClockChanges() -> [Date] {
        let windows: [(start: TimeInterval, days: Double)] = [
            (1_772_755_200, 5), // 6 March 2026
            (1_775_001_600, 7), // 1 April 2026, Sydney's change on the 5th
            (1_793_145_600, 5), // 30 October 2026
            (1_743_724_800, 4), // 4 April 2025, Santiago's change on the 6th
            (1_757_030_400, 4), // 5 September 2025, Santiago's change on the 7th
        ]
        return windows.flatMap { window in
            stride(from: 0, to: window.days * 86_400, by: 17 * 60).map {
                Date(timeIntervalSince1970: window.start + $0)
            }
        }
    }

    @Test("a day cursor agrees with startOfDay", arguments: zones)
    func dayCursorMatchesCalendar(zone: String) {
        let calendar = Self.calendar(zone)
        var cursor = CalendarUnitCursor(calendar: calendar, unit: .day)
        for date in Self.datesAcrossClockChanges() {
            #expect(cursor.start(of: date) == calendar.startOfDay(for: date), "\(date)")
        }
    }

    @Test("a month cursor agrees with the calendar, in any order", arguments: zones)
    func monthCursorMatchesCalendarUnordered(zone: String) {
        let calendar = Self.calendar(zone)
        var cursor = CalendarUnitCursor(calendar: calendar, unit: .month)
        for date in Self.datesAcrossClockChanges().shuffled() {
            #expect(cursor.start(of: date) == calendar.dateInterval(of: .month, for: date)?.start)
        }
    }

    @Test("the day clock's hour, weekday, weekend and year agree with the calendar", arguments: zones)
    func dayClockMatchesCalendar(zone: String) throws {
        let calendar = Self.calendar(zone)
        var clock = DayClock(calendar: calendar)
        for date in Self.datesAcrossClockChanges() {
            let found = clock.facts(for: date)
            let facts = try #require(found)
            #expect(facts.day.start == calendar.startOfDay(for: date))
            #expect(facts.hour == calendar.component(.hour, from: date), "\(date)")
            #expect(facts.weekday == calendar.component(.weekday, from: date))
            #expect(facts.isWeekend == calendar.isDateInWeekend(date))
            #expect(facts.year == calendar.component(.year, from: date))
        }
    }

    @Test("clock seconds agree with the calendar's hour, minute and second", arguments: zones)
    func clockSecondsMatchCalendar(zone: String) throws {
        let calendar = Self.calendar(zone)
        for date in Self.datesAcrossClockChanges() {
            let day = try #require(calendar.dateInterval(of: .day, for: date))
            let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
            let expected = (parts.hour ?? 0) * 3_600 + (parts.minute ?? 0) * 60 + (parts.second ?? 0)
            #expect(StatsCalculator.clockSeconds(of: date, in: day, calendar: calendar) == expected, "\(date)")
        }
    }
}
