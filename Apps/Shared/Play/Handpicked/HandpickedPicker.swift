import SwiftUI
import MusicKit
import TracksCore

/// Making a Handpicked station: pick songs as Music adds songs to a playlist, from a search,
/// your playlists, what you've played lately and what you play most, then start it. Each
/// song's ⊕ picks it and turns to a ✓, and a second tap takes it back out.
struct HandpickedPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @Environment(PlayerModel.self) private var player
    @Environment(YourMusic.self) private var music
    @State private var query = ""
    @State private var results: [Handpick]?
    @State private var recent: [Handpick] = []
    @State private var mostPlayed: [Handpick] = []
    @State private var hasLoaded = false
    @State private var selection = HandpickedSelection()
    @State private var isStarting = false

    var body: some View {
        let source = model.musicSource
        let count = selection.picks.count
        NavigationStack {
            List {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    browse(source: source)
                } else {
                    searchResults
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .navigationTitle(Handpicked.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            // On the Mac a sheet's subtitle shows in the window behind it too, so there the
            // list says the same at its top.
            .navigationSubtitle(Self.status(count: count))
            #endif
            .searchable(text: $query, prompt: source == .appleMusic ? "Apple Music" : "Your Music")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isStarting {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Starting Station")
                    } else {
                        Button("Start", role: .confirm, action: start)
                            .disabled(selection.picks.isEmpty)
                    }
                }
            }
            .navigationDestination(for: PickerPlaylist.self) { playlist in
                PickerPlaylistSongs(playlist: playlist)
            }
            .task { await loadHistory(source: source) }
            .task(id: query) { await search(source: source) }
        }
        .environment(selection)
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 560, idealHeight: 640)
        #endif
    }

    // MARK: Browsing

    private func start() {
        isStarting = true
        let picks = selection.picks
        Task {
            await HandpickedPlayback.start(model: model, picks: picks)
            dismiss()
        }
    }

    private static func status(count: Int) -> String {
        count == 0
            ? String(localized: "Pick Songs for a Station")
            : String(localized: "\(count) of \(Handpicked.limit) Picked")
    }

    @ViewBuilder
    private func browse(source: MusicSource) -> some View {
        #if os(macOS)
        Section {} header: {
            Text(Self.status(count: selection.picks.count))
        }
        #endif
        if PickerPlaylist.canBrowse(source: source, isDemo: player.isDemo) {
            Section {
                NavigationLink {
                    PickerPlaylists()
                } label: {
                    Label("Playlists", systemImage: "music.note.list")
                }
            }
        }
        if !recent.isEmpty {
            Section("Recently Played") {
                ForEach(recent) { PickRow(pick: $0) }
            }
        }
        if !mostPlayed.isEmpty {
            Section("Most Played") {
                ForEach(mostPlayed) { PickRow(pick: $0) }
            }
        }
        if hasLoaded, recent.isEmpty, mostPlayed.isEmpty {
            Section {
                Text("Search for songs you love, or pick from your playlists. Songs you play show up here too.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        // Last, so a pick never moves the rows under your finger.
        if !selection.picks.isEmpty {
            Section("Picked") {
                ForEach(selection.picks) { PickRow(pick: $0) }
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if let results {
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(results) { PickRow(pick: $0) }
                }
            }
        } else {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .listRowBackground(Color.clear)
            .accessibilityLabel("Searching")
        }
    }

    // MARK: Loading

    /// Songs from the history that can play from the source on: for your own music, only the
    /// ones in it, as your songs.
    private func loadHistory(source: MusicSource) async {
        let (history, signals) = (model.library.history, player.signals)
        let (recentSongs, mostSongs) = await OffMainActor.run {
            (HandpickedChoices.recentlyPlayed(in: history, signals: signals, limit: 40),
             HandpickedChoices.mostPlayed(in: history, signals: signals, limit: 40))
        }
        recent = Array(picks(from: recentSongs, source: source).prefix(15))
        mostPlayed = Array(picks(from: mostSongs, source: source).prefix(25))
        hasLoaded = true
    }

    private func picks(from songs: [MixSong], source: MusicSource) -> [Handpick] {
        switch source {
        case .appleMusic:
            // Songs played from your own music have no Apple Music id to play by.
            return songs.filter { player.canPlay(songID: $0.songID) && !isLocalID($0.songID) }.map(Handpick.init)
        case .yourMusic:
            var seen = Set<String>()
            return songs.compactMap { music.track(for: HistorySong($0)) }
                .filter { seen.insert($0.identity).inserted }
                .map { Handpick($0, music: music) }
        }
    }

    private func isLocalID(_ id: String) -> Bool {
        music.index.track(id: id) != nil
    }

    private func search(source: MusicSource) async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else {
            results = nil
            return
        }
        // Typing settles before asking.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        results = nil
        let found: [Handpick]
        switch source {
        case .yourMusic:
            found = music.index.tracks
                .filter { $0.title.localizedStandardContains(term) || $0.artist.localizedStandardContains(term) || ($0.album?.localizedStandardContains(term) ?? false) }
                .filter(music.isPlayable)
                .prefix(40)
                .map { Handpick($0, music: music) }
        case .appleMusic:
            found = await catalogSongs(matching: term)
        }
        guard !Task.isCancelled else { return }
        results = found
    }

    private func catalogSongs(matching term: String) async -> [Handpick] {
        #if DEBUG
        if player.isDemo {
            // The sample catalog has none of the sample history's songs: both, as Apple
            // Music's search would find them.
            let yours = HandpickedChoices.mostPlayed(in: model.library.history, limit: 500)
                .filter { $0.title.localizedStandardContains(term) || $0.artistName.localizedStandardContains(term) }
                .map(Handpick.init)
            let catalog = DemoCatalog.songs(count: 160, offset: 0, artists: nil)
                .filter { $0.title.localizedStandardContains(term) || $0.artistName.localizedStandardContains(term) }
                .map(Handpick.init(song:))
            return yours + catalog
        }
        #endif
        guard MusicAuthorization.currentStatus == .authorized else { return [] }
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
        request.limit = 25
        let songs = (try? await request.response().songs).map(Array.init) ?? []
        return PlayPreferences.versions(of: songs).map(Handpick.init(song:))
    }
}

/// A song to pick: its cover, name and artist, and ⊕, or ✓ once picked. The whole row picks.
private struct PickRow: View {
    let pick: Handpick
    @Environment(HandpickedSelection.self) private var selection
    /// Counts picks made here, so the tap is felt.
    @State private var toggles = 0

    var body: some View {
        let isPicked = selection.contains(pick.identity)
        let isBlocked = !isPicked && selection.isFull
        Button {
            withAnimation(PlayMotion.row) {
                if selection.toggle(pick) { toggles += 1 }
            }
        } label: {
            HStack(spacing: 12) {
                CoverImage(cover: pick.cover, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pick.title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(pick.artistName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: isPicked ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(isBlocked ? 0.4 : 1)
        .disabled(isBlocked)
        .sensoryFeedback(.selection, trigger: toggles)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
        .accessibilityHint(isPicked ? "Takes it out of the station" : "Adds it to the station")
    }
}

// MARK: - Playlists

/// A playlist to pick songs from: Apple Music's, or one of yours in your own music.
enum PickerPlaylist: Hashable, Identifiable {
    case appleMusic(Playlist)
    case tracks(TracksPlaylist)

    var id: String {
        switch self {
        case .appleMusic(let playlist): "am.\(playlist.id.rawValue)"
        case .tracks(let playlist): "tracks.\(playlist.id.uuidString)"
        }
    }

    var name: String {
        switch self {
        case .appleMusic(let playlist): playlist.name
        case .tracks(let playlist): playlist.name
        }
    }

    /// Sample data's Apple Music playlists have no songs to show.
    static func canBrowse(source: MusicSource, isDemo: Bool) -> Bool {
        source == .yourMusic || (!isDemo && MusicAuthorization.currentStatus == .authorized)
    }
}

/// Your playlists, the ones played most lately first.
private struct PickerPlaylists: View {
    @Environment(AppModel.self) private var model
    @Environment(YourMusic.self) private var music
    @State private var playlists: [PickerPlaylist]?

    var body: some View {
        List {
            if let playlists {
                if playlists.isEmpty {
                    ContentUnavailableView("No Playlists", systemImage: "music.note.list", description: Text("Playlists you make or add show up here."))
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(playlists) { playlist in
                        NavigationLink(value: playlist) {
                            PickerPlaylistRow(playlist: playlist)
                        }
                    }
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Playlists")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
    }

    private func load() async {
        guard playlists == nil else { return }
        if model.musicSource == .yourMusic {
            playlists = music.playlists.recent.map(PickerPlaylist.tracks)
            return
        }
        var request = MusicLibraryRequest<Playlist>()
        #if os(iOS)
        request.sort(by: \.lastPlayedDate, ascending: false)
        #endif
        let found = (try? await request.response().items).map(Array.init) ?? []
        playlists = found.map(PickerPlaylist.appleMusic)
    }
}

private struct PickerPlaylistRow: View {
    let playlist: PickerPlaylist

    var body: some View {
        HStack(spacing: 12) {
            switch playlist {
            case .appleMusic(let playlist):
                CoverImage(cover: playlist.artwork.map(CoverArt.artwork) ?? .url(nil, seed: playlist.name), size: 44)
            case .tracks(let playlist):
                CoverImage(cover: .url(nil, seed: playlist.name), size: 44)
            }
            Text(playlist.name)
                .lineLimit(1)
        }
    }
}

/// A playlist's songs, each to pick.
private struct PickerPlaylistSongs: View {
    let playlist: PickerPlaylist
    @Environment(YourMusic.self) private var music
    @Environment(PlayFeed.self) private var feed
    @State private var songs: [Handpick]?

    var body: some View {
        List {
            if let songs {
                if songs.isEmpty {
                    ContentUnavailableView("No Songs", systemImage: "music.note", description: Text("This playlist has no songs that can play here."))
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(songs) { PickRow(pick: $0) }
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle(playlist.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
    }

    private func load() async {
        guard songs == nil else { return }
        switch playlist {
        case .tracks(let playlist):
            var seen = Set<String>()
            songs = music.songs(in: playlist, facts: feed.facts)
                .filter { music.isPlayable($0) && seen.insert($0.identity).inserted }
                .map { Handpick($0, music: music) }
        case .appleMusic(let playlist):
            let tracks = try? await playlist.with([.tracks]).tracks
            var seen = Set<String>()
            songs = (tracks.map(Array.init) ?? []).compactMap { track -> Handpick? in
                guard case .song(let song) = track else { return nil }
                let pick = Handpick(song: song)
                return seen.insert(pick.identity).inserted ? pick : nil
            }
        }
    }
}
