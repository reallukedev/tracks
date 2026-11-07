import SwiftUI
import MusicKit
import TracksCore

/// An Apple Music artist: their top songs, newest release, albums, singles, the albums they
/// appear on, artists like them and what Apple Music says about them, under their picture
/// and what Tracks knows of you and them.
struct ArtistPage: View {
    let artist: Artist
    @Environment(AppModel.self) private var model
    @Environment(PlayerModel.self) private var player
    @State private var loaded: Artist?
    @State private var loadFailed = false
    @AppStorage(PlayPreferences.allowsExplicitKey) private var allowsExplicit = true

    var body: some View {
        let artist = loaded ?? artist
        let topSongs = Array(PlayPreferences.versions(of: Array(artist.topSongs ?? []), allowsExplicit: allowsExplicit).prefix(20))
        let context = PlayContext(kind: .artist, title: artist.name)
        ArtistScaffold(
            name: artist.name,
            picture: artist.artwork.map(CoverArt.artwork),
            play: topSongs.isEmpty ? nil : { player.play(.songs(topSongs), from: context) },
            shuffle: topSongs.isEmpty ? nil : { player.play(.songs(topSongs), from: context, shuffled: true) },
            // Apple Music's stations don't play from your own music.
            station: model.musicSource == .appleMusic ? { player.playStation(from: artist) } : nil,
            // Once the page has loaded, so it arrives with the sections above it.
            about: loaded.flatMap(ArtistAbout.init)
        ) {
            AddToLidarrButton(artistName: artist.name)
            if let url = artist.url {
                ShareLink(item: url) { Label("Share Artist", systemImage: "square.and.arrow.up") }
            }
        } sections: {
            if loadFailed {
                ArtistPageMessage(
                    title: String(localized: "Couldn't Load This Artist"),
                    symbol: "wifi.exclamationmark",
                    message: String(localized: "Apple Music didn't answer. Check your connection, then try again.")
                ) {
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(.bordered)
                }
            } else if loaded == nil {
                ArtistLoadingSections()
            } else {
                if !topSongs.isEmpty {
                    songs(topSongs, artist: artist.name, context: context)
                }
                if let latest = artist.latestRelease {
                    ArtistLatestRelease(
                        title: latest.title,
                        cover: latest.artwork.map(CoverArt.artwork) ?? .url(nil, seed: latest.title),
                        released: latest.releaseDate,
                        detail: detail(of: latest),
                        route: .album(latest)
                    ) {
                        FeedItemMenu(item: FeedItem(album: latest))
                    }
                }
                let albums = PlayPreferences.versions(of: Array(artist.fullAlbums ?? artist.albums ?? []), allowsExplicit: allowsExplicit)
                if !albums.isEmpty {
                    Shelf(title: String(localized: "Albums"), items: albums) { album in
                        ArtistAlbumTile(album: album)
                    }
                }
                let singles = PlayPreferences.versions(of: Array(artist.singles ?? []), allowsExplicit: allowsExplicit)
                if !singles.isEmpty {
                    Shelf(title: String(localized: "Singles & EPs"), items: singles) { album in
                        ArtistAlbumTile(album: album)
                    }
                }
                let appearsOn = PlayPreferences.versions(of: Array(artist.appearsOnAlbums ?? []), allowsExplicit: allowsExplicit)
                if !appearsOn.isEmpty {
                    Shelf(title: String(localized: "Appears On"), items: appearsOn) { album in
                        ArtistAlbumTile(album: album)
                    }
                }
                if let similar = artist.similarArtists, !similar.isEmpty {
                    Shelf(title: String(localized: "Similar Artists"), items: Array(similar)) { other in
                        NavigationLink(value: PlayRoute.artist(other)) {
                            ArtistCircleTile(name: other.name, picture: other.artwork.map(CoverArt.artwork))
                        }
                        .buttonStyle(.pressable)
                        .contextMenu { LibraryArtistMenu(name: other.name, artist: other) }
                    }
                }
            }
        }
        .task(id: artist.id) {
            // Once per artist: coming back to the page keeps what loaded.
            guard loaded?.id != artist.id else { return }
            await load()
        }
    }

    private func songs(_ songs: [Song], artist: String, context: PlayContext) -> some View {
        let visible = Array(songs.prefix(ArtistSongsSection<EmptyView, EmptyView>.visibleRows))
        return ArtistSongsSection(title: String(localized: "Top Songs"), showsSeeAll: songs.count > visible.count) {
            ArtistSongListPage(title: String(localized: "Top Songs"), artist: artist) {
                ForEach(songs) { song in row(song, in: songs, context: context) }
            }
        } content: {
            ForEach(visible) { song in row(song, in: songs, context: context) }
        }
    }

    private func row(_ song: Song, in songs: [Song], context: PlayContext) -> some View {
        let identity = HistoryImport.key(title: song.title, artistName: song.artistName)
        return AvailabilityGate(title: song.title, artist: song.artistName, album: song.albumTitle) {
            player.play(.songs(songs, startingAt: songs.firstIndex(of: song) ?? 0), from: context)
        } label: {
            ArtistSongLabel(
                title: song.title,
                subtitle: song.albumTitle,
                cover: song.artwork.map(CoverArt.artwork) ?? .url(nil, seed: song.title),
                isExplicit: song.isExplicit,
                isCurrent: player.current?.songIdentity == identity
            )
        }
        .contextMenu {
            if model.musicSource == .yourMusic {
                YourMusicSongMenu(song: song)
            } else {
                SongMenu(song: song, showsArtist: false)
            }
        }
    }

    /// "Single · 3 songs", "Album · 12 songs".
    private func detail(of album: Album) -> String {
        let kind = album.isSingle == true ? String(localized: "Single") : String(localized: "Album")
        guard album.trackCount > 0 else { return kind }
        let songs = String(AttributedString(localized: "^[\(album.trackCount) song](inflect: true)").characters)
        return "\(kind) · \(songs)"
    }

    private func load() async {
        loadFailed = false
        #if DEBUG
        if player.isDemo, AboutSamples.isSample(artist) {
            loaded = artist
            return
        }
        #endif
        do {
            loaded = try await artist.with([.topSongs, .fullAlbums, .albums, .singles, .latestRelease, .appearsOnAlbums, .similarArtists])
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = loaded == nil
        }
    }
}

/// An Apple Music album on an artist's shelf: the feed's tile on iPhone, the library's hover
/// tile on the Mac.
struct ArtistAlbumTile: View {
    let album: Album
    @Environment(PlayerModel.self) private var player

    var body: some View {
        #if os(macOS)
        LibraryCoverTile(
            title: album.title,
            subtitle: album.releaseDate.map { $0.formatted(.dateTime.year()) },
            route: .album(album),
            play: { player.play(.album(album), from: PlayContext(kind: .album, title: album.title)) },
            side: LibraryCoverTile<EmptyView, EmptyView>.shelfSide
        ) { side in
            CoverImage(cover: album.artwork.map(CoverArt.artwork) ?? .url(nil, seed: album.title), size: side ?? LibraryCoverTile<EmptyView, EmptyView>.shelfSide)
        } menu: {
            FeedItemMenu(item: FeedItem(album: album))
        }
        #else
        FeedTile(item: FeedItem(album: album))
        #endif
    }
}
