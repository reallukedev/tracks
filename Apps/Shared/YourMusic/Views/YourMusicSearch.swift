import SwiftUI
import TracksCore

/// Searching your music, laid out as Apple Music's search is: before you type, what you
/// searched lately and the moods; then the best match, your songs, artists and albums, and
/// songs your servers have that aren't in your music yet, asked of them as you type.
struct YourMusicSearchResults: View {
    let query: String
    /// Puts a recent search back in the field.
    var search: (String) -> Void = { _ in }

    @Environment(YourMusic.self) private var music
    @Environment(AppModel.self) private var model
    @Environment(PlayerModel.self) private var player
    @Environment(\.openPlayRoute) private var openRoute
    @AppStorage("recentYourMusicSearches") private var recentStorage = ""

    /// What's in your music for the search, looked up off the main thread.
    @State private var found = Found()
    /// All of your songs shown, rather than the first few.
    @State private var showsAllSongs = false

    @State private var fromServers: [LocalTrack] = []
    /// The search `fromServers` fully answers, so a newer one shows as still being asked.
    @State private var answeredQuery = ""
    /// A full search is taking a while, as Octo's do while it finds songs: said so.
    @State private var isSlow = false
    /// Where the next page of the search starts, on the servers that may have more.
    @State private var nextPage = ServerSearchPage()
    /// How many of `fromServers` are shown: a few at first, more as they're scrolled to.
    @State private var shownCount = Self.revealed
    /// Albums and artists your servers have, or a server like Octo finds, that aren't yours.
    @State private var serverAlbums: [ServerDiscovery.Album] = []
    @State private var serverArtists: [ServerArtist] = []
    /// The search `serverAlbums` and `serverArtists` answer, so an older one's don't show.
    @State private var serverShelvesQuery = ""
    /// Whether the end of the server's songs is on screen, for going on.
    @State private var isEndInView = false

    /// How many songs from your servers show at a time.
    private static let revealed = 15
    /// How many of your own songs show before See All.
    private static let songsShown = 8

    struct Found: Equatable {
        var query = ""
        var tracks: [LocalTrack] = []
        var albums: [LocalAlbum] = []
        var artists: [LocalArtist] = []

