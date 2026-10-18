import Foundation

/// How long a chart covers: a day, a week, a month or a year as the calendar has them, or
/// all time.
public enum ChartSpan: String, CaseIterable, Sendable, Codable, Identifiable {
    case day, week, month, year, allTime

    public var id: String { rawValue }

    /// Where the span on show is remembered.
    public static let storageKey = "chartSpan"

    /// The calendar's unit, so a week starts on the day the person's calendar starts one.
    var component: Calendar.Component? {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        case .allTime: nil
        }
    }
}

/// One chart's stretch of time: a particular day, week, month or year, or all time.
///
/// Periods follow the calendar rather than counting hours, so a day the clocks change is 23
/// or 25 hours long, and a week that runs over New Year is still one week.
public struct ChartPeriod: Sendable, Hashable {
    public let span: ChartSpan
    /// Half-open: a song at midnight belongs to the day it starts. Nil for all time.
    public let interval: DateInterval?

    public init(span: ChartSpan, interval: DateInterval?) {
        self.span = span
        self.interval = interval
    }

    /// The day, week, month or year `date` falls in.
    public static func containing(_ date: Date, span: ChartSpan, calendar: Calendar = .current) -> ChartPeriod {
        ChartPeriod(span: span, interval: span.component.flatMap { calendar.dateInterval(of: $0, for: date) })
    }

    /// The period of the same span just before this one. Nil for all time.
    public func previous(calendar: Calendar = .current) -> ChartPeriod? {
        guard let interval else { return nil }
        return .containing(interval.start.addingTimeInterval(-1), span: span, calendar: calendar)
    }

    /// The period of the same span just after this one. Nil for all time.
    public func next(calendar: Calendar = .current) -> ChartPeriod? {
        guard let interval else { return nil }
        return .containing(interval.end, span: span, calendar: calendar)
    }

    /// Whether `date` is inside it. All time contains everything.
    public func contains(_ date: Date) -> Bool {
        guard let interval else { return true }
        return interval.start <= date && date < interval.end
    }

    /// Whether it's the period happening now: today, this week, this month, this year or all
    /// time.
    public func isCurrent(now: Date = .now) -> Bool {
        contains(now)
    }
}

extension ListeningHistory {
    /// Plays in `period`.
    public func playCount(in period: ChartPeriod) -> Int {
        indices(in: period.interval).count
    }

    /// The latest period before `period` with any plays, passing over the empty ones between.
    /// Nil for all time, and when nothing was played before it.
    public func period(before period: ChartPeriod, calendar: Calendar = .current) -> ChartPeriod? {
        guard let interval = period.interval else { return nil }
        let earlier = indices(in: DateInterval(start: .distantPast, end: interval.start))
        guard let last = earlier.last else { return nil }
        return .containing(captures[last].capturedAt, span: period.span, calendar: calendar)
    }

    /// The earliest period after `period` with any plays, passing over the empty ones between,
    /// and never later than now. With nothing played since, the current period, since that's
    /// where going forward ends. Nil from the current period and for all time.
    public func period(
        after period: ChartPeriod,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> ChartPeriod? {
        guard let interval = period.interval, interval.end <= now else { return nil }
        let later = indices(in: DateInterval(start: interval.end, end: now))
        guard let first = later.first else { return .containing(now, span: period.span, calendar: calendar) }
        return .containing(captures[first].capturedAt, span: period.span, calendar: calendar)
    }
}
