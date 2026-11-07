import SwiftUI
import TracksCore

/// An artist in your music, laid out as Apple Music's artist pages are: their top songs,
/// newest release, albums, singles and EPs, the albums they appear on, and artists like them
/// from your server.
struct LocalArtistPage: View {
    let artistID: String
    @Environment(YourMusic.self) private var music
    @Environment(Lidarr.self) private var lidarr
    @Environment(PlayFeed.self) private var feed
    @Environment(PlayerModel.self) private var player
    @Environment(\.openPlayRoute) private var openPlayRoute
    /// What their server says about them, once asked.
    @State private var fromServer = FromServer()
    /// Albums by others they're on, worked out when the library changes.
    @State private var appearsOn: [LocalAlbum] = []

    struct FromServer {
        /// Their songs of yours in the order the server ranks them, most popular first.
        var topSongs: [LocalTrack] = []
        var similar: [SimilarArtist] = []
    }

    var body: some View {
        if let artist = music.index.artist(id: artistID) {
            let top = topSongs(of: artist)
            let playable = artist.tracks.filter(music.isPlayable)
            let context = PlayContext(kind: .artist, title: artist.name)
            ArtistScaffold(
                name: artist.name,
                picture: picture(of: artist),
                play: playable.isEmpty ? nil : {
                    // Their top songs, or everything that can play when none of those can.
                    let top = top.songs.filter(music.isPlayable)
                    player.play(.local(top.isEmpty ? playable : top), from: context)
                },
                shuffle: playable.isEmpty ? nil : { player.play(.local(playable), from: context, shuffled: true) },
                showsYourTopSongs: false
            ) {
                if lidarr.isSetUp {
                    if let followed = lidarr.artist(named: artist.name), let id = followed.id {
                        // Everything Lidarr knows of theirs, to get what you're missing.
                        Button("Show in Lidarr", systemImage: "tray.and.arrow.down") {
                            openPlayRoute(.lidarrArtist(id))
                        }
                    } else {
                        AddToLidarrButton(artistName: artist.name)
                    }
                }
            } sections: {
                songs(top.songs, title: top.title, artist: artist.name, context: context)
                let (albums, singles) = releases(of: artist)
                if artist.albums.count > 1, let latest = latestAlbum(of: artist) {
                    ArtistLatestRelease(
                        title: latest.displayTitle,
                        cover: cover(of: latest),
                        detail: detail(of: latest),
                        route: .localAlbum(latest.id)
                    ) {
                        LocalAlbumMenu(album: latest)
                    }
                }
                if !albums.isEmpty {
                    Shelf(title: String(localized: "Albums"), items: albums) { album in
                        LocalAlbumShelfTile(album: album, showsYear: true)
                    }
                }
                if !singles.isEmpty {
                    Shelf(title: String(localized: "Singles & EPs"), items: singles) { album in
                        LocalAlbumShelfTile(album: album, showsYear: true)
                    }
                }
                if !appearsOn.isEmpty {
                    Shelf(title: String(localized: "Appears On"), items: appearsOn) { album in
                        LocalAlbumShelfTile(album: album)
                    }
                }
                if !fromServer.similar.isEmpty {
                    Shelf(title: String(localized: "Similar Artists"), items: fromServer.similar) { other in
                        SimilarArtistTile(artist: other)
                    }
                }
            }
            .task(id: "\(artist.id).\(music.index.tracks.count)") {
                let (index, id) = (music.index, artist.id)
                appearsOn = await Task.detached(priority: .userInitiated) { index.albums(appearingOn: id) }.value
            }
            .task(id: "\(artist.id).\(music.servers.onlineServers.count)") {
                await loadFromServer(artist)
            }
        } else {
            ScrollView {
                ArtistPageMessage(
                    title: String(localized: "Artist Not Found"),
                    symbol: "music.microphone",
                    message: String(localized: "Their songs aren't in your music anymore. They may have been removed, or their server is offline.")
                ) {
                    NavigationLink("Show All Artists", value: PlayRoute.yourMusic(.artists))
                        .buttonStyle(.bordered)
                }
                .padding(.vertical, 20)
            }
            .navigationTitle("Artist")
        }
    }

