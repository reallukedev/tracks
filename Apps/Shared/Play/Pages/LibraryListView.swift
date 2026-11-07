import SwiftUI
import MusicKit
import TracksCore

/// One part of the Apple Music library: playlists, albums, artists or songs, each filtered as
/// you type and in the order chosen in the toolbar. On the Mac albums and playlists are grids
/// of covers, artists a list beside the chosen one's albums, and songs a table; on iPhone a
/// two-column grid of albums and lists with an A to Z index for the rest.
struct LibraryListView: View {
    let section: LibrarySection
    @State private var query = ""

    var body: some View {
        #if DEBUG && os(iOS)
        if LibraryLaunch.showsOverview {
            ScrollView {
                LibraryOverview()
                    .padding(.horizontal, PlayMetrics.margin)
            }
            .navigationTitle("Play")
        } else {
            page
        }
        #else
        page
        #endif
    }

    private var page: some View {
        LibraryAccessGate(title: section.title) {
            switch section {
            case .playlists: LibraryPlaylistsPage(query: query)
            case .albums: LibraryAlbumsPage(query: query)
            case .artists: LibraryArtistsPage(query: query)
            case .songs:
                #if os(macOS)
                LibrarySongsTablePage(query: query)
                #else
                LibrarySongsList(query: query)
                #endif
            }
        }
        .navigationTitle(section.title)
        #if os(macOS)
        .toolbar(removing: .title)
        #else
        .navigationBarTitleDisplayMode(.large)
        #endif
        .searchable(text: $query, placement: .pageSearch(alwaysShown: false), prompt: Text("Filter \(section.title)"))
        .libraryToolbar()
    }
}

// MARK: - Orders

/// Apple Music's own sort for an order, which iPhone asks for so a big library starts at the
/// top without reading all of it. Never on the Mac, where a sorted library request can raise
/// an exception that ends the app: there the order is kept in Swift.
enum LibraryServerSort {
    static func albums(_ order: LibraryOrder) -> ((inout MusicLibraryRequest<Album>) -> Void)? {
        #if os(iOS)
        { request in
            switch order.field {
            case .artist: request.sort(by: \.artistName, ascending: order.ascending)
            case .added: request.sort(by: \.libraryAddedDate, ascending: order.ascending)
            case .played: request.sort(by: \.lastPlayedDate, ascending: order.ascending)
            case .year: request.sort(by: \.releaseDate, ascending: order.ascending)
            case .title, .album, .time, .plays: request.sort(by: \.title, ascending: order.ascending)
            }
        }
        #else
        nil
        #endif
    }

    static func playlists(_ order: LibraryOrder) -> ((inout MusicLibraryRequest<Playlist>) -> Void)? {
        #if os(iOS)
        { request in
            switch order.field {
            case .added: request.sort(by: \.libraryAddedDate, ascending: order.ascending)
            case .played: request.sort(by: \.lastPlayedDate, ascending: order.ascending)
            default: request.sort(by: \.name, ascending: order.ascending)
            }
        }
        #else
        nil
        #endif
    }

    static func songs(_ order: LibraryOrder) -> ((inout MusicLibraryRequest<Song>) -> Void)? {
        #if os(iOS)
        { request in
            switch order.field {
            case .artist: request.sort(by: \.artistName, ascending: order.ascending)
            case .album: request.sort(by: \.albumTitle, ascending: order.ascending)
            case .time: request.sort(by: \.duration, ascending: order.ascending)
            case .added: request.sort(by: \.libraryAddedDate, ascending: order.ascending)
            case .played: request.sort(by: \.lastPlayedDate, ascending: order.ascending)
            case .title, .plays, .year: request.sort(by: \.title, ascending: order.ascending)
            }
        }
        #else
        nil
        #endif
    }
}

extension LibraryOrder {
    /// What the order is called in a Sort By menu.
    var menuTitle: LocalizedStringKey {
        switch field {
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .time: "Time"
        case .plays: "Most Played"
        case .added: "Recently Added"
        case .played: "Recently Played"
        case .year: "Year"
        }
    }

    static let albumOrders: [LibraryOrder] = [.natural(.added), .natural(.played), .title, .natural(.artist), .natural(.year)]
    static let playlistOrders: [LibraryOrder] = [.natural(.played), .natural(.added), .title]
}

