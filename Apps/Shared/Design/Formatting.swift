import Foundation
import SwiftUI

enum Format {
    /// "42m", "3h 5m", "912h". Under a minute reads "0m"; the estimate isn't that precise.
    static func listening(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        guard minutes > 0 else {
            return Duration.seconds(0).formatted(.units(allowed: [.minutes], width: .narrow, zeroValueUnits: .show(length: 1)))
        }
        let allowed: Set<Duration.UnitsFormatStyle.Unit> = minutes >= 6_000 ? [.hours] : [.hours, .minutes]
        return Duration.seconds(Double(minutes) * 60)
            .formatted(.units(allowed: allowed, width: .narrow, maximumUnitCount: 2))
    }

    /// Hours and minutes as two parts, for the big number on a card ("18" "hr" "20" "min").
    static func listeningParts(_ seconds: TimeInterval) -> (hours: Int, minutes: Int) {
        let minutes = Int((seconds / 60).rounded())
        return (minutes / 60, minutes % 60)
    }

    /// "+12%", "-8%".
    static func percentChange(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false)))
    }

    /// "42%".
    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    /// "1994", with no grouping separator: a year, not a quantity.
    static func year(_ year: Int) -> String {
        year.formatted(.number.grouping(.never))
    }

    /// "1990s".
    static func decade(_ decade: Int) -> String {
        String(localized: "\(self.year(decade))s", comment: "A decade, like 1990s")
    }

    /// "’90s", for a chart axis with many decades on it.
    static func shortDecade(_ decade: Int) -> String {
        let twoDigits = (decade % 100).formatted(.number.precision(.integerLength(2)))
        return String(localized: "’\(twoDigits)s", comment: "A decade, abbreviated, like ’90s")
    }

    /// "1971–1994", or one year when it's the same.
    static func years(_ years: ClosedRange<Int>) -> String {
        years.lowerBound == years.upperBound
            ? year(years.lowerBound)
            : "\(year(years.lowerBound))–\(year(years.upperBound))"
    }

    /// "1.5" or "3", for averages that aren't always whole.
    static func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    /// "Today", "Yesterday", "Sat, Sep 6", or "Sep 6, 2025" for past years. Short enough
    /// for a tile.
    static func compactDay(_ date: Date, calendar: Calendar = .current, now: Date = .now) -> String {
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// "9 AM", localised.
    static func hour(_ hour: Int, calendar: Calendar = .current) -> String {
        guard let date = calendar.date(from: DateComponents(hour: hour % 24)) else { return "\(hour)" }
        return date.formatted(.dateTime.hour())
    }

    /// Today → "Today", yesterday → "Yesterday", this week → "Tuesday", else "7 Sep" (with
    /// the year only when it isn't this year).
    static func day(_ date: Date, calendar: Calendar = .current, now: Date = .now) -> String {
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day,
           days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
        return date.formatted(.dateTime.day().month(.wide).year())
    }

    /// A time for today, "Yesterday", a weekday within the week, otherwise a short date.
    static func relativeTime(_ date: Date, calendar: Calendar = .current, now: Date = .now) -> String {
        // Measured from `now`, not the clock, so a caller that passes its own day gets labels
        // for that day.
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day
        if days == 0 { return date.formatted(date: .omitted, time: .shortened) }
        if days == 1 { return String(localized: "Yesterday") }
        if let days, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return shortDate(date, calendar: calendar, now: now)
    }

    /// "Sep 13, 9:24 PM", with the year only for past years.
    static func shortDateTime(_ date: Date, calendar: Calendar = .current, now: Date = .now) -> String {
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
    }

    static func shortDate(_ date: Date, calendar: Calendar = .current, now: Date = .now) -> String {
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