    /// Their songs: the ones you play most; before you've played any, the ones their server
    /// ranks highest; failing that, all of them in album order.
    private func topSongs(of artist: LocalArtist) -> (title: String, songs: [LocalTrack]) {
        let yours = artist.tracks
            .map { ($0, feed.facts[$0.identity]?.plays ?? 0) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        if !yours.isEmpty { return (String(localized: "Your Top Songs"), yours) }
        if !fromServer.topSongs.isEmpty { return (String(localized: "Top Songs"), fromServer.topSongs) }
        return (String(localized: "Songs"), artist.tracks)
    }

    private func songs(_ tracks: [LocalTrack], title: String, artist: String, context: PlayContext) -> some View {
        let visible = Array(tracks.prefix(ArtistSongsSection<EmptyView, EmptyView>.visibleRows))
        return ArtistSongsSection(title: title, showsSeeAll: tracks.count > visible.count) {
            ArtistSongListPage(title: title, artist: artist) {
                ForEach(tracks) { track in songRow(track, in: tracks, context: context) }
            }
        } content: {
            ForEach(visible) { track in songRow(track, in: tracks, context: context) }
        }
    }

    private func songRow(_ track: LocalTrack, in tracks: [LocalTrack], context: PlayContext) -> some View {
        Button {
            let queue = tracks.filter(music.isPlayable)
            guard let start = queue.firstIndex(of: track) else { return }
            player.play(.local(queue, startingAt: start), from: context)
        } label: {
            ArtistSongLabel(
                title: track.title,
                subtitle: track.album,
                cover: .url(music.artworkURL(track.artwork)?.absoluteString, seed: track.album ?? track.title),
                plays: feed.facts[track.identity]?.plays,
                isCurrent: player.current?.local?.id == track.id,
                localTrack: track,
                isPlayable: music.isPlayable(track)
            )
        }
        .buttonStyle(.plain)
        .disabled(!music.isPlayable(track))
        .contextMenu { LocalTrackMenu(track: track, showsStats: true) }
    }

    private func picture(of artist: LocalArtist) -> CoverArt? {
        let picture = music.artistPicture(for: artist)
        #if DEBUG
        if picture == nil, LibraryLaunch.drawsSamplePictures { return .url("sample", seed: artist.name) }
        #endif
        return picture
    }

    private func cover(of album: LocalAlbum) -> CoverArt {
        .url(music.artworkURL(album.artwork)?.absoluteString, seed: album.title)
    }

    /// "2024 · Album · 12 songs".
    private func detail(of album: LocalAlbum) -> String {
        let songs = String(AttributedString(localized: "^[\(album.tracks.count) song](inflect: true)").characters)
        return [album.year.map(String.init), album.kind.name, songs].compactMap(\.self).joined(separator: " · ")
    }

    /// The newest album that has a year; none when no album says when it came out.
    private func latestAlbum(of artist: LocalArtist) -> LocalAlbum? {
        artist.albums.filter { $0.year != nil }.max { ($0.year ?? 0, $0.addedAt) < ($1.year ?? 0, $1.addedAt) }
    }

    /// Their albums, and their singles and EPs apart, each newest first.
    private func releases(of artist: LocalArtist) -> (albums: [LocalAlbum], singles: [LocalAlbum]) {
        let newest = artist.albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        let singles = newest.filter { $0.kind != .album }
        // An artist with only singles has them as their albums, rather than an empty shelf.
        guard singles.count < newest.count else { return (newest, []) }
        return (newest.filter { $0.kind == .album }, singles)
    }

    /// Their top songs and artists like them, from a server that has them.
    private func loadFromServer(_ artist: LocalArtist) async {
        guard let (serverID, artistID) = music.serverArtist(named: artist.name),
              let client = music.servers.client(for: serverID) else { return }
        async let similar = try? await client.similarArtists(to: artistID, count: 15)
        let top = (try? await client.topSongs(artist: artist.name, count: 20)) ?? []
        // Only the ones in your music, as yours.
        let yours = top.compactMap { song in
            music.index.track(id: LocalTrack.id(for: .server(serverID: serverID, songID: song.id)))
                ?? music.index.tracks(withIdentity: HistoryImport.key(title: song.title, artistName: song.artist ?? artist.name)).first
        }
        var seen = Set<String>()
        let others = (await similar ?? []).compactMap { other -> SimilarArtist? in
            let key = StatsCalculator.folded(other.name)
            guard key != artist.id, seen.insert(key).inserted else { return nil }
            if let mine = music.index.artist(id: key) { return .yours(mine) }
            return .server(ServerArtist(other, serverID: serverID))
        }
        guard !Task.isCancelled else { return }
        withAnimation(PlayMotion.panel) {
            fromServer = FromServer(topSongs: yours, similar: others)
        }
    }
}

/// An artist like the one whose page it is: one of yours, or one only their server has.
enum SimilarArtist: Identifiable {
    case yours(LocalArtist)
    case server(ServerArtist)

