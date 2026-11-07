import SwiftUI
import MusicKit
import TracksCore

/// Albums and playlists as they came into the Apple Music library, newest first.
enum LibraryRecentlyAdded {
    /// As many as a Recently Added page shows: Music's goes back a few months, not forever.
    static let limit = 200

    enum Item: Identifiable {
        case album(Album)
        case playlist(Playlist)

        var id: MusicItemID {
            switch self {
            case .album(let album): album.id
            case .playlist(let playlist): playlist.id
            }
        }

        var added: Date? {
            switch self {
            case .album(let album): LibrarySortKeys(album: album).added
            case .playlist(let playlist): LibrarySortKeys(playlist: playlist).added
            }
        }
    }

    /// Two lists already newest first, woven into one, newest first, up to `limit`.
    static func merged(albums: [Album], playlists: [Playlist], limit: Int) -> [Item] {
        var result: [Item] = []
        var (album, playlist) = (albums.startIndex, playlists.startIndex)
        while result.count < limit, album < albums.endIndex || playlist < playlists.endIndex {
            let nextAlbum = album < albums.endIndex ? Item.album(albums[album]) : nil
            let nextPlaylist = playlist < playlists.endIndex ? Item.playlist(playlists[playlist]) : nil
            if let nextAlbum, nextPlaylist == nil || (nextAlbum.added ?? .distantPast) >= (nextPlaylist?.added ?? .distantPast) {
                result.append(nextAlbum)
                album += 1
            } else if let nextPlaylist {
                result.append(nextPlaylist)
                playlist += 1
            }
        }
        return result
    }
}

/// A recently added album or playlist in a grid.
struct LibraryRecentTile: View {
    let item: LibraryRecentlyAdded.Item

    var body: some View {
        switch item {
        case .album(let album): LibraryAlbumTile(album: album)
        case .playlist(let playlist): LibraryPlaylistTile(playlist: playlist, isAmongAlbums: true)
        }
    }
}

#if os(macOS)
/// Recently Added on the Mac, as in Music's sidebar: every album and playlist that came into
/// the library lately, newest first, as a grid of covers.
struct LibraryRecentlyAddedPage: View {
    @State private var query = ""
    @State private var albums = LibraryPager<Album>()
    @State private var playlists = LibraryPager<Playlist>()

    var body: some View {
        LibraryAccessGate(title: String(localized: "Recently Added")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    LibraryPageHeader(title: String(localized: "Recently Added"), subtitle: nil)
                    let items = LibraryRecentlyAdded.merged(albums: albums.items, playlists: playlists.items, limit: LibraryRecentlyAdded.limit)
                    switch albums.phase {
                    case .loading:
                        LibraryGridPlaceholder()
                    case .failed:
                        LibraryLoadFailed { await albums.retry(query: query) }
                    case .empty, .ready:
                        if !items.isEmpty {
                            LibraryGrid {
                                ForEach(items) { item in
                                    LibraryRecentTile(item: item)
                                }
                            }
                        } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
                            LibraryEmptyAppleMusic(section: .albums)
                        } else {
                            LibraryNoMatches(query: query)
                        }
                    }
                }
                .padding(.bottom, PlayMetrics.sectionSpacing)
            }
            .loads(albums, query: query, order: .natural(.added)) { LibrarySortKeys(album: $0) }
            .loads(playlists, query: query, order: .natural(.added)) { LibrarySortKeys(playlist: $0) }
        }
        .navigationTitle("Recently Added")
        .toolbar(removing: .title)
        .searchable(text: $query, placement: .pageSearch(alwaysShown: false), prompt: Text("Filter Recently Added"))
        .libraryToolbar()
    }
}
#endif

#if os(iOS)
/// The library on Play, as Music's Library tab begins: its parts as rows, then what came into
/// it lately as a two-column grid.
struct LibraryOverview: View {
    @State private var albums = LibraryPager<Album>()
    @State private var playlists = LibraryPager<Playlist>()
    @Environment(AppModel.self) private var model

    /// Three rows of two: enough to see what's new without taking over Play.
    private static let recentCount = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Library")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                categories
            }
            if isOpen {
                recent
                    .loads(albums, query: "", order: .natural(.added), server: LibraryServerSort.albums(.natural(.added))) { LibrarySortKeys(album: $0) }
                    .loads(playlists, query: "", order: .natural(.added), server: LibraryServerSort.playlists(.natural(.added))) { LibrarySortKeys(playlist: $0) }
            }
        }
        #if DEBUG
        .task { LibraryLaunch.push(in: model) }
        #endif
    }

    private var categories: some View {
        VStack(spacing: 0) {
            ForEach(Self.sections) { section in
                NavigationLink(value: PlayRoute.library(section)) {
                    HStack(spacing: 14) {
                        Image(systemName: section.symbol)
                            .font(.body)
                            .foregroundStyle(.tint)
                            .frame(width: 28)
                        Text(section.title)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    .contentShape(.rect)
                }
                .buttonStyle(RowButtonStyle())
                if section != Self.sections.last {
                    Divider().padding(.leading, 58)
                }
            }
        }
        .background(Color.cardFill)
        .clipShape(.rect(cornerRadius: 16, style: .continuous))
    }

    /// Music's order: Playlists, Artists, Albums, Songs.
    private static let sections: [LibrarySection] = [.playlists, .artists, .albums, .songs]

    /// Recently Added under the rows, once there's something in it. A frame of its own even
    /// while empty, so the library keeps being read.
    private var recent: some View {
        let items = LibraryRecentlyAdded.merged(albums: albums.items, playlists: playlists.items, limit: Self.recentCount)
        return VStack(alignment: .leading, spacing: 12) {
            if albums.phase == .loading || !items.isEmpty {
                Text("Recently Added")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                if albums.phase == .loading {
                    LibraryGridPlaceholder(count: Self.recentCount, margin: 0)
                } else {
                    LibraryGrid(margin: 0) {
                        ForEach(items) { item in
                            LibraryRecentTile(item: item)
                        }
                    }
                }
            }
        }
        .padding(.top, albums.phase == .loading || !items.isEmpty ? PlayMetrics.sectionSpacing : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isOpen: Bool {
        if LibraryDemo.isOn { return true }
        return model.musicAuthorization == .authorized && !model.isShowingSampleData
    }
}
#endif
