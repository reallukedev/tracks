import SwiftUI
import TracksCore

extension Insight.Category {
    var tint: Color {
        switch self {
        case .achievement: .orange
        case .trend: .blue
        case .favourites: .pink
        case .discovery: .purple
        case .rhythm: .indigo
        case .radio: .red
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .achievement: "Achievement"
        case .trend: "Trend"
        case .favourites: "Favorites"
        case .discovery: "Discovery"
        case .rhythm: "Rhythm"
        case .radio: "Radio"
        }
    }
}

extension CaptureKind {
    var tint: Color {
        switch self {
        case .onDemand: .accentColor
        case .radio: .pink
        case .imported: .teal
        case .lastFM: .red
        }
    }

    var symbol: String {
        switch self {
        case .onDemand: "music.note"
        case .radio: "dot.radiowaves.left.and.right"
        case .imported: "clock.arrow.circlepath"
        case .lastFM: "waveform"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .onDemand: "On Demand"
        case .radio: "Radio"
        case .imported: "Recovered"
        case .lastFM: "Last.fm"
        }
    }
}

extension StatsRange {
    var label: LocalizedStringKey {
        switch self {
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        case .allTime: "All Time"
        }
    }

    /// "this week", for sentences.
    var phrase: LocalizedStringKey {
        switch self {
        case .week: "this week"
        case .month: "this month"
        case .year: "this year"
        case .allTime: "of all time"
        }
    }

    /// "last week", for the comparison under a number.
    var previousPhrase: LocalizedStringKey {
        switch self {
        case .week: "this time last week"
        case .month: "this time last month"
        case .year: "this time last year"
        case .allTime: ""
        }
    }

    /// "This Week", for a chart's key.
    var currentTitle: LocalizedStringKey {
        switch self {
        case .week: "This Week"
        case .month: "This Month"
        case .year: "This Year"
        case .allTime: "All Time"
        }
    }

    /// "Last Week", for a chart's key.
    var previousTitle: LocalizedStringKey {
        switch self {
        case .week: "Last Week"
        case .month: "Last Month"
        case .year: "Last Year"
        case .allTime: ""
        }
    }
}

extension DayPart {
    var name: LocalizedStringKey {
        switch self {
        case .morning: "Morning"
        case .afternoon: "Afternoon"
        case .evening: "Evening"
        case .night: "Night"
        }
    }

    var symbol: String {
        switch self {
        case .morning: "sunrise.fill"
        case .afternoon: "sun.max.fill"
        case .evening: "sunset.fill"
        case .night: "moon.stars.fill"
        }
    }

    /// "5 AM–12 PM", in the locale's clock.
    var hours: String {
        "\(Format.hour(startHour))–\(Format.hour(endHour))"
    }
}

extension SessionLength {
    /// Short enough for a chart axis.
    var shortLabel: LocalizedStringKey {
        switch self {
        case .underFifteenMinutes: "<15m"
        case .underHalfHour: "15–30m"
        case .underHour: "30–60m"
        case .underTwoHours: "1–2h"
        case .twoHoursOrMore: "2h+"
        }
    }

    /// Spelled out, for VoiceOver.
    var spokenLabel: String {
        switch self {
        case .underFifteenMinutes: String(localized: "Under 15 minutes")
        case .underHalfHour: String(localized: "15 to 30 minutes")
        case .underHour: String(localized: "30 minutes to an hour")
        case .underTwoHours: String(localized: "1 to 2 hours")
        case .twoHoursOrMore: String(localized: "2 hours or more")
        }
    }
}

enum Metrics {
    #if os(iOS)
    static let cardRadius: CGFloat = 26
    static let cardPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 28
    /// Between cards in a row or a column.
    static let cardSpacing: CGFloat = 12
    #else
    static let cardRadius: CGFloat = 16
    static let cardPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 24
    static let cardSpacing: CGFloat = 16
    #endif
}