extension View {
    /// On the Mac, sends a library page's toolbar items and filter field to the trailing edge,
    /// where Music keeps them, rather than beside the sidebar. Nothing on iPhone.
    func libraryToolbar() -> some View {
        #if os(macOS)
        toolbar { ToolbarSpacer(.flexible) }
        #else
        self
        #endif
    }
}

extension ToolbarItemPlacement {
    /// Where a library page's Sort By and More go: trailing, beside the filter field, on the
    /// Mac (whose primary action sits at the leading edge); the primary action on iPhone.
    static var libraryAction: ToolbarItemPlacement {
        #if os(macOS)
        .automatic
        #else
        .primaryAction
        #endif
    }
}

/// A toolbar menu choosing the order of a library page.
struct LibrarySortMenu<Option: Hashable>: View {
    @Binding var selection: Option
    let options: [Option]
    let title: (Option) -> LocalizedStringKey

    var body: some View {
        Menu("Sort By", systemImage: "arrow.up.arrow.down") {
            Picker("Sort By", selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(title(option)).tag(option)
                }
            }
            .pickerStyle(.inline)
        }
        .help("Sort By")
    }
}

// MARK: - Playlists

/// Your playlists: a grid of covers on the Mac, rows with their covers on iPhone.
private struct LibraryPlaylistsPage: View {
    let query: String
    @AppStorage("libraryPlaylistOrder") private var order = LibraryOrder.natural(.played)
    @State private var pager = LibraryPager<Playlist>()
    @Environment(PlayerModel.self) private var player

    var body: some View {
        content
            .toolbar {
                ToolbarItem(placement: .libraryAction) {
                    LibrarySortMenu(selection: $order, options: LibraryOrder.playlistOrders) { order in
                        order.field == .title ? "Name" : order.menuTitle
                    }
                }
            }
            .loads(pager, query: query, order: order, server: LibraryServerSort.playlists(order)) { LibrarySortKeys(playlist: $0) }
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LibraryPageHeader(title: String(localized: "Playlists"), subtitle: pager.count(Self.count))
                LibraryPagerContent(pager: pager, query: query, section: .playlists) {
                    LibraryGridPlaceholder()
                } content: {
                    LibraryGrid {
                        ForEach(pager.items) { playlist in
                            LibraryPlaylistTile(playlist: playlist)
                        }
                    }
                }
            }
            .padding(.bottom, PlayMetrics.sectionSpacing)
        }
        #else
        LibraryPagerContent(pager: pager, query: query, section: .playlists, isList: true) {
            LoadingRows(count: 10)
                .padding(.horizontal, PlayMetrics.margin)
        } content: {
            ForEach(pager.items) { playlist in
                NavigationLink(value: PlayRoute.playlist(playlist)) {
                    LibraryPlaylistRow(playlist: playlist)
                }
                .navigationLinkIndicatorVisibility(.hidden)
                .libraryRowInsets()
                .contextMenu { FeedItemMenu(item: FeedItem(playlist: playlist)) }
                .swipeActions(edge: .leading) {
                    Button("Play", systemImage: "play.fill") { play(playlist) }
                        .tint(.accentColor)
                }
                .task { await pager.loadMore(after: playlist) }
            }
        }
        #endif
    }

    private func play(_ playlist: Playlist) {
        player.play(.playlist(playlist), from: PlayContext(kind: .playlist, title: playlist.name))
    }

    private static func count(_ count: Int) -> String {
        String(AttributedString(localized: "^[\(count) playlist](inflect: true)").characters)
    }
}

/// A playlist in a grid: its cover, its name, and who made it, or that it's a playlist where
/// it stands among albums.
struct LibraryPlaylistTile: View {
    let playlist: Playlist
    var side: CGFloat?
    var isAmongAlbums = false
    @Environment(PlayerModel.self) private var player

    var body: some View {
        LibraryCoverTile(
            title: playlist.name,
            subtitle: playlist.curatorName ?? (isAmongAlbums ? String(localized: "Playlist") : nil),
            route: .playlist(playlist),
            play: { player.play(.playlist(playlist), from: PlayContext(kind: .playlist, title: playlist.name)) },
            side: side
        ) { side in
            LibraryCover(cover: playlist.libraryCover, side: side)
        } menu: {
            FeedItemMenu(item: FeedItem(playlist: playlist))
        }
    }
}