    var id: String {
        switch self {
        case .yours(let artist): "yours:\(artist.id)"
        case .server(let artist): "server:\(artist.id)"
        }
    }
}

/// A similar artist's circle, opening their page.
private struct SimilarArtistTile: View {
    let artist: SimilarArtist
    @Environment(YourMusic.self) private var music

    var body: some View {
        switch artist {
        case .yours(let artist):
            NavigationLink(value: PlayRoute.localArtist(artist.id)) {
                ArtistCircleTile(name: artist.name, picture: music.artistPicture(for: artist))
            }
            .buttonStyle(.pressable)
            .contextMenu { LocalArtistMenu(artist: artist) }
        case .server(let artist):
            NavigationLink(value: PlayRoute.serverArtist(artist)) {
                ArtistCircleTile(name: artist.name, picture: music.artistPicture(for: artist))
            }
            .buttonStyle(.pressable)
        }
    }
}

/// An album of yours on an artist's shelf: the library's hover tile on the Mac.
struct LocalAlbumShelfTile: View {
    let album: LocalAlbum
    /// Its year under it rather than its artist, on the artist's own page.
    var showsYear = false

    var body: some View {
        let subtitle = showsYear ? album.year.map(String.init) ?? album.kind.name : nil
        #if os(macOS)
        LocalAlbumGridTile(album: album, subtitle: subtitle, side: LibraryCoverTile<EmptyView, EmptyView>.shelfSide)
        #else
        LocalAlbumTile(album: album, subtitle: subtitle)
        #endif
    }
}

/// An album of yours in a grid of covers, with Play under the pointer on the Mac.
struct LocalAlbumGridTile: View {
    let album: LocalAlbum
    var subtitle: String?
    /// A fixed side for a shelf; nil fills the grid's column.
    var side: CGFloat?
    @Environment(YourMusic.self) private var music
    @Environment(PlayerModel.self) private var player

    var body: some View {
        let playable = album.tracks.filter(music.isPlayable)
        LibraryCoverTile(
            title: album.title,
            subtitle: subtitle ?? album.artist,
            route: .localAlbum(album.id),
            play: playable.isEmpty ? nil : { player.play(.local(playable), from: PlayContext(kind: .album, title: album.title)) },
            side: side
        ) { side in
            LocalCover(artwork: album.artwork, seed: album.title, size: side)
                .aspectRatio(1, contentMode: .fit)
        } menu: {
            LocalAlbumMenu(album: album)
        }
    }
}

/// Every song in your music, to search and sort: a table on the Mac, a list on iPhone.
struct LocalSongsPage: View {
    var body: some View {
        #if os(macOS)
        LibraryYourSongsTablePage()
        #else
        LocalSongsList()
        #endif
    }
}

#if os(iOS)
private struct LocalSongsList: View {
    @Environment(YourMusic.self) private var music
    @Environment(PlayFeed.self) private var feed
    @Environment(PlayerModel.self) private var player
    @AppStorage("yourMusicSongOrder") private var order = LibraryOrder.title
    @State private var query = ""
    @State private var deleting: LocalTrack?
    /// The songs filtered and in order, worked out off the main actor when what they come
    /// from changes. Nil until the first time.
    @State private var sortedSongs: [LocalTrack]?

    private static let orders: [LibraryOrder] = [.title, .natural(.artist), .natural(.album), .natural(.added), .natural(.plays)]

