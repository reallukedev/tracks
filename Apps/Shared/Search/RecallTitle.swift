import Foundation
import TracksCore

/// What a remembered search understood, in words: a title for when or around what ("Last
/// Night", "September", "After Driftwood"), and the rest of it as a line under it ("On the
/// Radio · 1990s · Chill").
struct RecallTitle: Equatable {
    let title: String
    let detail: String?

    init(_ recall: HistoryRecall, anchor: String?, now: Date = .now, calendar: Calendar = .current) {
        var parts: [String] = []
        var title: String?

        if let relation = recall.relation, let anchor {
            title = switch relation {
            case .after: String(localized: "After \(anchor)")
            case .before: String(localized: "Before \(anchor)")
            }
        }
        if let interval = recall.interval, let span = recall.span {
            let when = Self.when(interval, span: span, part: recall.partOfDay, now: now, calendar: calendar)
            if title == nil { title = when.title } else { parts.append(when.title) }
            if let part = when.part { parts.append(part) }
        } else if let part = recall.partOfDay {
            let name = Self.plural(part)
            if title == nil { title = name } else { parts.append(name) }
        }
        if let weekday = recall.weekday {
            let name = Self.pluralWeekday(weekday, calendar: calendar)
            if title == nil { title = name } else { parts.append(name) }
        }
        if let station = recall.station {
            if title == nil { title = station } else { parts.append(station) }
        } else if recall.radioOnly {
            let radio = String(localized: "On the Radio")
            if title == nil { title = radio } else { parts.append(radio) }
        }
        if let decade = recall.decade {
            let name = String(localized: "\(decade.formatted(.number.grouping(.never)))s")
            if title == nil { title = String(localized: "Released in the \(name)") } else { parts.append(name) }
        }
        if let mood = recall.mood {
            if title == nil { title = mood.title } else { parts.append(mood.title) }
        }
        if !recall.words.isEmpty {
            parts.append(String(localized: "Matching “\(recall.words.joined(separator: " "))”"))
        }
        self.title = title ?? String(localized: "Songs")
        detail = parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A day, a night or a longer span named the way you'd say it, nearest first: "This
    /// Evening", "Last Night", "Tuesday", then dates.
    private static func when(
        _ interval: DateInterval,
        span: HistoryRecall.Span,
        part: HistoryRecall.PartOfDay?,
        now: Date,
        calendar: Calendar
    ) -> (title: String, part: String?) {
        let start = interval.start
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: start)
        let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        let weekday = start.formatted(.dateTime.weekday(.wide))
        let date = start.formatted(.dateTime.weekday(.wide).month(.wide).day())

        switch span {
        case .day:
            guard let part else {
                switch daysAgo {
                case 0: return (String(localized: "Today"), nil)
                case 1: return (String(localized: "Yesterday"), nil)
                case 2..<7: return (weekday, nil)
                default: return (date, nil)
                }
            }
            switch daysAgo {
            case 0: return (thisPart(part), nil)
            case 1: return (String(localized: "Yesterday \(name(of: part))"), nil)
            case 2..<7: return (String(localized: "\(weekday) \(name(of: part))"), nil)
            default: return (date, name(of: part))
            }
        case .night:
            switch daysAgo {
            case 0: return (String(localized: "Tonight"), nil)
            case 1: return (String(localized: "Last Night"), nil)
            case 2..<7: return (String(localized: "\(weekday) Night"), nil)
            default: return (date, String(localized: "Night"))
            }
        case .weekend:
            let partName = part.map(plural)
            if interval.contains(now) { return (String(localized: "This Weekend"), partName) }
            if interval.end <= now, now.timeIntervalSince(interval.end) < 6 * 86_400 {
                return (String(localized: "Last Weekend"), partName)
            }
            return (String(localized: "Weekend of \(start.formatted(.dateTime.month(.wide).day()))"), partName)
        case .week:
            let partName = part.map(plural)
            if interval.contains(now) { return (String(localized: "This Week"), partName) }
            if interval.end == calendar.dateInterval(of: .weekOfYear, for: now)?.start {
                return (String(localized: "Last Week"), partName)
            }
            return (String(localized: "Week of \(start.formatted(.dateTime.month(.wide).day()))"), partName)
        case .month:
            let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: now)
            let name = sameYear ? start.formatted(.dateTime.month(.wide)) : start.formatted(.dateTime.month(.wide).year())
            return (name, part.map(plural))
        case .year:
            let yearsAgo = calendar.component(.year, from: now) - calendar.component(.year, from: start)
            let name = switch yearsAgo {
            case 0: String(localized: "This Year")
            case 1: String(localized: "Last Year")
            default: calendar.component(.year, from: start).formatted(.number.grouping(.never))
            }
            return (name, part.map(plural))
        case .season(let season):
            let year = calendar.component(.year, from: start).formatted(.number.grouping(.never))
            let title = switch season {
            case .spring: String(localized: "Spring \(year)")
            case .summer: String(localized: "Summer \(year)")
            case .autumn: String(localized: "Autumn \(year)")
            case .winter: String(localized: "Winter \(year)")
            }
            return (title, part.map(plural))
        }
    }

    private static func name(of part: HistoryRecall.PartOfDay) -> String {
        switch part {
        case .morning: String(localized: "Morning")
        case .afternoon: String(localized: "Afternoon")
        case .evening: String(localized: "Evening")
        case .night: String(localized: "Night")
        }
    }

    private static func thisPart(_ part: HistoryRecall.PartOfDay) -> String {
        switch part {
        case .morning: String(localized: "This Morning")
        case .afternoon: String(localized: "This Afternoon")
        case .evening: String(localized: "This Evening")
        case .night: String(localized: "Tonight")
        }
    }

    private static func plural(_ part: HistoryRecall.PartOfDay) -> String {
        switch part {
        case .morning: String(localized: "Mornings")
        case .afternoon: String(localized: "Afternoons")
        case .evening: String(localized: "Evenings")
        case .night: String(localized: "Late Nights")
        }
    }

    private static func pluralWeekday(_ weekday: Int, calendar: Calendar) -> String {
        let names = calendar.standaloneWeekdaySymbols
        let name = names.indices.contains(weekday - 1) ? names[weekday - 1] : ""
        return String(localized: "\(name)s")
    }
}
