import SwiftUI
import MusicKit
import TracksCore

/// Party, from its tile on Find Your Mood: finding the playlist for the party you're having.
/// You say what kind of party, and the whole page turns to it: the field takes its colours,
/// Apple Music's best playlist for it leads as the Top Pick, more follow, then your own songs
/// that suit it, as a mix to play or keep.
///
/// With your own music, Apple Music's playlists can't play, so the page offers the mix from
/// your songs and your own playlists that look like party ones, and says where the rest went.
struct PartyView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerModel.self) private var player
    @Environment(YourMusic.self) private var music
    @AppStorage(PartyVibe.storageKey) private var vibe = PartyVibe.danceFloor
    @AppStorage(PlayPreferences.allowsExplicitKey) private var allowsExplicit = true

    // What's been found this visit, by party, so going back to one is instant.
    @State private var found: [PartyVibe: PartyCatalog.Found] = [:]
    @State private var failed: Set<PartyVibe> = []
    @State private var historyMixes: [PartyVibe: [MixSong]] = [:]
    @State private var localMixes: [PartyVibe: [LocalTrack]] = [:]
    /// Counts Try Again, so the load runs again for the same party.
    @State private var attempts = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PlayMetrics.sectionSpacing) {
                PartyHero(vibe: $vibe, vibes: vibes)
                if model.musicSource == .yourMusic {
                    yourMusicSections
                } else {
                    appleMusicSections
                }
            }
            .padding(.bottom, 24)
        }
        #if os(macOS)
        // The field runs on under the bar, which says nothing the field doesn't.
        .headerUnderBar()
        #else
        .toolbarTitleDisplayMode(.inline)
        #endif
        // A new party cancels the search for the last one, if it's still going.
        .task(id: LoadKey(vibe: vibe, source: model.musicSource, canSearch: canSearch, allowsExplicit: allowsExplicit, attempt: attempts)) {
            await load()
        }
        .onChange(of: allowsExplicit, forgetExplicitChoices)
    }

    private struct LoadKey: Hashable {
        let vibe: PartyVibe
        let source: MusicSource
        let canSearch: Bool
        let allowsExplicit: Bool
        let attempt: Int
    }

    /// Apple Music can be searched: access is on, or it's sample data.
    private var canSearch: Bool {
        player.isDemo || model.musicAuthorization == .authorized
    }

    private var vibes: [PartyVibe] { PartyVibe.ordered(allowsExplicit: allowsExplicit) }

    private var nextVibe: PartyVibe {
        let index = vibes.firstIndex(of: vibe) ?? 0
        return vibes[(index + 1) % vibes.count]
    }

    // MARK: Apple Music

    @ViewBuilder
    private var appleMusicSections: some View {
        if !canSearch {
            PlayAccessCard()
                .padding(.horizontal, PlayMetrics.margin)
        } else if failed.contains(vibe) {
            ContentUnavailableView {
                Label("Couldn't Reach Apple Music", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try Again", action: tryAgain)
                    .buttonStyle(.glass)
            }
        } else if let found = found[vibe] {
            if found.playlists.isEmpty, found.stations.isEmpty {
                ContentUnavailableView {
                    Label("No \(vibe.title) Playlists", systemImage: vibe.symbol)
                } description: {
                    Text("Apple Music didn't have any playlists for this party just now.")
                } actions: {
                    Button("Try Another Vibe", action: tryAnotherVibe)
                        .buttonStyle(.glass)
                }
            } else {
                PartyPlaylists(vibe: vibe, playlists: found.playlists)
            }
        } else {
            PartyPlaylistsPlaceholder(vibe: vibe)
        }

        if let songs = historyMixes[vibe], songs.count >= PartyMix.minimumSongs {
            PartyHistoryMix(vibe: vibe, songs: songs)
                // A fresh list, folded, for each party.
                .id(vibe)
        }

        if let stations = found[vibe]?.stations, !stations.isEmpty {
            Shelf(title: String(localized: "Party Stations"), items: stations) { FeedTile(item: $0) }
        }
    }

    // MARK: Your music

    @ViewBuilder
    private var yourMusicSections: some View {
        let own = PartyPlaylistRanking.own(music.playlists.recent, name: \.name, for: vibe)
        if let tracks = localMixes[vibe], tracks.count >= PartyMix.minimumSongs {
            PartyLocalMix(vibe: vibe, tracks: tracks)
                .id(vibe)
        }
        if !own.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ShelfHeader(title: String(localized: "Your Party Playlists")) { EmptyView() }
                PartyGrid {
                    ForEach(own) { playlist in
                        PartyOwnPlaylistTile(playlist: playlist)
                    }
                }
            }
            .padding(.horizontal, PlayMetrics.margin)
        }
        if let tracks = localMixes[vibe], tracks.count < PartyMix.minimumSongs, own.isEmpty {
            ContentUnavailableView {
                Label("Nothing for \(vibe.title) Yet", systemImage: vibe.symbol)
            } description: {
                Text("None of your music suits it yet, and none of your playlists look like party ones. Tracks goes by each song's genre.")
            } actions: {
                Button("Try Another Vibe", action: tryAnotherVibe)
                    .buttonStyle(.glass)
            }
        }
        Label("Apple Music's party playlists show here when Music Source is set to Apple Music.", systemImage: "info.circle")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, PlayMetrics.margin)
    }

    // MARK: Actions and loading

    private func tryAgain() {
        failed.remove(vibe)
        attempts += 1
    }

    private func tryAnotherVibe() {
        vibe = nextVibe
    }

    /// The ranking follows the explicit setting, and so does the mix's note.
    private func forgetExplicitChoices() {
        found = [:]
        historyMixes = [:]
    }

    private func load() async {
        let vibe = vibe
        let (history, signals) = (model.library.history, player.signals)
        if model.musicSource == .yourMusic {
            guard localMixes[vibe] == nil else { return }
            let tracks = music.playableTracks
            let mix = await OffMainActor.run { PartyMix.tracks(for: vibe, from: tracks, history: history, signals: signals) }
            guard !Task.isCancelled else { return }
            localMixes[vibe] = mix
            return
        }

        if historyMixes[vibe] == nil {
            let songs = await OffMainActor.run { PartyMix.songs(for: vibe, in: history, signals: signals) }
            guard !Task.isCancelled else { return }
            historyMixes[vibe] = songs.filter { player.canPlay(songID: $0.songID) }
        }
        guard canSearch, found[vibe] == nil, !failed.contains(vibe) else { return }
        let outcome = await PartyCatalog.find(vibe, isDemo: player.isDemo, allowsExplicit: allowsExplicit)
        // Another party was chosen meanwhile: this one is looked for again if it comes back.
        guard !Task.isCancelled else { return }
        switch outcome {
        case .found(let result): found[vibe] = result
        case .failed: failed.insert(vibe)
        }
    }
}