        var isEmpty: Bool { tracks.isEmpty && albums.isEmpty && artists.isEmpty }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PlayMetrics.sectionSpacing) {
                if isBlank {
                    blank
                } else {
                    HistoryRecallHint(query: query) { model.search.scope = .history }
                    results
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 28)
            .animation(.snappy, value: found.query)
        }
        .scrollDismissesKeyboard(.immediately)
        .launchScroll()
        .overlay { overlay }
        .task(id: SearchKey(query: query, songs: music.index.tracks.count)) {
            await searchYourMusic()
        }
        // Albums and artists, asked for as a pause in typing gives the songs time to be: quick
        // even on Octo, so they come well before the songs it finds.
        .task(id: query) {
            await searchServerAlbumsAndArtists()
        }
        .task(id: query) {
            await searchServerSongs()
        }
        .onChange(of: query) { showsAllSongs = false }
    }

    // MARK: - Before searching

    @ViewBuilder
    private var blank: some View {
        if !recents.isEmpty {
            RecentSearchesSection(recents: recents, clear: { recentStorage = "" }, search: search) {
                recentStorage = RecentSearches.removing($0, from: recentStorage)
            }
        }
        if hasMusic {
            BrowseSections()
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        // Why songs are dimmed, when a server can't be reached.
        let unreachable = music.servers.servers.filter { music.servers.status[$0.id].map(Self.isUnreachable) ?? false }
        if let server = unreachable.first, !music.index.isEmpty {
            Label(String(localized: "Can't reach \(server.name). Only downloaded songs play."), systemImage: "wifi.exclamationmark")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, PlayMetrics.margin)
        }
        let match = topMatch
        let top = match.map(card)
        let songs = shownSongs(besides: match)
        SearchLead(top: top, hasSongs: !songs.isEmpty) {
            songsTitle
        } songs: {
            songRows(songs, all: found.tracks)
        }

        let artists = shelfArtists(besides: match)
        if !artists.isEmpty {
            Shelf(title: String(localized: "Artists"), items: artists) { artist in
                SearchArtistTile(artist: artist)
                    .simultaneousGesture(TapGesture().onEnded { remember() })
            }
        }
        let albums = shelfAlbums(besides: match)
        if !albums.isEmpty {
            Shelf(title: String(localized: "Albums"), items: albums) { album in
                Group {
                    switch album {
                    case .yours(let album): LocalAlbumTile(album: album)
                    case .server(let album): ServerAlbumTile(album: album)
                    }
                }
                .simultaneousGesture(TapGesture().onEnded { remember() })
            }
        }

        serverSongs
    }

    private var songsTitle: some View {
        HStack(alignment: .firstTextBaseline) {
            SearchSectionTitle("Songs")
            Spacer()
            if found.tracks.count > Self.songsShown {
                Button(showsAllSongs ? "Show Less" : "See All") {
                    withAnimation(.snappy) { showsAllSongs.toggle() }
                }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(.tint)
            }
        }
    }

    /// Your songs, the top result's left out so it isn't listed twice.
    private func shownSongs(besides match: TopMatch?) -> [LocalTrack] {
        var songs = found.tracks
        if case .song(let top) = match { songs.removeAll { $0.id == top.id } }
        return showsAllSongs ? songs : Array(songs.prefix(Self.songsShown))
    }

    /// Your songs in rows. Playing one plays the rest of the results after it.
    private func songRows(_ shown: [LocalTrack], all: [LocalTrack]) -> some View {
        SearchSongGrid(items: shown) { track in
            Button {
                remember()
                let queue = all.filter(music.isPlayable)
                guard let start = queue.firstIndex(of: track) else { return }
                player.play(.local(queue, startingAt: start), from: .songs(query))
            } label: {
                songRow(track)
            }
            .buttonStyle(.plain)
            .disabled(!music.isPlayable(track))
            .contextMenu { LocalTrackMenu(track: track, showsStats: true) }
        }
    }

    private func songRow(_ track: LocalTrack) -> some View {
        TrackRow(
            title: track.title,
            subtitle: [track.artist, track.album].compactMap(\.self).joined(separator: " · "),
            cover: CoverArt.url(music.artworkURL(track.artwork)?.absoluteString, seed: track.album ?? track.title),
            isCurrent: player.current?.local?.id == track.id,
            localTrack: track,
            isPlayable: music.isPlayable(track)
        )
        .padding(.vertical, 5)
        .contentShape(.rect)
    }

    // MARK: - From your servers

    /// Songs your servers have for the search that aren't in your music: from a server like
    /// Octo, songs it finds for you to play and add.
    @ViewBuilder
    private var serverSongs: some View {
        let isAsking = answeredQuery != query && !music.servers.onlineServers.isEmpty
        if !fromServers.isEmpty || isAsking {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    SearchSectionTitle(serverSectionTitle)
                    Text("Not in your music yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)
                SearchSongGrid(items: Array(fromServers.prefix(shownCount))) { track in
                    HStack(spacing: 4) {
                        Button {
                            remember()
                            player.play(.local(fromServers, startingAt: fromServers.firstIndex(of: track) ?? 0), from: .songs(query))
                        } label: {
                            songRow(track)
                        }
                        .buttonStyle(.plain)
                        AddFoundSongButton(track: track)
                    }
                    .contextMenu { LocalTrackMenu(track: track) }
                }
                // Still asking: the places of what's to come are held below what's here.
                if isAsking {
                    if isSlow {
                        Text("Finding songs you don't have yet. This can take a few seconds.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                            .transition(.opacity)
                    }
                    LoadingRows(count: fromServers.isEmpty ? 3 : 2)
                } else if shownCount < fromServers.count || nextPage.hasMore {
                    // The end, once it's scrolled to: more of what's here, then the next page.
                    // Only while it's in view, so the servers are asked no further than you go.
                    LoadingRows(count: 1)
                        .onScrollVisibilityChange(threshold: 0.1) { isEndInView = $0 }
                        .onDisappear { isEndInView = false }
                        .task(id: "\(isEndInView).\(shownCount).\(fromServers.count)") {
                            guard isEndInView else { return }
                            await showMore()
                        }
                }
            }
            .padding(.horizontal, PlayMetrics.margin)
        }
    }

    private var serverSectionTitle: LocalizedStringKey {
        let servers = music.servers.onlineServers
        if servers.count == 1, let name = servers.first?.name { return "More on \(name)" }
        return "More from Your Servers"
    }

    // MARK: - The top result

    /// The best match for a search.
    enum TopMatch {
        case artist(LocalArtist), album(LocalAlbum), song(LocalTrack)
    }

    /// The best match, if there's a clear one, as ``SearchRanking`` picks it; a song only if it
    /// can play.
    private var topMatch: TopMatch? {
        let song = found.tracks.first(where: music.isPlayable)
        let kind = SearchRanking.topKind(
            for: query,
            artist: found.artists.first?.name,
            album: found.albums.first?.displayTitle,
            song: song?.title
        )
        return switch kind {
        case .artist: found.artists.first.map(TopMatch.artist)
        case .album: found.albums.first.map(TopMatch.album)
        case .song: song.map(TopMatch.song)
        case nil: nil
        }
    }

    /// The top result as its card shows it.
    private func card(for match: TopMatch) -> SearchTopResult {
        switch match {
        case .artist(let artist):
            let playable = artist.tracks.filter(music.isPlayable)
            return SearchTopResult(
                title: artist.name,
                kind: String(localized: "Artist"),
                cover: music.artistPicture(for: artist),
                isArtist: true,
                open: { remember(); openRoute(.localArtist(artist.id)) },
                play: playable.isEmpty ? nil : { remember(); player.play(.local(playable), from: PlayContext(kind: .artist, title: artist.name), shuffled: true) }
            )
        case .album(let album):
            let playable = album.tracks.filter(music.isPlayable)
            return SearchTopResult(
                title: album.displayTitle,
                kind: String(localized: "\(album.kind.name) · \(album.artist)"),
                cover: .url(music.artworkURL(album.artwork)?.absoluteString, seed: album.title),
                open: { remember(); openRoute(.localAlbum(album.id)) },
                play: playable.isEmpty ? nil : { remember(); player.play(.local(playable), from: PlayContext(kind: .album, title: album.title)) }
            )
        case .song(let track):
            return SearchTopResult(
                title: track.title,
                kind: String(localized: "Song · \(track.artist)"),
                cover: .url(music.artworkURL(track.artwork)?.absoluteString, seed: track.album ?? track.title),
                open: { remember(); playFromTop(track) },
                play: { remember(); playFromTop(track) }
            )
        }
    }

    private func playFromTop(_ track: LocalTrack) {
        let queue = found.tracks.filter(music.isPlayable)
        player.play(.local(queue, startingAt: queue.firstIndex(of: track) ?? 0), from: .songs(query))
    }

    // MARK: - Shelves

    /// Yours first, then your servers': ten at most, the top result's artist left out.
    private func shelfArtists(besides match: TopMatch?) -> [SearchArtist] {
        var yours = found.artists
        if case .artist(let top) = match { yours.removeAll { $0.id == top.id } }
        let theirs = serverShelvesQuery == query ? serverArtists : []
        return Array((yours.map { SearchArtist.yours($0, picture: music.artistPicture(for: $0)) }
            + theirs.map { SearchArtist.server($0, picture: music.artistPicture(for: $0)) }).prefix(10))
    }

    private func shelfAlbums(besides match: TopMatch?) -> [SearchAlbum] {
        var yours = found.albums
        if case .album(let top) = match { yours.removeAll { $0.id == top.id } }
        let theirs = serverShelvesQuery == query ? serverAlbums : []
        return Array((yours.map(SearchAlbum.yours) + theirs.map(SearchAlbum.server)).prefix(10))
    }

    // MARK: - States

    @ViewBuilder
    private var overlay: some View {
        // Not before the files have been read once, when "nothing" isn't known yet.
        if !hasMusic, music.hasScanned || !music.servers.servers.isEmpty {
            ContentUnavailableView(
                "Nothing to Search Yet",
                systemImage: "magnifyingglass",
                description: Text("Import songs or connect a server, and search them here.")
            )
        } else if !isBlank, found.query == query, found.isEmpty, fromServers.isEmpty,
                  serverShelvesQuery != query || (serverAlbums.isEmpty && serverArtists.isEmpty),
                  answeredQuery == query || music.servers.onlineServers.isEmpty {
            SearchNoResults(query: query)
        }
    }

    private static func isUnreachable(_ status: MusicServers.Status) -> Bool {
        switch status {
        case .offline, .wrongPassword, .failed: true
        case .online, .connecting: false
        }
    }

    private var hasMusic: Bool {
        !music.index.isEmpty || !music.servers.onlineServers.isEmpty
    }

    private var isBlank: Bool {
        query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Searching

    private func searchYourMusic() async {
        let query = query
        guard !isBlank else {
            found = Found(query: query)
            return
        }
        // A moment's pause, so fast typing doesn't stack up searches of the whole library.
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        let index = music.index
        let result = await Task.detached(priority: .userInitiated) { index.search(query) }.value
        guard !Task.isCancelled else { return }
        found = Found(query: query, tracks: result.tracks, albums: result.albums, artists: result.artists)
    }

    private func searchServerAlbumsAndArtists() async {
        guard !music.servers.onlineServers.isEmpty,
              query.trimmingCharacters(in: .whitespaces).count >= 2 else {
            serverAlbums = []
            serverArtists = []
            return
        }
        let query = query
        try? await Task.sleep(for: .milliseconds(700))
        guard !Task.isCancelled else { return }
        let found = await music.searchServerAlbumsAndArtists(query)
        guard !Task.isCancelled else { return }
        withAnimation(.snappy) {
            serverAlbums = found.albums
            serverArtists = found.artists
            serverShelvesQuery = query
        }
    }

    private func searchServerSongs() async {
        guard !music.servers.onlineServers.isEmpty, !isBlank else {
            fromServers = []
            answeredQuery = query
            return
        }
        let query = query
        isSlow = false
        shownCount = Self.revealed
        nextPage = ServerSearchPage()
        // A short pause so typing doesn't ask on every letter.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        // First the songs your servers have, which even Octo answers at once…
        let quick = await music.searchServers(query, isFull: false)
        guard !Task.isCancelled else { return }
        withAnimation(.snappy) { fromServers = quick.tracks }
        guard query.trimmingCharacters(in: .whitespaces).count >= 3 else {
            nextPage = quick
            answeredQuery = query
            return
        }
        // …then, once typing stops, the songs they can find for you. Octo takes seconds
        // to, so it's asked for the search you meant, not every word on the way to it.
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        let slow = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { isSlow = true }
        }
        defer { slow.cancel() }
        let found = await music.searchServers(query, isFull: true)
        guard !Task.isCancelled else { return }
        // What's shown stays where it is, and what's new joins below it.
        let shown = Set(quick.tracks.map(\.identity))
        withAnimation(.snappy) {
            fromServers = quick.tracks + found.tracks.filter { !shown.contains($0.identity) }
            nextPage = found
            answeredQuery = query
            isSlow = false
        }
        music.discover.warmCovers(Array(fromServers.prefix(shownCount)))
    }

    /// Shows more of what's here, or, with all of it shown, asks for the next page. A page that
    /// brings nothing new, the library's matches being in your music already, ends the search.
    private func showMore() async {
        if shownCount < fromServers.count {
            withAnimation(.snappy) { shownCount += Self.revealed }
            return
        }
        guard nextPage.hasMore else { return }
        let query = query
        let page = await music.searchServers(query, after: nextPage)
        guard !Task.isCancelled, query == self.query else { return }
        let shown = Set(fromServers.map(\.identity))
        let new = page.tracks.filter { !shown.contains($0.identity) }
        withAnimation(.snappy) {
            fromServers += new
            nextPage = new.isEmpty ? ServerSearchPage() : page
            shownCount += Self.revealed
        }
    }

    // MARK: - Recent searches

    private var recents: [String] {
        RecentSearches.list(recentStorage)
    }

    /// Keeps the query once someone acts on a result.
    private func remember() {
        recentStorage = RecentSearches.adding(query, to: recentStorage)
    }
}

