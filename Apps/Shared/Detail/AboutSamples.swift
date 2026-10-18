#if DEBUG
import Foundation
import MusicKit

/// Invented Apple Music items for screenshots of the About sections with sample data, which
/// can't reach the catalog: an artist with a biography, and a song with its credits, how it's
/// mastered and its album's label. `-TracksSampleArtist YES` beside `-TracksSampleAlbum YES` opens the artist
/// from the sample album. Debug builds only.
enum AboutSamples {
    static let artistID = MusicItemID("700")

    static var opensArtist: Bool { UserDefaults.standard.bool(forKey: "TracksSampleArtist") }

    static func isSample(_ artist: Artist) -> Bool { artist.id == artistID }

    static func artist() -> Artist {
        let albums = ["Coastlines", "Night Ferry", "Paper Harbour"].enumerated().map { index, title in
            #"{"id":"71\#(index)","type":"albums","attributes":{"name":"\#(title)","artistName":"Juniper Lane","releaseDate":"\#(2024 - index * 2)-05-17","trackCount":10}}"#
        }.joined(separator: ",")
        let json = #"""
        {"id":"\#(artistID.rawValue)","type":"artists","attributes":{"name":"Juniper Lane","genreNames":["Alternative","Music"],"url":"https://music.apple.com/artist/700","editorialNotes":{"short":"Hushed, coastal indie pop about leaving and coming back.","standard":"Juniper Lane make songs that sound like the drive home after a long day by the sea: close harmonies, a warm upright piano and drums played with brushes. The duo met singing in a harbour-town choir and started writing together on the night ferry between the islands where they grew up.\n\nTheir debut, Night Ferry, found its audience slowly, one late-night playlist at a time. Coastlines, recorded in a converted boathouse over one winter, keeps the hush but lets the songs open up, with strings arranged by the pair themselves."}},"relationships":{"albums":{"data":[\#(albums)]}}}
        """#
        // The previews can't run without it, and the JSON above is fixed.
        return try! JSONDecoder().decode(Artist.self, from: Data(json.utf8))
    }

    static func song(title: String, artist: String, album: String?) -> Song? {
        let payload: [String: Any] = [
            "id": "9001",
            "type": "songs",
            "attributes": [
                "name": title,
                "artistName": artist,
                "albumName": album ?? "",
                "durationInMillis": 222_000,
                "genreNames": ["Alternative", "Music"],
                "releaseDate": "2024-05-17",
                "composerName": "Ada Kestrel & Juniper Lane",
                "audioTraits": ["lossless", "atmos"],
                "isrc": "GBSMP2400117",
                "hasLyrics": true,
                "url": "https://music.apple.com/song/9001",
            ],
            "relationships": [
                "albums": [
                    "data": [[
                        "id": "9002",
                        "type": "albums",
                        "attributes": [
                            "name": album ?? title,
                            "artistName": artist,
                            "releaseDate": "2024-05-17",
                            "trackCount": 10,
                            "recordLabel": "Harbour Light Records",
                            "copyright": "℗ 2024 Harbour Light Records",
                        ],
                    ]],
                ],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return try? JSONDecoder().decode(Song.self, from: data)
    }
}
#endif
