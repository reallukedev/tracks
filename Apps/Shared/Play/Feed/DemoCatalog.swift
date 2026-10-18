#if DEBUG
import Foundation
import MusicKit
import TracksCore

/// Invented Apple Music songs, artists and albums, made from API JSON, for the pages that
/// need catalog items when Tracks runs on sample data. Every name here is made up.
enum DemoCatalog {
    private static let artistNames = [
        "Paper Lanterns", "Cold Harbour", "June Arcade", "The Quiet Hours", "Luma Vale",
        "Static Bloom", "Ocean Tapes", "Violet Radio", "Honey Circuit", "North Atlas",
        "Glass Animals Club", "Satellite Hearts", "Wren & Wolf", "Palomar", "Lowland Choir",
        "Coral Fever", "Midnight Orchard", "Silver Lakes", "Neon Pines", "Tidewater",
    ]

    private static let titleWords = [
        "Golden", "Hour", "Paper", "Moon", "Slow", "Motion", "Neon", "Rain", "Summer", "Ghost",
        "Satellite", "Heart", "Velvet", "Sky", "Late", "Bloom", "Echo", "Parade", "Wild", "Fire",
    ]

    private static let genres = ["Indie Pop", "Alternative", "R&B/Soul", "Electronic", "Singer/Songwriter", "Hip-Hop/Rap"]

    static func songs(count: Int, offset: Int, artists: [String]?) -> [Song] {
        (offset..<offset + count).compactMap { index in
            let artist = artists.map { $0[index % $0.count] } ?? artistNames[index % artistNames.count]
            let title = "\(titleWords[index % titleWords.count]) \(titleWords[(index * 7 + 3) % titleWords.count])"
            let json = #"""
            {"id":"demo-song-\#(index)","type":"songs","attributes":{"name":"\#(title)","artistName":"\#(escaped(artist))","albumName":"\#(title)","durationInMillis":\#(170_000 + index % 9 * 11_000),"genreNames":["\#(genres[index % genres.count])","Music"],"releaseDate":"2025-0\#(index % 9 + 1)-12"}}
            """#
            return try? JSONDecoder().decode(Song.self, from: Data(json.utf8))
        }
    }

    static func artists(count: Int, offset: Int) -> [Artist] {
        (offset..<offset + count).compactMap { index in
            let name = artistNames[index % artistNames.count] + (index >= artistNames.count ? " \(index / artistNames.count + 1)" : "")
            let json = #"""
            {"id":"demo-artist-\#(index)","type":"artists","attributes":{"name":"\#(escaped(name))","genreNames":["\#(genres[index % genres.count])"]}}
            """#
            return try? JSONDecoder().decode(Artist.self, from: Data(json.utf8))
        }
    }

    /// Releases by the sample history's own artists: two not out yet, the rest out lately.
    static func releases(by artists: [String]) -> [Discovery.Release] {
        guard !artists.isEmpty else { return [] }
        let days = [12, 4, -1, -3, -9, -16, -24, -40, -65, -90, -130]
        let tracks = [11, 1, 5, 1, 12, 2, 1, 9, 4, 1, 13]
        return days.indices.compactMap { index in
            let date = Calendar.current.date(byAdding: .day, value: days[index], to: .now)!
            let day = date.formatted(.iso8601.year().month().day())
            let title = "\(titleWords[(index * 3) % titleWords.count]) \(titleWords[(index * 5 + 1) % titleWords.count])"
            let json = #"""
            {"id":"demo-album-\#(index)","type":"albums","attributes":{"name":"\#(title)","artistName":"\#(escaped(artists[index % artists.count]))","genreNames":["\#(genres[index % genres.count])","Music"],"releaseDate":"\#(day)","trackCount":\#(tracks[index]),"isSingle":\#(tracks[index] == 1)}}
            """#
            return (try? JSONDecoder().decode(Album.self, from: Data(json.utf8))).map(Discovery.Release.init)
        }
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "\\\"")
    }
}
#endif
