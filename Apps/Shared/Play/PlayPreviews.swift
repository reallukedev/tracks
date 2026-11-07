#if DEBUG
import SwiftUI
import MusicKit
import TracksCore

/// Apple Music items made from API JSON, so pages that need them can be previewed without an
/// account or a network. Every name here is invented.
enum PreviewMusic {
    static func album(trackCount: Int = 9, longTitle: Bool = false) -> Album {
        let tracks = (1...trackCount).map { number in
            let title = number == 3 ? "Everything I Meant to Say on the Drive Home, Pt. 2" : "Track Title \(number)"
            let explicit = number == 5 ? #","contentRating":"explicit""# : ""
            return #"""
            {"id":"90\#(number)","type":"songs","attributes":{"name":"\#(title)","artistName":"Juniper Lane","albumName":"Coastlines","durationInMillis":\#(180_000 + number * 7_000),"trackNumber":\#(number),"genreNames":["Alternative"],"url":"https://music.apple.com/song/90\#(number)"\#(explicit)}}
            """#
        }.joined(separator: ",")
        let name = longTitle ? "Coastlines (Deluxe Edition) [Remastered with Bonus Tracks]" : "Coastlines"
        let json = #"""
        {"id":"800","type":"albums","attributes":{"name":"\#(name)","artistName":"Juniper Lane","genreNames":["Alternative","Music"],"releaseDate":"2024-05-17","trackCount":\#(trackCount),"url":"https://music.apple.com/album/800"},"relationships":{"tracks":{"data":[\#(tracks)]}}}
        """#
        // The previews can't run without it, and the JSON above is fixed.
        return try! JSONDecoder().decode(Album.self, from: Data(json.utf8))
    }
}

@MainActor
private func previewEnvironment<Content: View>(_ content: Content) -> some View {
    let player = PlayerModel(engine: DemoPlayerEngine { [] }, isDemo: true)
    let feed = PlayFeed(isDemo: true)
    return content
        .environment(player)
        .environment(feed)
        .environment(Discovery(feed: feed, player: player, isDemo: true))
        .environment(YourMusic(isDemo: true))
        .environment(Lidarr(isDemo: true))
}

#Preview("Album") {
    NavigationStack {
        previewEnvironment(AlbumPage(album: PreviewMusic.album()))
    }
}

#Preview("Album, long title, AX3") {
    NavigationStack {
        previewEnvironment(AlbumPage(album: PreviewMusic.album(trackCount: 4, longTitle: true)))
    }
    .dynamicTypeSize(.accessibility3)
}

#Preview("Album, dark") {
    NavigationStack {
        previewEnvironment(AlbumPage(album: PreviewMusic.album()))
    }
    .preferredColorScheme(.dark)
}
#endif
