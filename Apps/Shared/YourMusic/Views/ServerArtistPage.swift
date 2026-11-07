import SwiftUI
import TracksCore

/// An artist on one of your servers, looked up there: one found by searching that isn't in your
/// music, from the server's library or, on a server like Octo, found elsewhere. Their top songs
/// where the server knows them, their newest album, and every album, each a click from its page.
struct ServerArtistPage: View {
    let artist: ServerArtist
    @Environment(YourMusic.self) private var music
    @Environment(PlayFeed.self) private var feed
    @Environment(PlayerModel.self) private var player
    @State private var albums: [ServerDiscovery.Album]?
    /// The newest album's year, for the Latest Release card.
    @State private var latestYear: Int?
    @State private var songs: [LocalTrack] = []
    @State private var failed = false

    var body: some View {
        ArtistScaffold(
            name: artist.name,
            picture: music.artistPicture(for: artist),
            play: songs.isEmpty ? nil : { player.play(.local(songs), from: context) },
            shuffle: songs.isEmpty ? nil : { player.play(.local(songs), from: context, shuffled: true) }
        ) {
            AddToLidarrButton(artistName: artist.name)
        } sections: {
            if let albums {
                if !songs.isEmpty { topSongs }
                if albums.isEmpty, songs.isEmpty {
                    ArtistPageMessage(
                        title: String(localized: "Nothing to Show Yet"),
                        symbol: "square.stack",
                        message: String(localized: "\(serverName) doesn't have any of their albums or songs to show.")
                    ) { EmptyView() }
                } else if let latest = albums.first {
                    if albums.count > 1 {
                        ArtistLatestRelease(
                            title: latest.title,
                            cover: .url(music.artworkURL(latest.artwork)?.absoluteString, seed: latest.title),
                            detail: latestYear.map(String.init),
                            route: latest.route
                        ) { EmptyView() }
                    }
                    Shelf(title: String(localized: "Albums"), items: albums) { album in
                        ServerAlbumShelfTile(album: album)
                    }
                }
            } else if failed {
                ArtistPageMessage(
                    title: String(localized: "Couldn't Reach the Server"),
                    symbol: "wifi.exclamationmark",
                    message: String(localized: "\(serverName) didn't answer. Check that it's online, then try again.")
                ) {
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(.bordered)
                }
            } else {
                ArtistLoadingSections()
            }
        }
        .animation(PlayMotion.panel, value: albums?.count)
        .task { await load() }
    }

    private var topSongs: some View {
        let visible = Array(songs.prefix(ArtistSongsSection<EmptyView, EmptyView>.visibleRows))
        return ArtistSongsSection(title: String(localized: "Top Songs"), showsSeeAll: songs.count > visible.count) {
            ArtistSongListPage(title: String(localized: "Top Songs"), artist: artist.name) {
                ForEach(songs) { track in row(track) }
            }
        } content: {
            ForEach(visible) { track in row(track) }
        }
    }

    private func row(_ track: LocalTrack) -> some View {
        Button {
            player.play(.local(songs, startingAt: songs.firstIndex(of: track) ?? 0), from: context)
        } label: {
            ArtistSongLabel(
                title: track.title,
                subtitle: track.album,
                cover: .url(music.artworkURL(track.artwork)?.absoluteString, seed: track.album ?? track.title),
                plays: feed.facts[track.identity]?.plays,
                isCurrent: player.current?.local?.id == track.id,
                isPlayable: music.isPlayable(track)
            )
        }
        .buttonStyle(.plain)
        .contextMenu { LocalTrackMenu(track: track) }
    }

    private var context: PlayContext { PlayContext(kind: .artist, title: artist.name) }

    private var serverName: String {
        music.servers.servers.first { $0.id == artist.serverID }?.name ?? String(localized: "Your server")
    }

    /// Their albums from the server's page for them; one like Octo has none there for an artist
    /// it found elsewhere, so their albums come from searching it for the name instead. Their top
    /// songs where it knows them.
    private func load() async {
        failed = false
        guard let client = music.servers.client(for: artist.serverID) else {
            failed = true
            return
        }
        async let top = try? await client.topSongs(artist: artist.name, count: 20)
        var found = (try? await client.artist(id: artist.artistID).albums) ?? []
        if found.isEmpty {
            guard let result = try? await music.servers.lookups.run({ try await client.search(artist.name, artists: 0, albums: 30, songs: 0) }) else {
                failed = true
                return
            }
            let name = StatsCalculator.folded(artist.name)
            found = result.albums.filter { $0.artistId == artist.artistID || StatsCalculator.folded($0.artist ?? "") == name }
        }
        let tracks = (await top ?? []).map { song in
            music.index.track(id: LocalTrack.id(for: .server(serverID: artist.serverID, songID: song.id))) ?? song.track(on: artist.serverID)
        }
        music.remember(found: tracks)
        songs = tracks
        // Newest first, as an artist's page in Music has them.
        let newest = found.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        latestYear = newest.first?.year
        albums = newest.map { ServerDiscovery.Album($0, serverID: artist.serverID) }
    }
}

/// An album on a server, on an artist's shelf: the library's hover tile on the Mac.
private struct ServerAlbumShelfTile: View {
    let album: ServerDiscovery.Album

    var body: some View {
        #if os(macOS)
        LibraryCoverTile(title: album.title, subtitle: album.artist, route: album.route, side: LibraryCoverTile<EmptyView, EmptyView>.shelfSide) { side in
            LocalCover(artwork: album.artwork, seed: album.title, size: side)
        } menu: {
            EmptyView()
        }
        #else
        ServerAlbumTile(album: album)
        #endif
    }
}
