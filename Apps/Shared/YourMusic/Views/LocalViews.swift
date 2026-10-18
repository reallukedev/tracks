import SwiftUI
import TracksCore

/// The lists of everything in your music, each a page of its own.
enum YourMusicList: String, Hashable, CaseIterable, Identifiable {
    case playlists, songs, albums, artists, downloads, recentlyAdded

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .playlists: "Playlists"
        case .songs: "Songs"
        case .albums: "Albums"
        case .artists: "Artists"
        case .downloads: "Downloads"
        case .recentlyAdded: "Recently Added"
        }
    }

    var symbol: String {
        switch self {
        case .playlists: "music.note.list"
        case .songs: "music.note"
        case .albums: "square.stack"
        case .artists: "music.microphone"
        case .downloads: "arrow.down.circle"
        case .recentlyAdded: "clock"
        }
    }

    @MainActor @ViewBuilder
    var page: some View {
        switch self {
        case .playlists: PlaylistsPage()
        case .songs: LocalSongsPage()
        case .albums: LocalAlbumsPage()
        case .artists: LocalArtistsPage()
        case .downloads: DownloadsPage()
        case .recentlyAdded: LocalRecentlyAddedPage()
        }
    }
}

/// A cover from your music: a saved picture, the server's, or a generated one.
struct LocalCover: View {
    let artwork: LocalTrack.Artwork?
    let seed: String
    var size: CGFloat?
    var isCircle = false
    @Environment(YourMusic.self) private var music

    var body: some View {
        ArtworkView(
            url: music.artworkURL(artwork)?.absoluteString,
            seed: seed,
            size: size,
            isCircle: isCircle,
            maximumCornerRadius: CoverImage.maximumRadius
        )
    }
}

/// How a song is encoded, as Music marks Lossless: "Hi-Res Lossless", "Lossless", or the
/// codec and bit rate of anything else. The file's own format, for album and song pages; what
/// Now Playing is actually playing at is ``AudioQualityBadge``'s to say.
struct FormatBadge: View {
    let format: AudioFormat
    /// On Now Playing's coloured field rather than the page.
    var onDark = false
    var showsDetail = false

    var body: some View {
        QualityCapsule(label: label, showsWaveform: format.isLossless, onDark: onDark)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(spoken))
    }

    private var label: String {
        if format.isHiRes {
            return showsDetail ? "Hi-Res Lossless · \(format.detail ?? "")" : String(localized: "Hi-Res Lossless")
        }
        if format.isLossless {
            if showsDetail, let detail = format.detail { return "\(format.codec) · \(detail)" }
            return String(localized: "Lossless")
        }
        return [format.codec, format.detail].compactMap(\.self).joined(separator: " · ")
    }

    private var spoken: String {
        [label, format.isLossless ? format.detail : nil].compactMap(\.self).joined(separator: ", ")
    }
}

/// An album of yours on a shelf or in a grid.
struct LocalAlbumTile: View {
    let album: LocalAlbum
    /// What's under the title: its artist, unless given.
    var subtitle: String?
    var side: CGFloat?

    var body: some View {
        NavigationLink(value: PlayRoute.localAlbum(album.id)) {
            TileLabel(title: album.displayTitle, subtitle: subtitle ?? album.artist) { tileSide in
                LocalCover(artwork: album.artwork, seed: album.title, size: side ?? tileSide)
            }
            .frame(width: side)
        }
        .buttonStyle(.pressable)
        .contextMenu { LocalAlbumMenu(album: album) }
    }
}

/// A song of yours in a list, as Apple Music's songs are: ``TrackRow`` with its cover, from
/// your files or its server, and its download coming down.
struct LocalTrackRow: View {
    let track: LocalTrack
    var isCurrent = false

    @Environment(YourMusic.self) private var music

    var body: some View {
        let isPlayable = music.isPlayable(track)
        TrackRow(
            title: track.title,
            subtitle: track.artist,
            cover: .url(music.artworkURL(track.artwork)?.absoluteString, seed: track.album ?? track.title),
            isCurrent: isCurrent,
            localTrack: track,
            isPlayable: isPlayable
        )
        .accessibilityHint(isPlayable ? "" : String(localized: "Not downloaded, and its server can't be reached"))
    }
}

/// A server song's download, while it's under way: a ring turning while the song's being got
/// (by its server, for a song found for you, or queued to come down), then filling as it comes
/// down. Nothing once it's here: a downloaded song just plays. Follows the song into your music
/// once its server has kept it, so a row found before then shows the download too.
struct DownloadStateIcon: View {
    let track: LocalTrack
    @Environment(YourMusic.self) private var music