    var body: some View {
        let songs = sortedSongs ?? []
        let context = PlayContext.songs(String(localized: "Your Songs"))
        // One list from the first frame, with the state as its row until there are songs, so
        // the filter field stays tucked under the title (see `libraryStateRow()`).
        List {
            if music.index.isEmpty || sortedSongs == nil {
                Group {
                    if sortedSongs != nil, music.hasScanned || !music.servers.servers.isEmpty {
                        LibraryEmptyYourMusic(title: String(localized: "No Songs Yet"))
                    } else {
                        LoadingRows(count: 10)
                            .padding(.horizontal, PlayMetrics.margin)
                    }
                }
                .libraryStateRow()
            } else if songs.isEmpty {
                LibraryNoMatches(query: query)
                    .libraryStateRow()
            } else {
                if query.isEmpty {
                    LibraryPlayButtons {
                        player.play(.local(songs.filter(music.isPlayable)), from: context)
                    } shuffle: {
                        player.play(.local(songs.filter(music.isPlayable)), from: context, shuffled: true)
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: PlayMetrics.margin, bottom: 12, trailing: PlayMetrics.margin))
                }
                ForEach(songs) { track in
                    Button {
                        let queue = songs.filter(music.isPlayable)
                        player.play(.local(queue, startingAt: queue.firstIndex(of: track) ?? 0), from: context)
                    } label: {
                        LocalTrackRow(track: track, isCurrent: player.current?.local?.id == track.id)
                    }
                    .buttonStyle(.plain)
                    .disabled(!music.isPlayable(track))
                    .libraryRowInsets()
                    .contextMenu { LocalTrackMenu(track: track, showsStats: true, onDelete: { deleting = $0 }) }
                    .swipeActions(edge: .leading) {
                        if music.isPlayable(track) {
                            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                                player.enqueue(.local([track]), next: true, title: track.title)
                            }
                            .tint(.indigo)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if music.isPlayable(track) {
                            Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") {
                                player.enqueue(.local([track]), next: false, title: track.title)
                            }
                            .tint(.orange)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, placement: .pageSearch(alwaysShown: false), prompt: "Filter Songs")
        .navigationTitle("Songs")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .libraryAction) {
                LibrarySortMenu(selection: $order, options: Self.orders) { $0.menuTitle }
            }
        }
        .confirmationDialog(
            deleteTitle(deleting?.title ?? ""),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Song", role: .destructive) { if let deleting { music.deleteFile(deleting) } }
        }
        // Plays matter only to that order, so a new play doesn't sort the others again.
        .task(id: LibraryPageKey(query: query, order: order, index: music.indexRevision, plays: order.field == .plays ? feed.builtRevision : nil)) {
            let (tracks, query, order) = (music.index.tracks, query, order)
            let facts = order.field == .plays ? feed.facts : [:]
            if sortedSongs != nil, !query.isEmpty {
                // Typing: wait for a pause rather than sort for every letter.
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
            }
            let next = await OffMainActor.run { Self.sorted(tracks, matching: query, by: order, facts: facts) }
            guard !Task.isCancelled else { return }
            sortedSongs = next
        }
    }

    nonisolated private static func sorted(_ tracks: [LocalTrack], matching query: String, by order: LibraryOrder, facts: [String: SongFacts]) -> [LocalTrack] {
        let matches = LibrarySort.filtered(tracks, matching: query) { LibrarySortKeys(title: $0.title, artist: $0.artist, album: $0.album ?? "") }
        return LibrarySort.sorted(matches, by: order) { track in
            LibrarySortKeys(
                title: track.title,
                artist: track.artist,
                album: track.album ?? "",
                added: track.addedAt == .distantPast ? nil : track.addedAt,
                duration: track.duration ?? 0,
                plays: order.field == .plays ? facts[track.identity]?.plays ?? 0 : 0
            )
        }
    }
}
#endif

extension LibrarySortKeys {
    /// An album of yours, sorted as Apple Music's are.
    nonisolated init(localAlbum album: LocalAlbum) {
        self.init(
            title: album.title,
            artist: album.artist,
            added: album.addedAt == .distantPast ? nil : album.addedAt,
            released: album.year.flatMap { DateComponents(calendar: .current, year: $0).date }
        )
    }
}

/// Every album in your music, as a grid, filtered as you type and in the order chosen.
struct LocalAlbumsPage: View {
    @Environment(YourMusic.self) private var music
    @AppStorage("yourMusicAlbumOrder") private var order = LibraryOrder.natural(.added)
    @State private var query = ""
    /// Filtered and in order off the main actor. Nil until the first time.
    @State private var sortedAlbums: [LocalAlbum]?

    private static let orders: [LibraryOrder] = [.natural(.added), .title, .natural(.artist), .natural(.year)]