/// The Top Pick, then the rest of the party's playlists in a grid.
private struct PartyPlaylists: View {
    let vibe: PartyVibe
    let playlists: [Playlist]

    var body: some View {
        if let top = playlists.first {
            PartyTopPick(playlist: top, vibe: vibe)
                .padding(.horizontal, PlayMetrics.margin)
        }
        let rest = playlists.dropFirst()
        if !rest.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ShelfHeader(title: String(localized: "\(vibe.title) Playlists")) { EmptyView() }
                PartyGrid {
                    ForEach(rest, id: \.id) { playlist in
                        PartyPlaylistTile(playlist: playlist)
                    }
                }
            }
            .padding(.horizontal, PlayMetrics.margin)
        }
    }
}

/// The shape of the playlists while they're found: the Top Pick's card and four tiles.
private struct PartyPlaylistsPlaceholder: View {
    let vibe: PartyVibe

    var body: some View {
        PartyTopPickPlaceholder()
            .padding(.horizontal, PlayMetrics.margin)
        VStack(alignment: .leading, spacing: 12) {
            ShelfHeader(title: String(localized: "\(vibe.title) Playlists")) { EmptyView() }
            PartyGrid {
                ForEach(0..<4, id: \.self) { _ in PartyTilePlaceholder() }
            }
        }
        .padding(.horizontal, PlayMetrics.margin)
    }
}

/// One of your own playlists in the grid, for your music.
private struct PartyOwnPlaylistTile: View {
    let playlist: TracksPlaylist
    @Environment(YourMusic.self) private var music
    @Environment(PlayFeed.self) private var feed

    var body: some View {
        let songs = music.songs(in: playlist, facts: feed.facts)
        NavigationLink(value: PlayRoute.tracksPlaylist(playlist.id)) {
            PartyTileLabel(title: playlist.name, subtitle: PlaylistRow.summary(playlist, count: songs.count)) { side in
                PlaylistCover(songs: songs, isSmart: playlist.isSmart, seed: playlist.name, size: side)
            }
        }
        .buttonStyle(.pressable)
    }
}