    var body: some View {
        let copy = music.resolved(track)
        Group {
            if !copy.isFromServer {
                EmptyView()
            } else if music.downloads.isWaitingForWiFi(copy.id, onCellular: music.network.isExpensive) {
                // Queued, and starts by itself back on Wi-Fi.
                Image(systemName: "wifi")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Waiting for Wi-Fi")
            } else if music.downloads.sizeUnknown.contains(copy.id) {
                // The server didn't say how big it is, so there's no telling how far along.
                TurningRing()
                    .accessibilityLabel("Downloading")
            } else if music.downloads.isDownloading(copy.id), let progress = music.downloads.progress[copy.id] {
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: max(0.04, progress))
                        .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 15, height: 15)
                .animation(.linear(duration: 0.2), value: progress)
                .accessibilityLabel("Downloading")
                .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
            } else if music.downloads.isDownloaded(copy.id) {
                EmptyView()
            } else if music.downloads.isDownloading(copy.id) || music.servers.isWaitingToKeep(copy) {
                TurningRing()
                    .accessibilityLabel(music.servers.isWaitingToKeep(copy) ? "Getting from Your Server" : "Waiting to Download")
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.6)))
        .animation(.snappy, value: stateKey(copy))
    }

    /// Changes between states animate; progress within one doesn't restart the transition.
    private func stateKey(_ track: LocalTrack) -> Int {
        if music.downloads.isWaitingForWiFi(track.id, onCellular: music.network.isExpensive) { return 4 }
        if music.downloads.isDownloading(track.id) { return 1 }
        if music.downloads.isDownloaded(track.id) { return 2 }
        if music.downloads.isDownloading(track.id) || music.servers.isWaitingToKeep(track) { return 3 }
        return 0
    }
}

/// Everything that can be done with one of your songs.
struct LocalTrackMenu: View {
    let track: LocalTrack
    /// Where Go to Album and Go to Artist go; the stack the menu is in, unless given.
    var onNavigate: ((PlayRoute) -> Void)?
    var showsStats = false
    /// Asks before deleting a file, where the page can ask.
    var onDelete: ((LocalTrack) -> Void)?
    /// What a menu adds of its own, as the playing song's does.
    var adjust: ((inout SongActions) -> Void)?

    @Environment(YourMusic.self) private var music
    @Environment(PlayerModel.self) private var player
    @Environment(\.openPlayRoute) private var openPlayRoute

    var body: some View {
        var actions = SongActions.local(track, music: music, player: player, go: go, showsStats: showsStats, onDelete: onDelete)
        let _ = adjust?(&actions)
        SongMenuItems(actions)
    }

    private func go(_ route: PlayRoute) {
        if let onNavigate { onNavigate(route) } else { openPlayRoute(route) }
    }
}