    var body: some View {
        let albums = sortedAlbums ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                #if os(macOS)
                LibraryPageHeader(
                    title: String(localized: "Albums"),
                    subtitle: music.index.isEmpty ? nil : String(AttributedString(localized: "^[\(music.index.albums.count) album](inflect: true)").characters)
                )
                #endif
                if music.index.isEmpty || sortedAlbums == nil {
                    if sortedAlbums != nil, music.hasScanned || !music.servers.servers.isEmpty {
                        LibraryEmptyYourMusic(title: String(localized: "No Albums Yet"))
                    } else {
                        LibraryGridPlaceholder()
                    }
                } else if albums.isEmpty {
                    LibraryNoMatches(query: query)
                } else {
                    LibraryGrid {
                        ForEach(albums) { album in
                            LocalAlbumGridTile(album: album, subtitle: subtitle(of: album))
                        }
                    }
                }
            }
            .padding(.top, topPadding)
            .padding(.bottom, PlayMetrics.sectionSpacing)
        }
        .searchable(text: $query, placement: .pageSearch(alwaysShown: false), prompt: "Filter Albums")
        .libraryToolbar()
        .navigationTitle("Albums")
        #if os(macOS)
        .toolbar(removing: .title)
        #else
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar {
            ToolbarItem(placement: .libraryAction) {
                LibrarySortMenu(selection: $order, options: Self.orders) { $0.menuTitle }
            }
        }
        .task(id: LibraryPageKey(query: query, order: order, index: music.indexRevision)) {
            let (albums, query, order) = (music.index.albums, query, order)
            let next = await OffMainActor.run {
                LibrarySort.sorted(
                    LibrarySort.filtered(albums, matching: query) { LibrarySortKeys(localAlbum: $0) },
                    by: order
                ) { LibrarySortKeys(localAlbum: $0) }
            }
            guard !Task.isCancelled else { return }
            sortedAlbums = next
        }
    }

    private var topPadding: CGFloat {
        #if os(macOS)
        0
        #else
        8
        #endif
    }

    /// The artist, or the year too when the albums are in order of it.
    private func subtitle(of album: LocalAlbum) -> String {
        if order.field == .year, let year = album.year { return "\(album.artist) · \(String(year))" }
        return album.artist
    }
}

/// Every artist in your music, with their pictures and your plays: Music's Artists view on the
/// Mac, a list with an A to Z index on iPhone.
struct LocalArtistsPage: View {
    @Environment(YourMusic.self) private var music
    @Environment(PlayerModel.self) private var player
    @Environment(\.openPlayRoute) private var openPlayRoute
    #if DEBUG
    @Environment(AppModel.self) private var model
    #endif
    @State private var query = ""
    @State private var plays: [String: Int] = [:]
    /// Filtered and in order off the main actor. Nil until the first time.
    @State private var sortedArtists: [LocalArtist]?
    #if os(macOS)
    @State private var selection: LocalArtist.ID?
    #endif

    var body: some View {
        let artists = sortedArtists ?? []
        Group {
            #if os(macOS)
            VStack(spacing: 0) {
                LibraryPageHeader(
                    title: String(localized: "Artists"),
                    subtitle: music.index.isEmpty ? nil : String(AttributedString(localized: "^[\(music.index.artists.count) artist](inflect: true)").characters)
                )
                if music.index.isEmpty || artists.isEmpty {
                    state
                } else {
                    list(artists)
                }
            }
            #else
            // One list from the first frame, with the state as its row until there are
            // artists, so the filter field stays tucked under the title (see `libraryStateRow()`).
            List {
                if music.index.isEmpty || artists.isEmpty {
                    state.libraryStateRow()
                } else {
                    list(artists)
                }
            }
            .listStyle(.plain)
            .listSectionIndexVisibility(.visible)
            #endif
        }
        .artistPlays(into: $plays)
        .task(id: LibraryPageKey(query: query, order: .title, index: music.indexRevision)) {
            let (artists, query) = (music.index.artists, query)
            let next = await OffMainActor.run {
                LibrarySort.sorted(
                    LibrarySort.filtered(artists, matching: query) { LibrarySortKeys(title: $0.name) },
                    by: .title
                ) { LibrarySortKeys(title: $0.name) }
            }
            guard !Task.isCancelled else { return }
            sortedArtists = next
        }
        #if DEBUG
        .task(id: music.index.artists.count) { LibraryLaunch.push(in: model) }
        #endif
        .searchable(text: $query, placement: .pageSearch(alwaysShown: false), prompt: "Filter Artists")
        .libraryToolbar()
        .navigationTitle("Artists")
        #if os(macOS)
        .toolbar(removing: .title)
        #else
        .navigationBarTitleDisplayMode(.large)
        #endif
    }

