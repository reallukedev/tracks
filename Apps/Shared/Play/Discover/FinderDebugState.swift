#if DEBUG
import Foundation
import MusicKit

/// States of the Song and Artist Finders that sample data doesn't reach on its own, for
/// screenshots: `-TracksFinderState noAccess`, `loading`, `empty`, or `long` (songs and an
/// artist with names past 40 characters, first). Debug builds only.
enum FinderDebugState: String {
    case noAccess, loading, empty, long

    static var current: FinderDebugState? {
        UserDefaults.standard.string(forKey: "TracksFinderState").flatMap(FinderDebugState.init)
    }

    static let longSuggestions: [Suggestion] = [
        song(1, title: "The Longest Night of the Year (Live from the Harbour Hall)", artist: "Wren & Ivy"),
        song(2, title: "Everything You Said on the Way Home That Evening", artist: "The Midnight Orchard Collective Ensemble"),
    ].compactMap { $0 }.map { Suggestion(song: $0, reason: .like("Juniper Lane and the Northern Lights Orchestra")) }

    static let longArtist: SuggestedArtist? = {
        let json = #"{"id":"finder-long-artist","type":"artists","attributes":{"name":"The Midnight Orchard Collective Ensemble","genreNames":["Singer/Songwriter"]}}"#
        return (try? JSONDecoder().decode(Artist.self, from: Data(json.utf8))).map {
            SuggestedArtist(artist: $0, because: ["Juniper Lane and the Northern Lights Orchestra", "Mara Solis"])
        }
    }()

    private static func song(_ index: Int, title: String, artist: String) -> Song? {
        let json = #"{"id":"finder-long-\#(index)","type":"songs","attributes":{"name":"\#(title)","artistName":"\#(artist)","albumName":"\#(title)","durationInMillis":241000,"genreNames":["Indie Pop"]}}"#
        return try? JSONDecoder().decode(Song.self, from: Data(json.utf8))
    }
}
#endif
