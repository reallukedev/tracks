import SwiftUI
import TracksCore

/// How a summary names its period. This month reads "this month" and "this time last
/// month"; August, seen from September, reads "in August 2026" and "the month before".
extension StatsSummary {
    /// "September 2026", "Sep 13 – 19", "2026" or "All Time".
    var periodTitle: String {
        guard let interval else { return String(localized: "All Time") }
        switch range {
        case .week:
            return (interval.start..<interval.end.addingTimeInterval(-1)).formatted(.interval.day().month(.abbreviated))
        case .month:
            return interval.start.formatted(.dateTime.month(.wide).year())
        case .year:
            return interval.start.formatted(.dateTime.year())
        case .allTime:
            return String(localized: "All Time")
        }
    }

    /// "this month", or "in August 2026" for one that has ended.
    var phrase: Text {
        isCurrentPeriod ? Text(range.phrase) : Text("in \(periodTitle)")
    }

    /// "this time last month", or "the month before" for one that has ended.
    var previousPhrase: Text {
        guard !isCurrentPeriod else { return Text(range.previousPhrase) }
        return switch range {
        case .week: Text("the week before")
        case .month: Text("the month before")
        case .year: Text("the year before")
        case .allTime: Text(verbatim: "")
        }
    }

    /// A chart key: "This Month", or "August" for one that has ended.
    var currentKeyTitle: Text {
        guard !isCurrentPeriod, let interval else { return Text(range.currentTitle) }
        return Text(Self.shortTitle(of: interval.start, range: range))
    }

    /// The other chart key: "Last Month", or "July" beside August.
    var previousKeyTitle: Text {
        guard !isCurrentPeriod, let interval,
              let previous = range.previousInterval(before: interval)
        else { return Text(range.previousTitle) }
        return Text(Self.shortTitle(of: previous.start, range: range))
    }

    /// "August", "2025", "Week of Sep 13".
    private static func shortTitle(of start: Date, range: StatsRange) -> String {
        switch range {
        case .week: String(localized: "Week of \(start.formatted(.dateTime.day().month(.abbreviated)))")
        case .month: start.formatted(.dateTime.month(.wide))
        case .year: start.formatted(.dateTime.year())
        case .allTime: String(localized: "All Time")
        }
    }
}

extension StatsRange {
    /// "week", "month" or "year", for sentences about moving between them.
    var unitName: LocalizedStringKey {
        switch self {
        case .week: "week"
        case .month: "month"
        case .year: "year"
        case .allTime: "period"
        }
    }
}
