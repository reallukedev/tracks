import SwiftUI
import TracksCore

/// An album in your music, as Music lays out an album: its cover, its format, and its songs
/// with your plays. A server's album can be downloaded whole.
struct LocalAlbumPage: View {
    let albumID: String
    @Environment(YourMusic.self) private var music

    var body: some View {
        if let album = music.index.album(id: albumID) {
            LocalAlbumContent(album: album)
        } else {
            ContentUnavailableView("Album Not Found", systemImage: "square.stack", description: Text("It may have been removed from your music."))
        }
    }
}

/// An album on one of your servers, looked up there: from a server's own shelves, which can
/// hold albums the last sync didn't.
struct ServerAlbumPage: View {
    let serverID: String
    let albumID: String
    @Environment(YourMusic.self) private var music
    @State private var album: LocalAlbum?
    @State private var failed = false

    var body: some View {
        if let album {
            LocalAlbumContent(album: album)
        } else if failed {
            ContentUnavailableView {
                Label("Couldn't Reach the Server", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check that the server is running and this device is on its network.")
            } actions: {
                // Back to loading, which asks again.
                Button("Try Again") { failed = false }
            }
        } else {
            loading
                .task { await load() }
        }
    }

    /// The album's shape while the server answers: a field waiting for its cover, and rows.
    private var loading: some View {
        let header = CollectionHeader(kind: .album, title: "", tintCover: nil, isLoading: true, play: {}, shuffle: {}) {
            EmptyView()
        } cover: { _ in
            EmptyView()
        }
        #if os(iOS)
        return List {
            Section { header }
            LoadingRows(count: 8, showsCover: false)
                .listRowSeparator(.hidden)
        }
        .collectionPage(title: "")
        #else
        return CollectionMacLayout {
            header
        } content: {
            LoadingRows(count: 8, showsCover: false)
                .padding(.horizontal, PlayMetrics.margin)
                .padding(.top, 12)
        }
        #endif
    }

    private func load() async {
        failed = false
        guard let client = music.servers.client(for: serverID) else {
            failed = true
            return
        }
        do {
            let (found, songs) = try await client.album(id: albumID)
            let tracks = songs.map { music.index.track(id: LocalTrack.id(for: .server(serverID: serverID, songID: $0.id))) ?? $0.track(on: serverID) }
            album = LocalAlbum(
                id: tracks.first?.albumKey ?? albumID,
                title: found.name,
                artist: found.artist ?? tracks.first?.albumArtistName ?? "",
                tracks: tracks
            )
        } catch {
            failed = true
        }
    }
}

/// The album itself, wherever it came from: its cover on a field of its colour, its format,
/// your history with it, and its songs.
struct LocalAlbumContent: View {
    let album: LocalAlbum
    @Environment(AppModel.self) private var model
    @Environment(YourMusic.self) private var music
    @Environment(PlayerModel.self) private var player
    @Environment(PlayFeed.self) private var feed
    @Environment(\.openPlayRoute) private var openPlayRoute
    @State private var deleting: LocalTrack?

