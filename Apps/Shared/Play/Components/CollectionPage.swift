import SwiftUI
import TracksCore

#if os(iOS)
extension View {
    /// A collection's page on iPhone: a plain list whose first row is the header's field. While
    /// the field is under the navigation bar the bar is drawn for a dark field, and the title
    /// joins the bar once the header's own title has scrolled under it, as Music's does.
    func collectionPage(title: String) -> some View {
        modifier(CollectionChrome(title: title))
    }
}

private struct CollectionChrome: ViewModifier {
    let title: String
    /// How far the header has gone under the bar: 0 still showing its title, 1 its title
    /// gone, 2 the field gone.
    @State private var phase = 0
    @ScaledMetric(relativeTo: .title2) private var titleDepth: CGFloat = 300

    func body(content: Content) -> some View {
        content
            .listStyle(.plain)
            .onScrollGeometryChange(for: Int.self) { geometry in
                let scrolled = geometry.contentOffset.y + geometry.contentInsets.top
                if scrolled > titleDepth + 150 { return 2 }
                return scrolled > titleDepth ? 1 : 0
            } action: { _, phase in
                self.phase = phase
            }
            .navigationTitle(phase > 0 ? title : "")
            .toolbarTitleDisplayMode(.inline)
            .toolbarColorScheme(phase < 2 ? .dark : nil, for: .navigationBar)
    }
}
#endif

#if DEBUG
/// Sample playlists for screenshots, with sample data only. `-TracksDemoPlaylists YES` makes
/// them; `list` opens them all, and a number one of them: 1 a long one, 2 a short one, 3 an
/// empty one with a long name, 4 a smart one. `-TracksCollectionSheet add` then opens Add Songs on it, and
/// `pick` the sheet that adds songs to a playlist. Debug builds only.
enum CollectionDemo {
    @MainActor
    static func seedPlaylists(music: YourMusic, isDemo: Bool, open: OpenPlayRouteAction) {
        guard isDemo, let value = UserDefaults.standard.string(forKey: "TracksDemoPlaylists"),
              music.playlists.all.isEmpty, !music.index.tracks.isEmpty
        else { return }
        let tracks = music.index.tracks
        let made = [
            music.playlists.create(name: "Late Night Drives", tracks: Array(tracks.prefix(18))),
            music.playlists.create(name: "Sunday Morning", tracks: Array(tracks.dropFirst(18).prefix(3))),
            music.playlists.create(name: "Everything I Meant to Say on the Drive Home, the Long Way"),
            music.playlists.create(
                name: "Juniper Lane, Most Played",
                rules: SmartRules(source: .yourMusic, conditions: [SmartRules.Condition(field: .artist, text: "Juniper Lane")], order: .mostPlayed)
            ),
        ]
        if value == "list" {
            open(.yourMusic(.playlists))
        } else if let number = Int(value), made.indices.contains(number - 1) {
            open(.tracksPlaylist(made[number - 1].id))
        }
    }

    static var sheet: String? { UserDefaults.standard.string(forKey: "TracksCollectionSheet") }
}
#endif
