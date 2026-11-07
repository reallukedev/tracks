import Foundation
import MusicKit
import TracksCore

/// An invented Apple Music library for screenshots of the library's pages, which sample data
/// otherwise can't reach: `-TracksDemoLibrary YES` beside `-TracksDemoData YES`. Its albums and
/// songs are the sample history's, so your plays show beside them, plus a few playlists and an
/// album with a long name that you've never played. Debug builds only; nothing in a release.
nonisolated enum LibraryDemo {
    static var isOn: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "TracksDemoLibrary")
        #else
        false
        #endif
    }

    /// When a sample item came into the library. MusicKit keeps library dates to itself, so
    /// items made from JSON have none of their own.
    static func added(_ id: MusicItemID) -> Date? {
        #if DEBUG
        isOn ? catalog.dates[id]?.added : nil
        #else
        nil
        #endif
    }

    static func played(_ id: MusicItemID) -> Date? {
        #if DEBUG
        isOn ? catalog.dates[id]?.played : nil
        #else
        nil
        #endif
    }
}

#if DEBUG
nonisolated extension LibraryDemo {
    /// The sample library's items of a kind, or nil when it's off or has none of that kind.
    static func items<Item>(_: Item.Type) -> [Item]? {
        guard isOn else { return nil }
        let catalog = catalog
        let found: [Any]? = switch Item.self {
        case is Album.Type: catalog.albums
        case is Artist.Type: catalog.artists
        case is Playlist.Type: catalog.playlists
        case is Song.Type: catalog.songs
        default: nil
        }
        return found?.compactMap { $0 as? Item }
    }

    private struct Dates: Sendable {
        let added: Date
        let played: Date?
    }

    private struct Catalog: Sendable {
        var albums: [Album] = []
        var artists: [Artist] = []
        var playlists: [Playlist] = []
        var songs: [Song] = []
        var dates: [MusicItemID: Dates] = [:]
    }

    private static let catalog = makeCatalog()

    private static let playlistNames = [
        "Kitchen Dancing", "Sunday Morning", "Deep Focus", "Late Nights", "Road Trip",
        "Songs for the Long Drive Home With the Windows Down", "Rainy Day", "Found on Tracks Radio",
        "Running", "Wedding Maybe",
    ]

    private static func makeCatalog() -> Catalog {
        let plays = DemoLibrary.plays().sorted { $0.capturedAt < $1.capturedAt }
        var catalog = Catalog()
        var albumOrder: [String] = []
        var albumPlays: [String: (title: String, artist: String, first: Date, last: Date)] = [:]
        var songOrder: [String] = []
        var songPlays: [String: (play: DemoLibrary.Play, first: Date, last: Date)] = [:]
        for play in plays {
            let albumKey = "\(play.albumTitle)\u{1F}\(play.artistName)"
            if let known = albumPlays[albumKey] {
                albumPlays[albumKey] = (known.title, known.artist, known.first, play.capturedAt)
            } else {
                albumOrder.append(albumKey)
                albumPlays[albumKey] = (play.albumTitle, play.artistName, play.capturedAt, play.capturedAt)
            }
            let songKey = HistoryImport.key(title: play.title, artistName: play.artistName)
            if let known = songPlays[songKey] {
                songPlays[songKey] = (known.play, known.first, play.capturedAt)
            } else {
                songOrder.append(songKey)
                songPlays[songKey] = (play, play.capturedAt, play.capturedAt)
            }
        }

        for (index, key) in albumOrder.enumerated() {
            guard let album = albumPlays[key] else { continue }
            let id = MusicItemID("l.demo-album-\(index)")
            let year = 2014 + index % 12
            catalog.albums += decode(Album.self, id: id, type: "albums", attributes: #""name":"\#(escaped(album.title))","artistName":"\#(escaped(album.artist))","releaseDate":"\#(year)-0\#(index % 9 + 1)-15","trackCount":\#(8 + index % 5)"#)
            catalog.dates[id] = Dates(added: album.first, played: album.last)
        }
        // One you've never played, with a name too long for any tile.
        let longID = MusicItemID("l.demo-album-long")
        catalog.albums += decode(Album.self, id: longID, type: "albums", attributes: #""name":"Everything I Meant to Say on the Drive Home (Deluxe Edition)","artistName":"Juniper Lane","releaseDate":"2025-05-17","trackCount":14"#)
        catalog.dates[longID] = Dates(added: .now.addingTimeInterval(-3_600), played: nil)

        let artistNames = Array(Set(albumPlays.values.map(\.artist))).sorted()
        for (index, name) in artistNames.enumerated() {
            catalog.artists += decode(Artist.self, id: MusicItemID("r.demo-artist-\(index)"), type: "artists", attributes: #""name":"\#(escaped(name))""#)
        }

        for (index, key) in songOrder.enumerated() {
            guard let song = songPlays[key] else { continue }
            let id = MusicItemID("i.demo-song-\(index)")
            let duration = 150_000 + (index * 7_919) % 140_000
            catalog.songs += decode(Song.self, id: id, type: "songs", attributes: #""name":"\#(escaped(song.play.title))","artistName":"\#(escaped(song.play.artistName))","albumName":"\#(escaped(song.play.albumTitle))","durationInMillis":\#(duration)"#)
            catalog.dates[id] = Dates(added: song.first, played: song.last)
        }

        for (index, name) in playlistNames.enumerated() {
            let id = MusicItemID("p.demo-playlist-\(index)")
            catalog.playlists += decode(Playlist.self, id: id, type: "playlists", attributes: #""name":"\#(escaped(name))""#)
            let added = Date.now.addingTimeInterval(-Double(index * 9 + 2) * 86_400)
            catalog.dates[id] = Dates(added: added, played: index % 3 == 2 ? nil : .now.addingTimeInterval(-Double(index * index + 1) * 43_200))
        }
        return catalog
    }

    private static func decode<Item: Decodable>(_: Item.Type, id: MusicItemID, type: String, attributes: String) -> [Item] {
        let json = #"{"id":"\#(id.rawValue)","type":"\#(type)","attributes":{\#(attributes)}}"#
        return (try? JSONDecoder().decode(Item.self, from: Data(json.utf8))).map { [$0] } ?? []
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
#endif
