import SwiftUI
import MusicKit
import TracksCore

/// Play with Apple Music as the source: the whole page with a connection, and only what's
/// downloaded to this iPhone without one, or with Offline Mode on.
struct AppleMusicPlayScreen: View {
    @Environment(YourMusic.self) private var music
    @AppStorage(OfflineMode.storageKey) private var isOfflineModeOn = false

    var body: some View {
        if isOfflineModeOn || !music.network.isOnline {
            OfflineScreen()
        } else {
            PlayScreen()
        }
    }
}

/// Play offline: songs downloaded to this iPhone, the mixes they make, and every one of them.
/// Everything here plays without a connection, and is kept in the history like anything else.
struct OfflineScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerModel.self) private var player
    @Environment(PlayFeed.self) private var feed
    @Environment(DownloadedSongs.self) private var downloads
    @State private var showsSettings = LaunchScene.opensPlaySettings

    /// Mixes need this many of their songs downloaded to be worth a tile.
    private static let mixMinimum = 5

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                OfflineBanner()
                    .padding(.horizontal, PlayMetrics.margin)

                if !model.isShowingSampleData, model.musicAuthorization != .authorized {
                    PlayAccessCard()
                        .padding(.horizontal, PlayMetrics.margin)
                } else if downloads.songs.isEmpty {
                    if downloads.hasLoaded {
                        emptyState
                            .padding(.horizontal, PlayMetrics.margin)
                    } else {
                        LoadingRows(count: 6)
                            .padding(.horizontal, PlayMetrics.margin)
                    }
                } else {
                    content
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .navigationTitle("Play")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Settings", systemImage: "gearshape") { showsSettings = true }
            }
        }
        .sheet(isPresented: $showsSettings) {
            SettingsSheet()
        }
        .refreshable { await downloads.load() }
        .task(id: feed.hasBuilt) { await downloads.loadIfNeeded() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let songs = downloads.songs
        playButtons(songs)
            .padding(.horizontal, PlayMetrics.margin)

        let mixes = downloadedMixes
        if !mixes.isEmpty {
            Shelf(title: String(localized: "Made from Your Listening"), items: mixes) { mix in
                OfflineMixTile(mix: mix.mix, songs: mix.songs)
            }
        }

        let mostPlayed = self.mostPlayed
        if !mostPlayed.isEmpty {
            Shelf(title: String(localized: "Your Most Played"), items: mostPlayed) { song in
                OfflineSongTile(song: song, queue: mostPlayed, context: .songs(String(localized: "Your Most Played")))
            }
        }

        let recent = Array(songs.prefix(15))
        Shelf(title: String(localized: "Recently Added"), items: recent) { song in
            OfflineSongTile(song: song, queue: recent, context: .songs(String(localized: "Recently Added")))
        }

        allSongs
            .padding(.horizontal, PlayMetrics.margin)
    }

    private func playButtons(_ songs: [OfflineSong]) -> some View {
        let context = PlayContext.songs(String(localized: "Downloaded"))
        return HStack(spacing: 12) {
            Button {
                player.play(songs.sortedByTitle.request(), from: context)
            } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            Button {
                player.play(songs.request(), from: context, shuffled: true)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .frame(maxWidth: .infinity)
            }
        }
        .font(.headline)
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 12))
        .controlSize(.large)
    }

    /// Every downloaded song, A to Z, as Music lists songs.
    private var allSongs: some View {
        let songs = downloads.songs.sortedByTitle
        let context = PlayContext.songs(String(localized: "Downloaded"))
        return LazyVStack(alignment: .leading, spacing: 0) {
            ShelfHeader(title: String(localized: "Downloaded Songs")) {
                Text(songs.count, format: .number)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)

            ForEach(songs.enumerated(), id: \.element.id) { index, song in
                Button {
                    player.play(songs.request(startingAt: index), from: context)
                } label: {
                    TrackRow(
                        title: song.title,
                        subtitle: song.artistName,
                        cover: song.cover,
                        plays: feed.facts[song.identity]?.plays,
                        isExplicit: song.isExplicit,
                        isCurrent: player.current?.songIdentity == song.identity
                    )
                }
                .buttonStyle(RowButtonStyle())
                .contextMenu { OfflineSongMenu(song: song) }
                Divider().padding(.leading, 60)
            }
        }
    }

    private var emptyState: some View {
        PlayStateCard(
            symbol: "arrow.down.circle",
            title: String(localized: "Nothing Downloaded Yet"),
            message: String(localized: "Songs you download in Apple Music play here without a connection. To download the songs you add to your library from Tracks, turn on Automatic Downloads in Settings › Apps › Music.")
        ) {
            EmptyView()
        }
    }

    // MARK: - Shelves

    /// Tracks’ mixes, with only their downloaded songs, when enough of them are.
    private var downloadedMixes: [DownloadedMix] {
        let downloaded = downloads.byIdentity
        return feed.mixes.all.compactMap { mix in
            let songs = mix.songs.compactMap { downloaded[$0.songIdentity] }
            return songs.count >= Self.mixMinimum ? DownloadedMix(mix: mix, songs: songs) : nil
        }
    }

    /// The downloaded songs you play most, from Tracks’ history.
    private var mostPlayed: [OfflineSong] {
        let plays = downloads.songs.compactMap { song in feed.facts[song.identity].map { (song, $0.plays) } }
        return Array(plays.filter { $0.1 > 1 }.sorted { $0.1 > $1.1 }.prefix(15).map(\.0))
    }
}