extension SongActions {
    /// One of your songs' actions.
    /// - Parameters:
    ///   - go: where Go to Album, Go to Artist and Your Stats lead.
    ///   - onDelete: asks before deleting the file, where the page can ask. Nil leaves it out.
    static func local(
        _ track: LocalTrack,
        music: YourMusic,
        player: PlayerModel,
        play: (() -> Void)? = nil,
        go: @escaping (PlayRoute) -> Void,
        showsStats: Bool = true,
        onDelete: ((LocalTrack) -> Void)? = nil
    ) -> SongActions {
        let isPlayable = music.isPlayable(track)
        var actions = SongActions(
            play: isPlayable ? play : nil,
            playlistTracks: [track],
            stats: showsStats ? { go(.stats(.song(track.identity))) } : nil,
            info: SongInfoSubject(track),
            suggestLess: showsStats ? track.identity : nil,
            block: track.artist
        )
        if isPlayable {
            actions.playNext = { player.enqueue(.local([track]), next: true, title: track.title) }
            actions.playLast = { player.enqueue(.local([track]), next: false, title: track.title) }
        }
        if track.isFromServer, !music.isInYourMusic(track) {
            // Found on a server that doesn't have it yet: ask it to keep the song, then it
            // joins your music like any other, to download and find on its album.
            actions.keep.append(.addToYourMusic(track, music: music, player: player))
            return actions
        }
        if music.isRadioOnly(track) {
            #if os(macOS)
            actions.keep.append(SongMenuButton(title: "Keep on This Mac", systemImage: "pin") { music.keep(HistorySong(track)) })
            #else
            actions.keep.append(SongMenuButton(title: "Keep on iPhone", systemImage: "pin") { music.keep(HistorySong(track)) })
            #endif
        }
        if track.isFromServer {
            if music.downloads.isDownloaded(track.id) {
                actions.keep.append(SongMenuButton(title: "Remove Download", systemImage: "trash") { music.downloads.remove([track.id]) })
            } else if music.downloads.isDownloading(track.id) {
                actions.keep.append(SongMenuButton(title: "Stop Downloading", systemImage: "xmark.circle") { music.downloads.cancel([track.id]) })
            } else {
                actions.keep.append(SongMenuButton(title: "Download", systemImage: "arrow.down.circle") { music.downloads.download([track]) })
            }
        }
        actions.goToAlbum = { go(.localAlbum(track.albumKey)) }
        actions.goToArtist = { go(.localArtist(track.artistKey)) }
        #if os(macOS)
        if let file = music.fileURL(of: track) {
            actions.reveal.append(SongMenuButton(title: "Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            })
        }
        #endif
        if let onDelete, !track.isFromServer {
            #if os(macOS)
            actions.trailing.append(SongMenuButton(title: "Delete from This Mac", systemImage: "trash", role: .destructive) { onDelete(track) })
            #else
            actions.trailing.append(SongMenuButton(title: "Delete from iPhone", systemImage: "trash", role: .destructive) { onDelete(track) })
            #endif
        }
        return actions
    }
}

extension SongMenuButton {
    /// Asks a song's server to keep it, for a song found on a server that doesn't have it yet;
    /// once asked, says it's waiting.
    static func addToYourMusic(_ track: LocalTrack, music: YourMusic, player: PlayerModel) -> SongMenuButton {
        if music.servers.isWaitingToKeep(track) {
            return SongMenuButton(title: "Waiting for Your Server", systemImage: "clock", isDisabled: true) {}
        }
        return SongMenuButton(title: "Add to Your Music", systemImage: "plus.circle") {
            Task { player.confirm(await music.keep(track)) }
        }
    }
}

extension YourMusic {
    /// The song's file on this device: one of your files, or a server's song downloaded.
    /// Nil for a song only on its server.
    func fileURL(of track: LocalTrack) -> URL? {
        switch track.origin {
        case .file(let path): LibraryFolders.music.appending(path: path)
        case .server: downloads.fileURL(for: track.id)
        }
    }
}

/// Add to Playlist, for songs of yours. On the Mac a submenu of your playlists, as Music's is,
/// with New Playlist… at its end; on iPhone it opens the sheet to choose one.
struct AddToPlaylistMenu: View {
    let tracks: [LocalTrack]
    @Environment(YourMusic.self) private var music
    @Environment(PlayerModel.self) private var player

    var body: some View {
        #if os(macOS)
        Menu("Add to Playlist", systemImage: "text.badge.plus") {
            ForEach(music.playlists.fillable) { playlist in
                Button(playlist.name) {
                    music.playlists.add(tracks, to: playlist.id)
                    player.confirm(String(localized: "Added to \u{201C}\(playlist.name)\u{201D}"))
                }
            }
            if !music.playlists.fillable.isEmpty {
                Divider()
            }
            Button("New Playlist…") {
                let pick = PlaylistPick(tracks: tracks)
                PlaylistPickerSheet.startsNew.insert(pick.id)
                music.playlists.picking = pick
            }
        }
        #else
        Button("Add to Playlist…", systemImage: "text.badge.plus") {
            music.playlists.picking = PlaylistPick(tracks: tracks)
        }
        #endif
    }
}

/// What can be done with an album of yours from a long press.
struct LocalAlbumMenu: View {
    let album: LocalAlbum
    /// Play and Shuffle, left out where the page has its own.
    var showsPlay = true
    @Environment(YourMusic.self) private var music
    @Environment(PlayerModel.self) private var player

    var body: some View {
        let playable = album.tracks.filter(music.isPlayable)
        if !playable.isEmpty {
            if showsPlay {
                Button("Play", systemImage: "play") { player.play(.local(playable), from: PlayContext(kind: .album, title: album.title)) }
                Button("Shuffle", systemImage: "shuffle") { player.play(.local(playable), from: PlayContext(kind: .album, title: album.title), shuffled: true) }
                Divider()
            }
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.enqueue(.local(playable), next: true, title: album.title) }
            Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") { player.enqueue(.local(playable), next: false, title: album.title) }
        }
        let server = album.tracks.filter(\.isFromServer)
        if !server.isEmpty {
            Divider()
            if server.allSatisfy({ music.downloads.isDownloaded($0.id) }) {
                Button("Remove Download", systemImage: "trash") { music.downloads.remove(Set(server.map(\.id))) }
            } else {
                Button("Download", systemImage: "arrow.down.circle") { music.downloads.download(server) }
            }
        }
        Divider()
        AddToPlaylistMenu(tracks: album.tracks)
    }
}

/// What can be done with an artist of yours from a long press: play or queue everything of
/// theirs, download it, and the artist menu's own.
struct LocalArtistMenu: View {
    let artist: LocalArtist
    @Environment(YourMusic.self) private var music
    @Environment(PlayerModel.self) private var player

    var body: some View {
        let playable = artist.tracks.filter(music.isPlayable)
        let context = PlayContext(kind: .artist, title: artist.name)
        if !playable.isEmpty {
            Button("Shuffle", systemImage: "shuffle") { player.play(.local(playable), from: context, shuffled: true) }
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.enqueue(.local(playable), next: true, title: artist.name) }
            Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") { player.enqueue(.local(playable), next: false, title: artist.name) }
        }
        let server = artist.tracks.filter(\.isFromServer)
        if !server.isEmpty {
            Divider()
            if server.allSatisfy({ music.downloads.isDownloaded($0.id) }) {
                Button("Remove Downloads", systemImage: "trash") { music.downloads.remove(Set(server.map(\.id))) }
            } else {
                Button("Download All", systemImage: "arrow.down.circle") { music.downloads.download(server) }
            }
        }
        Divider()
        LibraryArtistMenu(name: artist.name)
    }
}

/// "12 songs, 48 minutes · 1.2 GB".
enum LocalFormat {
    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }
}