private struct SearchKey: Equatable {
    let query: String
    /// The library changing, a sync say, searches again.
    let songs: Int
}

/// An artist on search's shelf: one of yours, or one a server has.
enum SearchArtist: Identifiable {
    case yours(LocalArtist, picture: CoverArt?)
    case server(ServerArtist, picture: CoverArt?)

    var id: String {
        switch self {
        case .yours(let artist, _): "yours:\(artist.id)"
        case .server(let artist, _): "server:\(artist.id)"
        }
    }
}

/// An album on search's shelf: one of yours, or one a server has.
enum SearchAlbum: Identifiable {
    case yours(LocalAlbum)
    case server(ServerDiscovery.Album)

    var id: String {
        switch self {
        case .yours(let album): "yours:\(album.id)"
        case .server(let album): "server:\(album.id)"
        }
    }
}

/// An artist's circle and name, opening their page.
private struct SearchArtistTile: View {
    let artist: SearchArtist

    var body: some View {
        NavigationLink(value: route) {
            VStack(spacing: 8) {
                ArtistPicture(cover: picture, name: name, size: 120)
                Text(name)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(width: 120)
        }
        .buttonStyle(.pressable)
        .contextMenu {
            if case .yours(let artist, _) = artist {
                LocalArtistMenu(artist: artist)
            }
        }
    }

    private var name: String {
        switch artist {
        case .yours(let artist, _): artist.name
        case .server(let artist, _): artist.name
        }
    }

    private var picture: CoverArt? {
        switch artist {
        case .yours(_, let picture), .server(_, let picture): picture
        }
    }

    private var route: PlayRoute {
        switch artist {
        case .yours(let artist, _): .localArtist(artist.id)
        case .server(let artist, _): .serverArtist(artist)
        }
    }
}

/// Adds a song a server found for you to your music, at the end of its row. Once asked, the
/// row's own ring shows the server getting it, and the button's place stays, so nothing moves.
struct AddFoundSongButton: View {
    let track: LocalTrack
    @Environment(YourMusic.self) private var music
    @Environment(PlayerModel.self) private var player
    @State private var adds = 0

    var body: some View {
        ZStack {
            if track.isFromServer, !music.isInYourMusic(track), !music.servers.isWaitingToKeep(track) {
                Button {
                    adds += 1
                    Task { player.confirm(await music.keep(track)) }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add to Your Music")
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .frame(width: 44)
        .sensoryFeedback(.success, trigger: adds)
        .animation(.snappy, value: music.servers.isWaitingToKeep(track))
    }
}

extension LocalAlbum.Kind {
    /// "Album", "EP" or "Single".
    var name: String {
        switch self {
        case .album: String(localized: "Album")
        case .ep: String(localized: "EP")
        case .single: String(localized: "Single")
        }
    }

    var collectionKind: CollectionKind {
        switch self {
        case .album: .album
        case .ep: .ep
        case .single: .single
        }
    }
}
