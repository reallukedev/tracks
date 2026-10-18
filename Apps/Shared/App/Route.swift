import SwiftUI
import TracksCore

/// Places a navigation stack can push.
nonisolated enum Route: Hashable, Sendable {
    case artist(String)
    case song(String)
    /// A `CaptureStat.albumIdentity`.
    case album(String)
    /// A range, and how many periods back from the current one.
    case highlights(StatsRange, periodOffset: Int)
}

/// Which ranked list the Charts tab, and the Mac's Top Charts sidebar items, are showing.
///
/// Not a ``Route``: the full lists have a home of their own on both platforms, so Summary's
/// "See All" goes there rather than pushing a second copy inside Summary.
nonisolated enum ChartKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case songs, artists, albums

    var id: String { rawValue }

    /// Where the chosen chart is remembered. `ChartsScreen` reads it with `@AppStorage`, so
    /// writing it here moves the tab to that chart.
    static let storageKey = "chartKind"

    /// Makes the Charts tab show this chart.
    func select() {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
    }

    var title: LocalizedStringKey {
        switch self {
        case .songs: "Songs"
        case .artists: "Artists"
        case .albums: "Albums"
        }
    }

    var navigationTitle: LocalizedStringKey {
        switch self {
        case .songs: "Top Songs"
        case .artists: "Top Artists"
        case .albums: "Top Albums"
        }
    }
}

extension View {
    /// The destinations every stack in the app understands.
    func tracksDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            Group {
                switch route {
                case .artist(let id): ArtistDetailView(artistID: id)
                case .song(let id): SongDetailView(songID: id)
                case .album(let id): AlbumDetailView(albumID: id)
                case .highlights(let range, let offset): HighlightsList(range: range, periodOffset: offset)
                }
            }
            .pageChrome()
        }
    }
}
