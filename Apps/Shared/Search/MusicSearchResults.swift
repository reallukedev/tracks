import SwiftUI
import MusicKit
import TracksCore

/// Apple Music results for a search, from the catalog or the library, in Music's order:
/// artists, songs, albums, playlists, stations. With no query, recent searches.
struct MusicSearchResults: View {
    let query: String
    let scope: SearchScope
    /// Puts a recent search back in the field.
    let search: (String) -> Void

    @Environment(AppModel.self) private var model
    @Environment(PlayerModel.self) private var player
    @Environment(PlayFeed.self) private var feed
    @Environment(\.openPlayRoute) private var openRoute
    @State private var results = Results()
    @State private var state: LoadState = .idle
    /// Bumped by Try Again, so the retry runs as the search task itself and a newer query
    /// still replaces it.
    @State private var attempt = 0
    /// The song selected on the Mac, where a click selects and a double-click plays.
    @FocusState private var selectedSong: String?
    @AppStorage("recentMusicSearches") private var recentStorage = ""
    @AppStorage(PlayPreferences.allowsExplicitKey) private var allowsExplicit = true

    enum LoadState: Equatable { case idle, loading, loaded, failed }

    struct Results {
        var artists: [Artist] = []
        var songs: [Song] = []
        var albums: [Album] = []
        var playlists: [Playlist] = []
        var stations: [MusicKit.Station] = []