#if os(iOS)
/// A playlist in a list, as Music lists them: its cover, its name, and who made it.
private struct LibraryPlaylistRow: View {
    let playlist: Playlist
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 56

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(cover: playlist.libraryCover, size: min(side, 80))
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .lineLimit(2)
                if let curator = playlist.curatorName {
                    Text(curator)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
        .accessibilityElement(children: .combine)
    }
}
#endif

extension Playlist {
    /// Its artwork, or a cover drawn from its name.
    var libraryCover: CoverArt { artwork.map(CoverArt.artwork) ?? .url(nil, seed: name) }
}

extension Album {
    var libraryCover: CoverArt { artwork.map(CoverArt.artwork) ?? .url(nil, seed: title) }
}

/// A cover at a side, or filling its grid cell when there's no side.
struct LibraryCover: View {
    let cover: CoverArt
    let side: CGFloat?

    var body: some View {
        if let side {
            CoverImage(cover: cover, size: side)
        } else {
            CoverImageFill(cover: cover)
        }
    }
}

// MARK: - Albums

/// Your albums as a grid of covers, on both platforms.
private struct LibraryAlbumsPage: View {
    let query: String
    @AppStorage("libraryAlbumOrder") private var order = LibraryOrder.natural(.added)
    @State private var pager = LibraryPager<Album>()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                #if os(macOS)
                LibraryPageHeader(title: String(localized: "Albums"), subtitle: pager.count(Self.count))
                #endif
                LibraryPagerContent(pager: pager, query: query, section: .albums) {
                    LibraryGridPlaceholder()
                } content: {
                    LibraryGrid {
                        ForEach(pager.items) { album in
                            LibraryAlbumTile(album: album, showsYear: order.field == .year)
                                .task { await pager.loadMore(after: album) }
                        }
                    }
                }
            }
            .padding(.top, topPadding)
            .padding(.bottom, PlayMetrics.sectionSpacing)
        }
        .toolbar {
            ToolbarItem(placement: .libraryAction) {
                LibrarySortMenu(selection: $order, options: LibraryOrder.albumOrders) { $0.menuTitle }
            }
        }
        .loads(pager, query: query, order: order, server: LibraryServerSort.albums(order)) { LibrarySortKeys(album: $0) }
    }

    private var topPadding: CGFloat {
        #if os(macOS)
        0
        #else
        8
        #endif
    }

    private static func count(_ count: Int) -> String {
        String(AttributedString(localized: "^[\(count) album](inflect: true)").characters)
    }
}

/// An album in a grid: its cover, its title and its artist, with the year when the grid is in
/// order of it.
struct LibraryAlbumTile: View {
    let album: Album
    var showsYear = false
    var side: CGFloat?
    @Environment(PlayerModel.self) private var player

    var body: some View {
        LibraryCoverTile(
            title: album.title,
            subtitle: subtitle,
            route: .album(album),
            play: { player.play(.album(album), from: PlayContext(kind: .album, title: album.title)) },
            side: side
        ) { side in
            LibraryCover(cover: album.libraryCover, side: side)
        } menu: {
            FeedItemMenu(item: FeedItem(album: album))
        }
    }

    private var subtitle: String {
        guard showsYear, let released = album.releaseDate else { return album.artistName }
        return "\(album.artistName) · \(released.formatted(.dateTime.year()))"
    }
}

/// A cover that fills its grid cell, square.
struct CoverImageFill: View {
    let cover: CoverArt

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    CoverImage(cover: cover, size: proxy.size.width)
                }
            }
    }
}

// MARK: - Artists

/// What can be done with an artist from a library list.
struct LibraryArtistMenu: View {
    let name: String
    var artist: Artist?
    @Environment(PlayerModel.self) private var player
    @Environment(AppModel.self) private var model
    @Environment(\.openPlayRoute) private var openPlayRoute

    var body: some View {
        if let artist, model.musicSource == .appleMusic, !player.isDemo {
            Button("Create Station", systemImage: "dot.radiowaves.left.and.right") { player.playStation(from: artist) }
            Divider()
        }
        Button("Your Stats", systemImage: "chart.bar.xaxis") {
            openPlayRoute(.stats(.artist(StatsCalculator.folded(name))))
        }
        AddToLidarrButton(artistName: name)
        if let url = artist?.url {
            ShareLink(item: url) { Label("Share Artist", systemImage: "square.and.arrow.up") }
        }
        Divider()
        BlockArtistButton(artist: name)
    }
}
