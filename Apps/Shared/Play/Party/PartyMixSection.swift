import SwiftUI
import TracksCore

/// Your Party Mix from the history, for Apple Music: the songs you play most that suit the
/// party, to play, shuffle or keep as a playlist in your library.
struct PartyHistoryMix: View {
    let vibe: PartyVibe
    let songs: [MixSong]
    @Environment(PlayerModel.self) private var player
    @AppStorage(PlayPreferences.allowsExplicitKey) private var allowsExplicit = true
    @State private var showsAll = false

    var body: some View {
        let shown = Array(songs.prefix(showsAll ? PartyMetrics.mixExpanded : PartyMetrics.mixCollapsed))
        PartyMixLayout(
            vibe: vibe,
            covers: covers,
            // The history doesn't know which songs are explicit; the player skips them.
            skipsExplicit: !allowsExplicit,
            // Saving goes to your Apple Music library, which sample data has none of.
            canSave: !player.isDemo,
            count: songs.count,
            showsAll: $showsAll,
            play: { play(from: nil, shuffled: $0) },
            save: save
        ) {
            ForEach(shown) { song in
                Button {
                    play(from: song, shuffled: false)
                } label: {
                    TrackRow(
                        title: song.title,
                        subtitle: song.artistName,
                        cover: .url(song.artworkURL, seed: song.albumTitle ?? song.title),
                        plays: song.plays,
                        isCurrent: player.current?.songIdentity == song.songIdentity
                    )
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .contextMenu { HistorySongMenu(song: song) }
                if song.id != shown.last?.id { Divider().padding(.leading, 60) }
            }
        }
    }

    /// Four different albums' covers, for the mosaic.
    private var covers: [CoverArt] {
        var seen = Set<String>()
        return Array(songs.compactMap { song -> CoverArt? in
            guard let url = song.artworkURL, seen.insert(song.albumTitle ?? url).inserted else { return nil }
            return .url(url, seed: song.albumTitle ?? song.title)
        }
        .prefix(4))
    }

    private func play(from first: MixSong?, shuffled: Bool) {
        let start = first.flatMap { songs.firstIndex(of: $0) } ?? 0
        player.play(
            .history(songs.map(HistorySong.init), startingAt: start),
            from: PlayContext(kind: .mix, title: vibe.playlistName),
            shuffled: shuffled
        )
    }

    private func save() {
        player.saveAsPlaylist(named: vibe.playlistName, songs: songs.map(HistorySong.init))
    }
}

/// Your Party Mix from your own music: your songs that suit the party, to play, shuffle or
/// keep as one of your playlists.
struct PartyLocalMix: View {
    let vibe: PartyVibe
    let tracks: [LocalTrack]
    @Environment(PlayerModel.self) private var player
    @Environment(YourMusic.self) private var music
    @State private var showsAll = false

    var body: some View {
        let shown = Array(tracks.prefix(showsAll ? PartyMetrics.mixExpanded : PartyMetrics.mixCollapsed))
        PartyMixLayout(
            vibe: vibe,
            covers: covers,
            skipsExplicit: false,
            canSave: true,
            count: tracks.count,
            showsAll: $showsAll,
            play: { play(from: nil, shuffled: $0) },
            save: save
        ) {
            ForEach(shown) { track in
                Button {
                    play(from: track, shuffled: false)
                } label: {
                    LocalTrackRow(track: track, isCurrent: player.current?.local?.id == track.id)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .contextMenu { LocalTrackMenu(track: track) }
                if track.id != shown.last?.id { Divider().padding(.leading, 60) }
            }
        }
    }

    private var covers: [CoverArt] {
        var seen = Set<String>()
        return Array(tracks.compactMap { track -> CoverArt? in
            guard seen.insert(track.albumKey).inserted else { return nil }
            return .url(music.artworkURL(track.artwork)?.absoluteString, seed: track.album ?? track.title)
        }
        .prefix(4))
    }

    private func play(from first: LocalTrack?, shuffled: Bool) {
        let start = first.flatMap { tracks.firstIndex(of: $0) } ?? 0
        player.play(.local(tracks, startingAt: start), from: PlayContext(kind: .mix, title: vibe.playlistName), shuffled: shuffled)
    }

    private func save() {
        music.playlists.create(name: vibe.playlistName, tracks: tracks)
        player.confirm(String(localized: "Saved to Your Playlists"))
    }
}

/// The mix's section: its header with Save as Playlist, a card with a mosaic of its covers,
/// what it's made of and Play and Shuffle, then its first songs.
struct PartyMixLayout<Rows: View>: View {
    let vibe: PartyVibe
    let covers: [CoverArt]
    let skipsExplicit: Bool
    let canSave: Bool
    let count: Int
    @Binding var showsAll: Bool
    let play: (_ shuffled: Bool) -> Void
    let save: () -> Void
    @ViewBuilder let rows: Rows
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShelfHeader(title: String(localized: "Your Party Mix")) {
                Button("Save as Playlist", action: save)
                    .buttonStyle(.borderless)
                    .disabled(!canSave)
            }
            card
            VStack(alignment: .leading, spacing: 0) {
                rows
                if count > PartyMetrics.mixCollapsed {
                    Button(action: toggleShowsAll) {
                        Text(showsAll ? "Show Less" : "Show More")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }
        }
        .padding(.horizontal, PlayMetrics.margin)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
            layout {
                MosaicCover(covers: covers, symbol: "party.popper.fill", size: dynamicTypeSize.isAccessibilitySize ? 120 : 88)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(vibe.title) Mix")
                        .font(.headline)
                    Text("\(count) songs · \(vibe.mixLine)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if skipsExplicit {
                        Text("Explicit songs are skipped as it plays.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            PartyPlayButtons(tint: vibe.palette[1]) {
                play(false)
            } shuffle: {
                play(true)
            }
        }
        .padding(PartyMetrics.cardPadding)
        .frame(maxWidth: PartyMetrics.topPickWidth, alignment: .leading)
        .background(Color.cardFill, in: .rect(cornerRadius: PartyMetrics.cardRadius, style: .continuous))
    }

    private func toggleShowsAll() {
        withAnimation(PlayMotion.panel) { showsAll.toggle() }
    }
}