/// A mix, cut down to the songs of it that are downloaded.
private struct DownloadedMix: Identifiable {
    let mix: Mix
    let songs: [OfflineSong]
    var id: String { mix.id }
}

private extension Array where Element == OfflineSong {
    var sortedByTitle: [OfflineSong] {
        sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

/// Why Play is showing only downloads, and, when there's a connection, the way back.
private struct OfflineBanner: View {
    @Environment(YourMusic.self) private var music
    @AppStorage(OfflineMode.storageKey) private var isOfflineModeOn = false

    var body: some View {
        let isOnline = music.network.isOnline
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: isOnline ? "arrow.down.circle.fill" : "wifi.slash")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(isOnline ? "Offline Mode" : "You're Offline")
                    .font(.headline)
                Text(isOnline
                    ? "Only songs downloaded to this iPhone."
                    : "Playing songs downloaded to this iPhone. Every song is still kept.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if isOnline {
                Button("Turn Off") {
                    withAnimation { isOfflineModeOn = false }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A mix on the offline shelf: plays its downloaded songs, since its page needs a connection.
private struct OfflineMixTile: View {
    let mix: Mix
    let songs: [OfflineSong]
    @Environment(PlayerModel.self) private var player

    var body: some View {
        let context = PlayContext(kind: .mix, title: mix.kind.title)
        Button {
            player.play(songs.request(), from: context)
        } label: {
            TileLabel(title: mix.kind.title, subtitle: String(AttributedString(localized: "^[\(songs.count) song](inflect: true) downloaded").characters)) { side in
                MixCover(mix: mix, size: side)
            }
        }
        .buttonStyle(.pressable)
        .accessibilityHint("Plays the downloaded songs from this mix")
        .contextMenu {
            Button("Play", systemImage: "play") { player.play(songs.request(), from: context) }
            Button("Shuffle", systemImage: "shuffle") { player.play(songs.request(), from: context, shuffled: true) }
            Divider()
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                player.enqueue(songs.request(), next: true, title: mix.kind.title)
            }
            Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") {
                player.enqueue(songs.request(), next: false, title: mix.kind.title)
            }
        }
    }
}

/// A downloaded song on a shelf: plays the shelf from it.
private struct OfflineSongTile: View {
    let song: OfflineSong
    let queue: [OfflineSong]
    let context: PlayContext
    @Environment(PlayerModel.self) private var player

    var body: some View {
        Button {
            player.play(queue.request(startingAt: queue.firstIndex(of: song) ?? 0), from: context)
        } label: {
            TileLabel(title: song.title, subtitle: song.artistName) { side in
                CoverImage(cover: song.cover, size: side)
            }
        }
        .buttonStyle(.pressable)
        .contextMenu { OfflineSongMenu(song: song) }
    }
}

/// What can be done with a downloaded song without a connection.
private struct OfflineSongMenu: View {
    let song: OfflineSong
    @Environment(PlayerModel.self) private var player
    @Environment(\.openPlayRoute) private var openPlayRoute

    var body: some View {
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
            player.enqueue([song].request(), next: true, title: song.title)
        }
        Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") {
            player.enqueue([song].request(), next: false, title: song.title)
        }
        Divider()
        Button("Your Stats", systemImage: "chart.bar.xaxis") {
            openPlayRoute(.stats(.song(song.identity)))
        }
    }
}
