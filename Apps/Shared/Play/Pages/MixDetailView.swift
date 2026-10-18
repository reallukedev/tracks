import SwiftUI
import TracksCore

/// One of Tracks’ mixes: its cover on a field of its colour, why it exists, and its songs.
struct MixDetailView: View {
    let mixID: String
    @Environment(PlayFeed.self) private var feed
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let mix = feed.mixes.mix(id: mixID) {
                content(mix)
            } else if feed.hasBuilt {
                ContentUnavailableView {
                    Label("This Mix Has Moved On", systemImage: "music.note.list")
                } description: {
                    Text("Mixes change as you listen, and this one isn't among today's.")
                } actions: {
                    Button("See Today's Mixes") { dismiss() }
                }
            } else {
                loading
            }
        }
    }

    /// The history is still being read: the page's shape, with nothing to play yet.
    private var loading: some View {
        let header = CollectionHeader(
            kind: .mix,
            title: "",
            tintCover: nil,
            isLoading: true,
            play: {},
            shuffle: {}
        ) {
            EmptyView()
        } cover: { _ in
            EmptyView()
        }
        #if os(iOS)
        return List {
            Section { header }
            LoadingRows()
                .listRowSeparator(.hidden)
        }
        .collectionPage(title: "")
        #else
        return CollectionMacLayout {
            header
        } content: {
            LoadingRows(count: 8)
                .padding(.horizontal, PlayMetrics.margin)
                .padding(.top, 12)
        }
        #endif
    }

    @ViewBuilder
    private func content(_ mix: Mix) -> some View {
        let context = PlayContext(kind: .mix, title: mix.kind.title)
        let songs = player.songs(in: mix)
        #if os(iOS)
        List {
            Section {
                header(mix, songs: songs, context: context)
            }

            Section {
                ForEach(mix.songs) { song in
                    let playable = player.canPlay(songID: song.songID)
                    Button {
                        play(song, in: songs, context: context)
                    } label: {
                        TrackRow(
                            title: song.title,
                            subtitle: song.artistName,
                            cover: .url(song.artworkURL, seed: song.albumTitle ?? song.title),
                            isCurrent: player.current?.songIdentity == song.songIdentity,
                            isPlayable: playable,
                            artist: song.artistName
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!playable)
                    .trackMenu { HistorySongMenu(song: song) }
                    .collectionRowInsets(hasCover: true)
                    .swipeActions(edge: .leading) {
                        if playable {
                            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                                player.enqueue(.history([HistorySong(song)]), next: true, title: song.title)
                            }
                            .tint(.indigo)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Suggest Less", systemImage: "hand.thumbsdown") {
                            player.setSuggestLess(song.songIdentity, true)
                        }
                        .tint(.gray)
                    }
                }
            } footer: {
                CollectionFooter(lines: [footer(mix, missing: mix.songs.count - songs.count)])
            }
        }
        .collectionPage(title: mix.kind.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("More", systemImage: "ellipsis") { moreItems(mix, songs: songs) }
            }
        }
        #else
        CollectionMacLayout {
            header(mix, songs: songs, context: context)
        } content: {
            CollectionTable(
                tracks: mix.songs.enumerated().map { index, song in
                    CollectionTrack(
                        id: song.id,
                        position: index + 1,
                        number: index + 1,
                        title: song.title,
                        artist: song.artistName,
                        album: song.albumTitle ?? "",
                        plays: plays(of: song),
                        duration: 0,
                        isCurrent: player.current?.songIdentity == song.songIdentity,
                        isPlayable: player.canPlay(songID: song.songID),
                        artwork: .url(song.artworkURL, seed: song.albumTitle ?? song.title),
                        drag: SongDrag([HistorySong(song)]).songs.first
                    )
                },
                play: { id in
                    if let song = mix.songs.first(where: { $0.id == id }) { play(song, in: songs, context: context) }
                },
                enqueue: { ids, next in
                    let chosen = ids.compactMap { id in mix.songs.first { $0.id == id } }.map(HistorySong.init)
                    guard !chosen.isEmpty else { return }
                    player.enqueue(.history(chosen), next: next, title: mix.kind.title)
                }
            ) { row in
                if let song = mix.songs.first(where: { $0.id == row.id }) {
                    HistorySongMenu(song: song)
                }
            }
        }
        .navigationTitle(mix.kind.title)
        #endif
    }

    private func header(_ mix: Mix, songs: [HistorySong], context: PlayContext) -> some View {
        let first = mix.covers.first
        return CollectionHeader(
            kind: .mix,
            title: mix.kind.title,
            facts: Text(mix.kind.reason),
            tintCover: .url(first?.url, seed: first?.seed ?? mix.id),
            canPlay: !songs.isEmpty,
            play: { player.play(.history(songs), from: context) },
            shuffle: { player.play(.history(songs), from: context, shuffled: true) }
        ) {
            moreItems(mix, songs: songs)
        } cover: { side in
            MixCover(mix: mix, size: side)
        }
    }

    @ViewBuilder
    private func moreItems(_ mix: Mix, songs: [HistorySong]) -> some View {
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
            player.enqueue(.history(songs), next: true, title: mix.kind.title)
        }
        .disabled(songs.isEmpty)
        Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") {
            player.enqueue(.history(songs), next: false, title: mix.kind.title)
        }
        .disabled(songs.isEmpty)
        if !player.isDemo {
            Divider()
            Button("Save as Playlist", systemImage: "text.badge.plus") {
                player.saveAsPlaylist(named: Self.playlistName(for: mix), songs: songs)
            }
            .disabled(songs.isEmpty)
        }
    }

    private func play(_ song: MixSong, in songs: [HistorySong], context: PlayContext) {
        guard let start = songs.firstIndex(where: { $0.title == song.title && $0.artistName == song.artistName }) else { return }
        player.play(.history(songs, startingAt: start), from: context)
    }

    #if os(macOS)
    /// Your plays, as every other page counts them, for the Mac table's Plays column.
    private func plays(of song: MixSong) -> Int {
        feed.facts[song.songIdentity]?.plays ?? song.plays
    }
    #endif

    /// "On Repeat · September 23": a mix changes, so the saved copy says when it was made.
    static func playlistName(for mix: Mix) -> String {
        "\(mix.kind.title) · \(Date.now.formatted(.dateTime.month(.wide).day()))"
    }

    private func footer(_ mix: Mix, missing: Int) -> String {
        guard missing > 0 else {
            return String(localized: "Changes as you listen; songs you skip or suggest less drop out.")
        }
        return String(AttributedString(localized: "Changes as you listen; songs you skip or suggest less drop out. ^[\(missing) song](inflect: true) couldn't be found in Apple Music.").characters)
    }
}
