import SwiftUI
import TracksCore

/// One server's shelves on Play: what's new on it, what it plays most, and albums at random.
/// What it picks for you is a section of its own, ``ServerForYouSection``.
struct ServerShelves: View {
    let server: SubsonicServer
    @Environment(YourMusic.self) private var music

    var body: some View {
        let shelves = music.discover.shelves[server.id]
        Group {
            if let shelves {
                if !shelves.newest.isEmpty {
                    Shelf(title: String(localized: "New on \(server.name)"), items: shelves.newest) { album in
                        ServerAlbumTile(album: album)
                    }
                }
                if !shelves.mostPlayed.isEmpty {
                    Shelf(title: String(localized: "Most Played on \(server.name)"), items: shelves.mostPlayed) { album in
                        ServerAlbumTile(album: album)
                    }
                }
                if !shelves.random.isEmpty {
                    Shelf(title: String(localized: "Something Different"), items: shelves.random) {
                        Button("Shuffle", systemImage: "shuffle") {
                            Task { await music.discover.shuffleRandom(for: server.id) }
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Show Other Albums")
                    } tile: { album in
                        ServerAlbumTile(album: album)
                    }
                }
            }
        }
        .task(id: server.id) {
            await music.discover.loadShelves(for: server.id)
        }
    }
}

/// An album on a server's shelf.
struct ServerAlbumTile: View {
    let album: ServerDiscovery.Album
    /// The cover's side, in a grid; a shelf's own otherwise.
    var side: CGFloat?

    var body: some View {
        NavigationLink(value: album.route) {
            TileLabel(title: album.title, subtitle: album.artist) { tileSide in
                LocalCover(artwork: album.artwork, seed: album.title, size: side ?? tileSide)
            }
            .frame(width: side)
        }
        .buttonStyle(.pressable)
    }
}

/// Keep Exploring for your servers: songs you've never played, for as long as you scroll.
struct ServerExploring: View {
    @Environment(YourMusic.self) private var music
    @Environment(PlayFeed.self) private var feed
    @Environment(PlayerModel.self) private var player
    /// Whether the end of the list is on screen: only then is more found, so your servers are
    /// only asked as far as you scroll.
    @State private var isEndInView = false

    var body: some View {
        let discover = music.discover
        let servers = music.servers.onlineServers
        // Songs you have and haven't played, woven with new ones by artists new to you that
        // aren't on the shelves above.
        let further = servers.flatMap { discover.forYou[$0.id]?.further ?? [] }
        let songs = ServerMix.blend(owned: discover.exploring, new: further)
        let goesOn = discover.canExploreMore || servers.contains { discover.forYou[$0.id]?.canGoOn == true }
        LazyVStack(alignment: .leading, spacing: 0) {
            Text("Keep Exploring")
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 8)

            ForEach(songs) { track in
                HStack(spacing: 4) {
                    Button {
                        player.play(.local(songs, startingAt: songs.firstIndex(of: track) ?? 0), from: .songs(String(localized: "Keep Exploring")))
                    } label: {
                        LocalTrackRow(track: track, isCurrent: player.current?.local?.id == track.id)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    AddFoundSongButton(track: track)
                }
                .contextMenu { LocalTrackMenu(track: track, showsStats: true) }
                Divider().padding(.leading, 60)
            }

            if goesOn {
                LoadingRows(count: 2)
                    .onScrollVisibilityChange(threshold: 0.1) { isEndInView = $0 }
                    .onDisappear { isEndInView = false }
            }
        }
        .padding(.horizontal, PlayMetrics.margin)
        .animation(.snappy, value: songs.count)
        // Again after each lot, while the end's still in view, as each server's budget allows.
        .task(id: "\(isEndInView).\(songs.count)") {
            guard isEndInView else { return }
            if SuggestionMode.current != .onlyYours {
                for server in servers { await discover.loadMore(for: server.id, shelf: .further) }
            }
            await discover.exploreMore(heard: { [player] in feed.facts[$0] != nil || player.signals.excludes($0) })
        }
    }
}