        var isEmpty: Bool {
            artists.isEmpty && songs.isEmpty && albums.isEmpty && playlists.isEmpty && stations.isEmpty
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PlayMetrics.sectionSpacing) {
                if isBlank {
                    blank
                } else if model.isShowingSampleData {
                    // Sample data never reaches Apple Music.
                } else if !results.isEmpty {
                    HistoryRecallHint(query: query) { model.search.scope = .history }
                    resultSections
                }
            }
            // The page's width even when empty, so the overlay's message has it too.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 16)
            .padding(.bottom, 28)
            .animation(.snappy, value: results.isEmpty)
        }
        .overlay { overlay }
        .task(id: SearchKey(query: query, scope: scope, authorization: model.musicAuthorization, allowsExplicit: allowsExplicit, attempt: attempt)) {
            await runSearch()
        }
    }

    // MARK: - Before searching

    /// What you looked for lately, as chips to look again, and the moods to browse by.
    @ViewBuilder
    private var blank: some View {
        if !recents.isEmpty, !model.isShowingSampleData {
            RecentSearchesSection(recents: recents, clear: { recentStorage = "" }, search: search) {
                recentStorage = RecentSearches.removing($0, from: recentStorage)
            }
        }
        if showsBrowse {
            BrowseSections()
        }
    }

    /// The moods and genres before a search of the catalog: they play from the history, so
    /// sample data has them too.
    private var showsBrowse: Bool {
        scope == .appleMusic && (model.musicAuthorization == .authorized || model.isShowingSampleData)
    }

    // MARK: - Results

    /// The best match, if there's a clear one, as ``SearchRanking`` picks it.
    private var topResult: TopResult? {
        let kind = SearchRanking.topKind(
            for: query,
            artist: results.artists.first?.name,
            album: results.albums.first?.title,
            song: results.songs.first?.title
        )
        return switch kind {
        case .artist: results.artists.first.map(TopResult.artist)
        case .album: results.albums.first.map(TopResult.album)
        case .song: results.songs.first.map(TopResult.song)
        case nil: nil
        }
    }

    enum TopResult {
        case artist(Artist), album(Album), song(Song)
    }

    /// The top result as the card shows it.
    private func card(for result: TopResult) -> SearchTopResult {
        switch result {
        case .artist(let artist):
            SearchTopResult(
                title: artist.name,
                kind: String(localized: "Artist"),
                cover: artist.artwork.map(CoverArt.artwork),
                isArtist: true,
                open: { remember(); openRoute(.artist(artist)) },
                play: { remember(); Task { await ArtistPlayback.playTopSongs(of: artist, player: player) } }
            )
        case .album(let album):
            SearchTopResult(
                title: CollectionKind.of(album).title,
                kind: String(localized: "Album · \(album.artistName)"),
                cover: album.artwork.map(CoverArt.artwork) ?? .url(nil, seed: album.title),
                open: { remember(); openRoute(.album(album)) },
                play: { remember(); player.play(.album(album), from: PlayContext(kind: .album, title: album.title)) }
            )
        case .song(let song):
            SearchTopResult(
                title: song.title,
                kind: String(localized: "Song · \(song.artistName)"),
                cover: song.artwork.map(CoverArt.artwork) ?? .url(nil, seed: song.albumTitle ?? song.title),
                open: { remember(); player.play(.songs([song]), from: .songs(String(localized: "Search"))) },
                play: { remember(); player.play(.songs([song]), from: .songs(String(localized: "Search"))) }
            )
        }
    }

    @ViewBuilder
    private var resultSections: some View {
        let top = topResult
        let songs = Array(results.songs.prefix(8))
        SearchLead(top: top.map(card), hasSongs: !songs.isEmpty) {
            SearchSectionTitle("Songs")
        } songs: {
            songRows(songs, all: songs)
        }

        if results.artists.count > (top.isArtist ? 1 : 0) {
            Shelf(title: String(localized: "Artists"), items: Array(results.artists.dropFirst(top.isArtist ? 1 : 0).prefix(10))) { artist in
                NavigationLink(value: PlayRoute.artist(artist)) {
                    VStack(spacing: 8) {
                        CoverImage(cover: artist.artwork.map(CoverArt.artwork) ?? .url(nil, seed: artist.name), size: 120, isCircle: true)
                        Text(artist.name)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    .frame(width: 120)
                }
                .buttonStyle(.pressable)
                .simultaneousGesture(TapGesture().onEnded { remember() })
            }
        }
        if !results.albums.isEmpty {
            Shelf(title: String(localized: "Albums"), items: results.albums.prefix(10).map(FeedItem.init(album:))) { item in
                FeedTile(item: item)
                    .simultaneousGesture(TapGesture().onEnded { remember() })
            }
        }
        if !results.playlists.isEmpty {
            Shelf(title: String(localized: "Playlists"), items: results.playlists.prefix(10).map(FeedItem.init(playlist:))) { item in
                FeedTile(item: item)
                    .simultaneousGesture(TapGesture().onEnded { remember() })
            }
        }
        if !results.stations.isEmpty {
            Shelf(title: String(localized: "Stations"), items: results.stations.prefix(8).map { FeedItem(station: $0) }) { item in
                FeedTile(item: item)
                    .simultaneousGesture(TapGesture().onEnded { remember() })
            }
        }
    }

    /// Songs in rows, two columns of them on the Mac.
    private func songRows(_ shown: [Song], all: [Song]) -> some View {
        SearchSongGrid(items: shown) { song in
            let play = {
                remember()
                // The song, then the rest of the results, as playing from any list does.
                player.play(.songs(all, startingAt: all.firstIndex(of: song) ?? 0), from: .songs(String(localized: "Search")))
            }
            SongResultRow(id: song.id.rawValue, selection: $selectedSong, step: { step(from: song, by: $0, in: all) }, play: play) {
                TrackRow(
                    title: song.title,
                    subtitle: [song.artistName, song.albumTitle].compactMap(\.self).joined(separator: " · "),
                    cover: song.artwork.map(CoverArt.artwork) ?? .url(nil, seed: song.title),
                    isExplicit: song.isExplicit,
                    isCurrent: player.current?.songIdentity == HistoryImport.key(title: song.title, artistName: song.artistName),
                    artist: song.artistName
                )
                .padding(.vertical, 5)
                .contentShape(.rect)
            }
            .macDraggable(SongDrag(song))
            .contextMenu { SongMenu(song: song, play: play) }
        }
    }

    /// The arrow keys, through every song shown, across both columns in reading order.
    private func step(from song: Song, by offset: Int, in all: [Song]) {
        guard let index = all.firstIndex(of: song), all.indices.contains(index + offset) else { return }
        selectedSong = all[index + offset].id.rawValue
    }

    @ViewBuilder
    private var overlay: some View {
        if model.isShowingSampleData, !isBlank {
            ContentUnavailableView {
                Label("Not Available with Sample Data", systemImage: "music.note")
            } description: {
                Text("Search History to look through the sample listening.")
            } actions: {
                Button("Search History") { model.search.scope = .history }
            }
        } else if model.musicAuthorization != .authorized, !model.isShowingSampleData {
            ContentUnavailableView {
                Label("Search Apple Music", systemImage: "magnifyingglass")
            } description: {
                Text("Let Tracks use Apple Music to search its catalog and your library.")
            } actions: {
                if model.musicAuthorization == .notDetermined {
                    Button("Allow Apple Music Access") { Task { await model.requestMusicAccess() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else if isBlank, recents.isEmpty, !showsBrowse {
            ContentUnavailableView(
                scope == .appleMusic ? "Search Apple Music" : "Search Your Library",
                systemImage: "magnifyingglass",
                description: Text(scope == .appleMusic
                    ? "Find any song, album, artist or station, and play it here."
                    : "Find songs, albums, artists and playlists you've added.")
            )
        } else if !isBlank, state == .failed {
            ContentUnavailableView {
                Label("Couldn't Search", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check your connection and try again. Your history is on this device, so you can search it now.")
            } actions: {
                Button("Try Again") { attempt += 1 }
                Button("Search History") { model.search.scope = .history }
            }
        } else if !isBlank, state == .loaded, results.isEmpty {
            SearchNoResults(query: query)
        } else if !isBlank, state == .loading, results.isEmpty {
            ProgressView()
        }
    }

    // MARK: - Searching

    private var isBlank: Bool {
        query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func runSearch() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, !model.isShowingSampleData, model.musicAuthorization == .authorized else {
            results = Results()
            state = .idle
            return
        }
        // A short pause so typing doesn't search on every letter.
        try? await Task.sleep(for: .milliseconds(280))
        guard !Task.isCancelled else { return }
        state = .loading
        do {
            let found = scope == .library ? try await Self.searchLibrary(term) : try await Self.searchCatalog(term)
            guard !Task.isCancelled else { return }
            // One version of each song and album: Apple Music lists both.
            var picked = found
            picked.songs = PlayPreferences.versions(of: found.songs, allowsExplicit: allowsExplicit)
            picked.albums = PlayPreferences.versions(of: found.albums, allowsExplicit: allowsExplicit)
            results = picked
            state = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed
        }
    }

    private static func searchCatalog(_ term: String) async throws -> Results {
        var request = MusicCatalogSearchRequest(
            term: term,
            types: [Artist.self, Song.self, Album.self, Playlist.self, MusicKit.Station.self]
        )
        request.limit = 12
        let response = try await request.response()
        return Results(
            artists: Array(response.artists),
            songs: Array(response.songs),
            albums: Array(response.albums),
            playlists: Array(response.playlists),
            stations: Array(response.stations)
        )
    }

    private static func searchLibrary(_ term: String) async throws -> Results {
        var request = MusicLibrarySearchRequest(term: term, types: [Artist.self, Song.self, Album.self, Playlist.self])
        request.limit = 12
        let response = try await request.response()
        return Results(
            artists: Array(response.artists),
            songs: Array(response.songs),
            albums: Array(response.albums),
            playlists: Array(response.playlists)
        )
    }

    // MARK: - Recent searches

    private var recents: [String] {
        RecentSearches.list(recentStorage)
    }

    /// Keeps the query once someone acts on a result, newest first, eight at most.
    private func remember() {
        recentStorage = RecentSearches.adding(query, to: recentStorage)
    }
}

private struct SearchKey: Equatable {
    let query: String
    let scope: SearchScope
    let authorization: MusicAuthorization.Status
    let allowsExplicit: Bool
    let attempt: Int
}

private extension Optional where Wrapped == MusicSearchResults.TopResult {
    var isArtist: Bool {
        if case .artist = self { true } else { false }
    }
}
