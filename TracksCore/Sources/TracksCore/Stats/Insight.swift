import Foundation

/// A highlight we can put into a sentence.
///
/// The view builds the sentence, not us: inflection (`^[\(n) song](inflect: true)`) only
/// works in a string literal, so anything assembled here would read "1 songs".
public enum Insight: Sendable, Equatable, Identifiable {
    case milestone(count: Int, reachedOn: Date)
    case streak(days: Int)
    /// Listening time compared with the same point in the previous period.
    case listeningTrend(percent: Int, range: StatsRange)
    case onRepeat(title: String, artistName: String, count: Int, day: Date)
    case topArtistShare(name: String, percent: Int, count: Int)
    /// `percent` is out of the plays whose genre is known.
    case topGenre(name: String, percent: Int)
    /// `decade` is its first year, 1990 for the 1990s. `percent` is out of plays with a
    /// known release year.
    case favouriteDecade(decade: Int, percent: Int)
    case newArtists(count: Int)
    case allNew(count: Int)
    case mostlyNew(percent: Int)
    case persona(ListeningPersona, percent: Int)
    case busiestHour(hour: Int, count: Int)
    case weekendListener(percent: Int)
    case busiestDay(weekday: Int, count: Int)
    /// `total` is radio songs with a known station.
    case dominantStation(name: String, count: Int, total: Int)
    case repeatedSong(title: String, artistName: String, count: Int)
    case longestSession(minutes: Int)
    case playedBack(count: Int, total: Int)

    /// Whether it still reads true for a period that has ended. A streak is about today, and
    /// a trend compares with "this time last month".
    public var isAboutEndedPeriod: Bool {
        switch self {
        case .streak, .listeningTrend: false
        default: true
        }
    }

    public var id: String {
        switch self {
        case .milestone: "milestone"
        case .streak: "streak"
        case .listeningTrend: "listeningTrend"
        case .onRepeat: "onRepeat"
        case .topArtistShare: "topArtistShare"
        case .topGenre: "topGenre"
        case .favouriteDecade: "favouriteDecade"
        case .newArtists: "newArtists"
        case .allNew: "allNew"
        case .mostlyNew: "mostlyNew"
        case .persona: "persona"
        case .busiestHour: "busiestHour"
        case .weekendListener: "weekendListener"
        case .busiestDay: "busiestDay"
        case .dominantStation: "dominantStation"
        case .repeatedSong: "repeatedSong"
        case .longestSession: "longestSession"
        case .playedBack: "playedBack"
        }
    }

    public var symbol: String {
        switch self {
        case .milestone: "trophy.fill"
        case .streak: "flame.fill"
        case .listeningTrend(let percent, _): percent >= 0 ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis"
        case .onRepeat: "repeat"
        case .topArtistShare: "music.microphone"
        case .topGenre: "guitars.fill"
        case .favouriteDecade: "calendar.badge.clock"
        case .newArtists: "person.2.badge.plus"
        case .allNew, .mostlyNew: "sparkles"
        case .persona(let persona, _): persona == .nightOwl ? "moon.stars.fill" : "sunrise.fill"
        case .busiestHour: "clock.fill"
        case .weekendListener: "sun.max.fill"
        case .busiestDay: "calendar"
        case .dominantStation: "dot.radiowaves.left.and.right"
        case .repeatedSong: "arrow.trianglehead.2.clockwise"
        case .longestSession: "hourglass"
        case .playedBack: "play.circle.fill"
        }
    }

    public var category: Category {
        switch self {
        case .milestone, .streak: .achievement
        case .listeningTrend: .trend
        case .onRepeat, .repeatedSong, .topArtistShare, .topGenre, .favouriteDecade: .favourites
        case .newArtists, .allNew, .mostlyNew: .discovery
        case .persona, .busiestHour, .weekendListener, .busiestDay: .rhythm
        case .dominantStation, .longestSession, .playedBack: .radio
        }
    }

    public enum Category: String, Sendable, CaseIterable {
        case achievement, trend, favourites, discovery, rhythm, radio
    }
}
