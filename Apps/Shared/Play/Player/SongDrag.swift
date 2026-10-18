import SwiftUI
import MusicKit
import UniformTypeIdentifiers
import TracksCore

/// Songs being dragged: from a list or a table onto Up Next, the player, or a playlist.
///
/// Each song carries every way Tracks has of finding it again, because where it came from
/// decides how it plays: a song of your own by its id in your music, an Apple Music library
/// song by its library id, anything else by its catalog id and name, as the history knows it.
nonisolated struct SongDrag: Codable, Hashable, Sendable, Transferable {
    struct Song: Codable, Hashable, Sendable {
        var songID: String = ""
        let title: String
        let artistName: String
        var albumTitle: String?
        /// An Apple Music library id, "i." and the like.
        var libraryID: String?
        /// ``TracksCore/LocalTrack/id``, for a song in your own music.
        var localID: String?
    }

    let songs: [Song]

    init(songs: [Song]) {
        self.songs = songs
    }

    init(_ songs: [HistorySong]) {
        self.songs = songs.map { Song(songID: $0.songID, title: $0.title, artistName: $0.artistName, albumTitle: $0.albumTitle) }
    }

    init(_ tracks: [LocalTrack]) {
        self.songs = tracks.map { Song(title: $0.title, artistName: $0.artist, albumTitle: $0.album, localID: $0.id) }
    }

    /// "Wildflowers" for one song, "3 Songs" for more, for where it lands.
    var title: String {
        if songs.count == 1, let song = songs.first { return song.title }
        return String(AttributedString(localized: "^[\(songs.count) Song](inflect: true)").characters)
    }

    /// The file of a song of yours on this device, for a drag onto Finder or another app.
    /// One file a drag, so only for one song.
    var fileURL: URL? {
        guard songs.count == 1, let id = songs.first?.localID, id.hasPrefix("file:") else { return nil }
        return LibraryFolders.music.appending(path: String(id.dropFirst("file:".count)))
    }

    /// The song on Apple Music, for a drag into Messages, Mail or a browser.
    var catalogURL: URL? {
        guard songs.count == 1, let id = songs.first?.songID, !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
        return URL(string: "https://music.apple.com/song/\(id)")
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .tracksSongs)
        // A copy, so a drag to Finder never moves the file out of your music.
        FileRepresentation(exportedContentType: .audio) { drag in
            guard let url = drag.fileURL else { throw CocoaError(.fileNoSuchFile) }
            return SentTransferredFile(url, allowAccessingOriginalFile: false)
        }
        .exportingCondition { $0.fileURL != nil }
        ProxyRepresentation { drag in
            guard let url = drag.catalogURL else { throw CocoaError(.fileNoSuchFile) }
            return url
        }
        .exportingCondition { $0.catalogURL != nil }
        // Anywhere else, the songs as text, a line each.
        ProxyRepresentation { drag in
            drag.songs.map { "\($0.title), \($0.artistName)" }.joined(separator: "\n")
        }
    }
}

extension SongDrag {
    /// What to hand the player for these songs: your own when every one is, Apple Music's
    /// library songs when they came from there, and the history's way otherwise.
    @MainActor
    func request(in music: YourMusic) async -> PlayRequest? {
        let local = songs.compactMap { $0.localID.flatMap(music.index.track(id:)) }
        if !local.isEmpty, local.count == songs.count {
            return .local(local)
        }
        let libraryIDs = songs.compactMap(\.libraryID).map { MusicItemID($0) }
        if !libraryIDs.isEmpty {
            var request = MusicLibraryRequest<MusicKit.Song>()
            request.filter(matching: \.id, memberOf: libraryIDs)
            guard let found = try? await request.response().items, !found.isEmpty else { return nil }
            // In the order they were dragged.
            let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return .songs(libraryIDs.compactMap { byID[$0] })
        }
        return .history(songs.map { HistorySong(songID: $0.songID, title: $0.title, artistName: $0.artistName, albumTitle: $0.albumTitle) })
    }
}

extension UTType {
    /// Songs dragged within Tracks. Declared in both apps' Info.plist.
    nonisolated static let tracksSongs = UTType(exportedAs: "com.luke.tracks.songs")
}
