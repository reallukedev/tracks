import SwiftUI

/// Where Search looks: Apple Music's catalog, the Apple Music library, or Tracks’ history.
enum SearchScope: String, CaseIterable, Identifiable {
    case appleMusic, library, history

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .appleMusic: "Apple Music"
        case .library: "Your Library"
        case .history: "History"
        }
    }

    var prompt: Text {
        switch self {
        case .appleMusic: Text("Artists, Songs, Stations and More")
        case .library: Text("Your Library")
        case .history: Text("Songs, Artists, Dates and More")
        }
    }

    /// The title where the library is your own music rather than Apple Music's.
    func title(for source: MusicSource) -> LocalizedStringKey {
        self == .library && source == .yourMusic ? "Your Music" : title
    }

    func prompt(for source: MusicSource) -> Text {
        self == .library && source == .yourMusic ? Text("Songs, Albums and Artists") : prompt
    }

    /// Where the scope's recent searches are kept. Apple Music's catalog and library share
    /// theirs, as they did before scopes were one page.
    func recentsKey(for source: MusicSource) -> String {
        switch self {
        case .appleMusic: "recentMusicSearches"
        case .library: source == .yourMusic ? "recentYourMusicSearches" : "recentMusicSearches"
        case .history: "recentHistorySearches"
        }
    }

    /// The scopes Play offers: Apple Music's catalog isn't one when your own music is what
    /// plays.
    static func scopes(for source: MusicSource) -> [SearchScope] {
        source == .yourMusic ? [.library, .history] : allCases
    }
}