    var body: some View {
        let context = PlayContext(kind: .album, title: album.title)
        let playable = album.tracks.filter(music.isPlayable)
        #if os(iOS)
        List {
            Section {
                header(playable: playable, context: context)
            }

            // One section per disc, headed as Music heads them, when there's more than one.
            let discs = album.discs
            ForEach(discs, id: \.number) { disc in
                Section {
                    ForEach(disc.tracks.enumerated(), id: \.element.id) { position, track in
                        Button {
                            play(track, in: playable, context: context)
                        } label: {
                            TrackRow(
                                title: track.title,
                                subtitle: showsArtist(of: track) ? track.artist : nil,
                                number: track.trackNumber ?? position + 1,
                                isCurrent: player.current?.local?.id == track.id,
                                localTrack: track,
                                isPlayable: music.isPlayable(track)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!music.isPlayable(track))
                        .trackMenu { LocalTrackMenu(track: track, showsStats: true, onDelete: { deleting = $0 }) }
                        .collectionRowInsets(hasCover: false)
                    }
                } header: {
                    if discs.count > 1 {
                        Text("Disc \(disc.number)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                            .listRowInsets(EdgeInsets(top: 12, leading: PlayMetrics.margin, bottom: 4, trailing: PlayMetrics.margin))
                    }
                } footer: {
                    if disc.number == discs.last?.number {
                        CollectionFooter(lines: footerLines)
                    }
                }
            }
        }
        .collectionPage(title: album.displayTitle)
        #if DEBUG
        // Screenshots reach a playlist through an album of yours, which a launch can open.
        .task { CollectionDemo.seedPlaylists(music: music, isDemo: model.isDemoLaunch, open: openPlayRoute) }
        #endif
        .toolbar {
            if album.tracks.contains(where: \.isFromServer) {
                ToolbarItem(placement: .primaryAction) {
                    AlbumDownloadButton(tracks: album.tracks.filter(\.isFromServer))
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu("More", systemImage: "ellipsis") { moreItems }
            }
        }
        .confirmationDialog(deleteTitle, isPresented: isDeleting, titleVisibility: .visible) {
            deleteActions
        } message: {
            Text("The file is deleted from the Tracks Music folder. Your plays of it stay in your history.")
        }
        #else
        CollectionMacLayout {
            header(playable: playable, context: context)
        } content: {
            VStack(spacing: 0) {
                CollectionTable(
                    tracks: album.tracks.enumerated().map { position, track in
                        CollectionTrack(
                            id: track.id,
                            position: position + 1,
                            number: track.trackNumber ?? position + 1,
                            title: track.title,
                            artist: track.artist,
                            album: album.title,
                            plays: feed.facts[track.identity]?.plays ?? 0,
                            duration: track.duration ?? 0,
                            isCurrent: player.current?.local?.id == track.id,
                            isPlayable: music.isPlayable(track),
                            drag: SongDrag([track]).songs.first
                        )
                    },
                    style: .album,
                    play: { id in
                        if let track = album.tracks.first(where: { $0.id == id }) { play(track, in: playable, context: context) }
                    },
                    enqueue: { ids, next in
                        let chosen = ids.compactMap { id in playable.first { $0.id == id } }
                        guard !chosen.isEmpty else { return }
                        player.enqueue(.local(chosen), next: next, title: album.title)
                    }
                ) { row in
                    if let track = album.tracks.first(where: { $0.id == row.id }) {
                        LocalTrackMenu(track: track, showsStats: true, onDelete: { deleting = $0 })
                    }
                }
                if let whereFrom {
                    Text(whereFrom)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, PlayMetrics.margin)
                        .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle(album.title)
        #if DEBUG
        .task { CollectionDemo.seedPlaylists(music: music, isDemo: model.isDemoLaunch, open: openPlayRoute) }
        #endif
        .toolbar {
            if album.tracks.contains(where: \.isFromServer) {
                ToolbarItem(placement: .primaryAction) {
                    AlbumDownloadButton(tracks: album.tracks.filter(\.isFromServer))
                        .help("Download Album")
                }
            }
        }
        .confirmationDialog(deleteTitle, isPresented: isDeleting, titleVisibility: .visible) {
            deleteActions
        } message: {
            Text("The file is deleted from the Tracks Music folder. Your plays of it stay in your history.")
        }
        #endif
    }

    private func header(playable: [LocalTrack], context: PlayContext) -> some View {
        let cover = CoverArt.url(music.artworkURL(album.artwork)?.absoluteString, seed: album.title)
        #if os(iOS)
        let kindName: String? = album.kind == .album ? nil : album.kind.name
        #else
        let kindName: String? = nil
        #endif
        return CollectionHeader(
            kind: album.kind.collectionKind,
            title: album.displayTitle,
            subtitle: album.artist,
            onSubtitle: { openPlayRoute(.localArtist(StatsCalculator.folded(album.artist))) },
            facts: CollectionFacts.line([
                kindName,
                album.genre,
                album.year.map { Format.year($0) },
                CollectionFacts.length(count: album.tracks.count, seconds: album.duration),
            ]),
            format: album.format,
            tintCover: cover,
            canPlay: !playable.isEmpty,
            play: { player.play(.local(playable), from: context) },
            shuffle: { player.play(.local(playable), from: context, shuffled: true) }
        ) {
            moreItems
        } cover: { side in
            LocalCover(artwork: album.artwork, seed: album.title, size: side)
        }
    }

    @ViewBuilder
    private var moreItems: some View {
        // Play and Shuffle are the header's.
        LocalAlbumMenu(album: album, showsPlay: false)
        Divider()
        Button("Go to Artist", systemImage: "music.microphone") {
            openPlayRoute(.localArtist(StatsCalculator.folded(album.artist)))
        }
    }

    private func play(_ track: LocalTrack, in playable: [LocalTrack], context: PlayContext) {
        guard let start = playable.firstIndex(of: track) else { return }
        player.play(.local(playable, startingAt: start), from: context)
    }

    private func showsArtist(of track: LocalTrack) -> Bool {
        StatsCalculator.folded(track.artist) != StatsCalculator.folded(album.artist)
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private var deleteTitle: String {
        #if os(iOS)
        String(localized: "Delete \u{201C}\(deleting?.title ?? "")\u{201D} from This iPhone?")
        #else
        String(localized: "Delete \u{201C}\(deleting?.title ?? "")\u{201D} from This Mac?")
        #endif
    }

    @ViewBuilder
    private var deleteActions: some View {
        Button("Delete Song", role: .destructive) {
            if let deleting { music.deleteFile(deleting) }
        }
    }

    /// "12 songs, 48 minutes", and where they are.
    private var footerLines: [String] {
        [TrackListFooter.summary(count: album.tracks.count, seconds: album.duration), whereFrom].compactMap(\.self)
    }

    /// "On Octo" or "Downloaded from Octo", for an album on a server.
    private var whereFrom: String? {
        let server = album.tracks.filter(\.isFromServer)
        guard !server.isEmpty else { return nil }
        let name = server.first?.serverID.flatMap { music.servers.server($0)?.name } ?? String(localized: "your server")
        let downloaded = server.filter { music.downloads.isDownloaded($0.id) }.count
        return downloaded == server.count
            ? String(localized: "Downloaded from \(name)")
            : String(localized: "On \(name)")
    }
}

/// Download a whole album, see it coming down, or remove it again.
struct AlbumDownloadButton: View {
    let tracks: [LocalTrack]
    @Environment(YourMusic.self) private var music

    var body: some View {
        let downloads = music.downloads
        let done = tracks.filter { downloads.isDownloaded($0.id) }.count
        let active = tracks.compactMap { downloads.progress[$0.id] }
        if !active.isEmpty {
            Button {
                downloads.cancel(Set(tracks.map(\.id)))
            } label: {
                let fraction = (Double(done) + active.reduce(0, +)) / Double(max(1, tracks.count))
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: max(0.03, fraction))
                        .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "stop.fill").font(.system(size: 8)).foregroundStyle(.tint)
                }
                .frame(width: 22, height: 22)
                .animation(.linear(duration: 0.2), value: fraction)
            }
            .accessibilityLabel("Stop Downloading")
        } else if done == tracks.count {
            Menu {
                Button("Remove Download", systemImage: "trash", role: .destructive) {
                    downloads.remove(Set(tracks.map(\.id)))
                }
            } label: {
                Image(systemName: "arrow.down.circle.fill")
            }
            .accessibilityLabel("Downloaded")
        } else {
            Button("Download", systemImage: "arrow.down.circle") {
                downloads.download(tracks)
            }
        }
    }
}
