import Foundation

/// The start of the calendar unit a date falls in, reusing the last answer while dates stay
/// inside the same unit.
///
/// Calendar arithmetic costs about a microsecond a call, and the statistics used to do it for
/// every play, several times over: a hundred and fifty thousand plays spent over a second of
/// a Summary on `startOfDay` alone. Plays come oldest first, so consecutive ones nearly always
/// share a day, and one lookup per day does.
public struct CalendarUnitCursor: Sendable {
    public let calendar: Calendar
    public let unit: Calendar.Component
    private var current: DateInterval?

    public init(calendar: Calendar, unit: Calendar.Component) {
        self.calendar = calendar
        self.unit = unit
    }

    /// The same as `calendar.dateInterval(of: unit, for: date)`.
    public mutating func interval(containing date: Date) -> DateInterval? {
        if let current, current.start <= date, date < current.end { return current }
        current = calendar.dateInterval(of: unit, for: date)
        return current
    }

    /// The same as `calendar.dateInterval(of: unit, for: date)?.start`, which for `.day` is
    /// `calendar.startOfDay(for:)`.
    public mutating func start(of date: Date) -> Date? {
        interval(containing: date)?.start
    }
}

/// The calendar facts the statistics need about a moment, worked out once per day.
///
/// The day, weekday, weekend and year are the same for every play on a day. The hour is
/// the time since the day began, except on the days the clocks change, when the calendar is
/// asked. So a long history costs one set of calendar calls per day, not per play.
struct DayClock {
    struct Facts {
        let day: DateInterval
        let hour: Int
        let weekday: Int
        let isWeekend: Bool
        let year: Int
    }

    private struct Day {
        let interval: DateInterval
        let weekday: Int
        let isWeekend: Bool
        let year: Int
        /// False on a day the clocks change, when elapsed time isn't the clock time.
        let isSteady: Bool
    }

    let calendar: Calendar
    private var days: CalendarUnitCursor
    private var current: Day?

    init(calendar: Calendar) {
        self.calendar = calendar
        days = CalendarUnitCursor(calendar: calendar, unit: .day)
    }

    mutating func facts(for date: Date) -> Facts? {
        if current.map({ $0.interval.start <= date && date < $0.interval.end }) != true {
            guard let interval = days.interval(containing: date) else { return nil }
            current = Day(
                interval: interval,
                weekday: calendar.component(.weekday, from: interval.start),
                isWeekend: calendar.isDateInWeekend(interval.start),
                year: calendar.component(.year, from: interval.start),
                isSteady: Self.isSteady(interval, calendar: calendar)
            )
        }
        guard let day = current else { return nil }
        let hour = day.isSteady
            ? Int(date.timeIntervalSince(day.interval.start)) / 3_600
            : calendar.component(.hour, from: date)
        return Facts(day: day.interval, hour: hour, weekday: day.weekday, isWeekend: day.isWeekend, year: day.year)
    }

    /// Whether the time since `day` began is its clock time. Not on a day the clocks change,
    /// including one where they change at midnight and the day starts at 1 AM, with the same
    /// offset all day.
    static func isSteady(_ day: DateInterval, calendar: Calendar) -> Bool {
        let zone = calendar.timeZone
        return zone.secondsFromGMT(for: day.start) == zone.secondsFromGMT(for: day.end.addingTimeInterval(-1))
            && calendar.component(.hour, from: day.start) == 0
    }
}
