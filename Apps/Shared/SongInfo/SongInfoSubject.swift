import SwiftUI
import MusicKit
import TracksCore

/// The song Get Info is about, as much as the place it was opened from knows: always its
/// name, and its Apple Music song or your own file where there is one.
struct SongInfoSubject: Hashable, Identifiable {
    /// The key the history groups plays by.
    let identity: String
    let title: String
    let artistName: String
    let albumTitle: String?
    let cover: CoverArt
    /// Apple Music's id for it, where it's known.
    var catalogID: String?
    var song: Song?
    var local: LocalTrack?

    var id: String { identity }

    init(title: String, artistName: String, albumTitle: String? = nil, cover: CoverArt? = nil, catalogID: String? = nil) {
        identity = HistoryImport.key(title: title, artistName: artistName)
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle.flatMap { $0.isEmpty ? nil : $0 }
        self.cover = cover ?? .url(nil, seed: albumTitle ?? title)
        self.catalogID = catalogID.flatMap { !$0.isEmpty && $0.allSatisfy(\.isNumber) ? $0 : nil }
    }

    init(_ song: Song) {
        self.init(
            title: song.title,
            artistName: song.artistName,
            albumTitle: song.albumTitle,
            cover: song.artwork.map(CoverArt.artwork),
            catalogID: song.id.rawValue
        )
        self.song = song
    }

    init(_ track: PlayerTrack) {
        self.init(title: track.title, artistName: track.artistName, albumTitle: track.albumTitle, cover: track.cover, catalogID: track.song?.id.rawValue)
        song = track.song
        local = track.local
    }

    init(_ song: MixSong) {
        self.init(
            title: song.title,
            artistName: song.artistName,
            albumTitle: song.albumTitle,
            cover: .url(song.artworkURL, seed: song.albumTitle ?? song.title),
            catalogID: song.songID
        )
    }

    init(_ track: LocalTrack) {
        self.init(title: track.title, artistName: track.artist, albumTitle: track.album)
        local = track
    }

    init(_ link: RecordingLink) {
        self.init(title: link.title, artistName: link.artistName)
    }

    init(_ similar: LastFMTrackInfo.SimilarTrack) {
        self.init(title: similar.title, artistName: similar.artistName)
    }
}

/// Opens Get Info: the Mac's Song Info window, the iPhone's sheet. Nil where neither can
/// show, and menus leave Get Info out there.
struct ShowSongInfoAction {
    let show: @MainActor (SongInfoSubject) -> Void

    @MainActor
    func callAsFunction(_ subject: SongInfoSubject) {
        show(subject)
    }
}

extension EnvironmentValues {
    @Entry var showSongInfo: ShowSongInfoAction?
}

/// Which song Get Info shows. One for the app, so every menu, the menu bar and the player
/// open the same window or sheet.
@MainActor
@Observable
final class SongInfoPresenter {
    /// The song shown, or nil while the iPhone's sheet is closed.
    var subject: SongInfoSubject? {
        didSet { if let subject { lastShown = subject } }
    }
    /// Kept while the sheet slides away, so it doesn't go blank on the way down.
    private(set) var lastShown: SongInfoSubject?
    /// Bumped by every request, so asking again for the song already shown still brings the
    /// page back to it from a sample or a similar song it was following.
    private(set) var request = 0

    func show(_ subject: SongInfoSubject) {
        self.subject = subject
        request += 1
    }
}