    /// Loading, an empty library, or nothing matching the filter.
    @ViewBuilder
    private var state: some View {
        if !music.index.isEmpty, sortedArtists != nil {
            LibraryNoMatches(query: query)
                .frame(maxHeight: .infinity, alignment: .top)
        } else if music.index.isEmpty, music.hasScanned || !music.servers.servers.isEmpty {
            LibraryEmptyYourMusic(title: String(localized: "No Artists Yet"))
        } else {
            #if os(macOS)
            LibraryArtistSplitPlaceholder()
            #else
            LibraryArtistRowsPlaceholder()
            #endif
        }
    }

    @ViewBuilder
    private func list(_ artists: [LocalArtist]) -> some View {
        #if os(macOS)
        LibraryArtistSplit(
            artists: artists,
            selection: $selection,
            name: \.name,
            picture: picture(of:),
            open: { openPlayRoute(.localArtist($0.id)) }
        ) { artist in
            let playable = artist.tracks.filter(music.isPlayable)
            LibraryArtistDetail(
                name: artist.name,
                picture: picture(of: artist),
                facts: facts(of: artist),
                shuffle: playable.isEmpty ? nil : {
                    player.play(.local(playable), from: PlayContext(kind: .artist, title: artist.name), shuffled: true)
                },
                open: { openPlayRoute(.localArtist(artist.id)) }
            ) {
                ForEach(artist.albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }) { album in
                    LocalAlbumGridTile(album: album, subtitle: album.year.map(String.init) ?? album.artist)
                }
            }
        } menu: { artist in
            LocalArtistMenu(artist: artist)
        }
        #else
        LibraryArtistIndexSections(artists: artists, name: \.name) { artist in
            NavigationLink(value: PlayRoute.localArtist(artist.id)) {
                LibraryArtistRow(
                    name: artist.name,
                    picture: picture(of: artist),
                    plays: plays[StatsCalculator.folded(artist.name)]
                )
            }
            .contextMenu { LocalArtistMenu(artist: artist) }
        }
        #endif
    }

    private func picture(of artist: LocalArtist) -> CoverArt? {
        music.artistPicture(for: artist)
    }

    /// "3 albums · 212 plays".
    private func facts(of artist: LocalArtist) -> String {
        var parts = [String(AttributedString(localized: "^[\(artist.albums.count) album](inflect: true)").characters)]
        if let count = plays[StatsCalculator.folded(artist.name)], count > 0 { parts.append(PlayCountText.short(count)) }
        return parts.joined(separator: " · ")
    }
}

/// The albums added to your music most lately, newest first, as a grid.
struct LocalRecentlyAddedPage: View {
    @Environment(YourMusic.self) private var music
    @State private var query = ""

    var body: some View {
        let albums = Array(LibrarySort.filtered(music.index.recentlyAdded, matching: query) { LibrarySortKeys(localAlbum: $0) }.prefix(LibraryRecentlyAdded.limit))
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                #if os(macOS)
                LibraryPageHeader(title: String(localized: "Recently Added"), subtitle: nil)
                #endif
                if music.index.isEmpty {
                    if music.hasScanned || !music.servers.servers.isEmpty {
                        LibraryEmptyYourMusic(title: String(localized: "Nothing Added Yet"))
                    } else {
                        LibraryGridPlaceholder()
                    }
                } else if albums.isEmpty {
                    LibraryNoMatches(query: query)
                } else {
                    LibraryGrid {
                        ForEach(albums) { album in
                            LocalAlbumGridTile(album: album)
                        }
                    }
                }
            }
            .padding(.bottom, PlayMetrics.sectionSpacing)
        }
        .searchable(text: $query, placement: .pageSearch(alwaysShown: false), prompt: "Filter Recently Added")
        .libraryToolbar()
        .navigationTitle("Recently Added")
        #if os(macOS)
        .toolbar(removing: .title)
        #endif
    }
}

/// "Delete “Wildflowers” from This iPhone?", or from This Mac.
private func deleteTitle(_ title: String) -> String {
    #if os(macOS)
    String(localized: "Delete \u{201C}\(title)\u{201D} from This Mac?")
    #else
    String(localized: "Delete \u{201C}\(title)\u{201D} from This iPhone?")
    #endif
}

/// What a library page's filtered, ordered list is worked out from.
private struct LibraryPageKey: Equatable {
    let query: String
    let order: LibraryOrder
    let index: Int
    var plays: Int?
}
