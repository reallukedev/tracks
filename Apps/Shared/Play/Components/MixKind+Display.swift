import SwiftUI
import TracksCore

extension MixKind {
    var title: String {
        switch self {
        case .rightNow(let part, _):
            switch part {
            case .morning: String(localized: "Morning Mix")
            case .afternoon: String(localized: "Afternoon Mix")
            case .evening: String(localized: "Evening Mix")
            case .night: String(localized: "Late Night Mix")
            }
        case .onRepeat: String(localized: "On Repeat")
        case .allTimeFavorites: String(localized: "All-Time Favorites")
        case .deepCuts: String(localized: "Deep Cuts")
        case .newFinds: String(localized: "New Finds")
        case .radioFinds: String(localized: "Radio Finds")
        case .rediscover: String(localized: "Rediscover")
        case .throwback(let months, _):
            switch months {
            case 12: String(localized: "A Year Ago")
            case 6: String(localized: "Six Months Ago")
            default: String(localized: "Three Months Ago")
            }
        }
    }

    /// One line on why these songs: the mix's reason for being, never its settings.
    var reason: String {
        switch self {
        case .rightNow(let part, let isWeekend):
            switch (part, isWeekend) {
            case (.morning, false): String(localized: "What you play most on weekday mornings")
            case (.afternoon, false): String(localized: "What you play most on weekday afternoons")
            case (.evening, false): String(localized: "What you play most on weekday evenings")
            case (.night, false): String(localized: "What you play most late on weeknights")
            case (.morning, true): String(localized: "What you play most on weekend mornings")
            case (.afternoon, true): String(localized: "What you play most on weekend afternoons")
            case (.evening, true): String(localized: "What you play most on weekend evenings")
            case (.night, true): String(localized: "What you play most late on weekends")
            }
        case .onRepeat: String(localized: "Your most played this month")
        case .allTimeFavorites: String(localized: "Your most played ever, the ones still in rotation first")
        case .deepCuts: String(localized: "Songs you've barely played by the artists you play most")
        case .newFinds: String(localized: "New to you this month, and played again")
        case .radioFinds: String(localized: "Heard on the radio, never picked yourself")
        case .rediscover: String(localized: "Old favorites you haven't played lately")
        case .throwback(_, let around):
            String(localized: "What you played the week of \(around.formatted(.dateTime.month(.abbreviated).day().year()))")
        }
    }

    /// Short enough to sit under a tile on the shelf. The full reason is on the mix's page.
    var tileLine: String {
        switch self {
        case .rightNow(let part, let isWeekend):
            switch (part, isWeekend) {
            case (.morning, false): String(localized: "Weekday mornings")
            case (.afternoon, false): String(localized: "Weekday afternoons")
            case (.evening, false): String(localized: "Weekday evenings")
            case (.night, false): String(localized: "Late weeknights")
            case (.morning, true): String(localized: "Weekend mornings")
            case (.afternoon, true): String(localized: "Weekend afternoons")
            case (.evening, true): String(localized: "Weekend evenings")
            case (.night, true): String(localized: "Late weekends")
            }
        case .onRepeat: String(localized: "Most played lately")
        case .allTimeFavorites: String(localized: "Most played ever")
        case .deepCuts: String(localized: "Barely played")
        case .newFinds: String(localized: "New this month")
        case .radioFinds: String(localized: "Heard on the radio")
        case .rediscover: String(localized: "Old favorites")
        case .throwback(_, let around): around.formatted(.dateTime.month(.wide).year())
        }
    }

    /// "WEEKDAY EVENING", above the Right Now mix.
    var eyebrow: String? {
        guard case .rightNow(let part, let isWeekend) = self else { return nil }
        return switch (part, isWeekend) {
        case (.morning, false): String(localized: "Weekday Morning")
        case (.afternoon, false): String(localized: "Weekday Afternoon")
        case (.evening, false): String(localized: "Weekday Evening")
        case (.night, false): String(localized: "Weeknight")
        case (.morning, true): String(localized: "Weekend Morning")
        case (.afternoon, true): String(localized: "Weekend Afternoon")
        case (.evening, true): String(localized: "Weekend Evening")
        case (.night, true): String(localized: "Weekend Night")
        }
    }

    var symbol: String {
        switch self {
        case .rightNow(let part, _): part.symbol
        case .onRepeat: "repeat"
        case .allTimeFavorites: "heart.fill"
        case .deepCuts: "square.stack.3d.down.right"
        case .newFinds: "star.fill"
        case .radioFinds: "dot.radiowaves.left.and.right"
        case .rediscover: "arrow.counterclockwise"
        case .throwback: "calendar"
        }
    }
}
