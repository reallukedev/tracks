import SwiftUI
import MusicKit
import TracksCore

/// Your own Apple Music on someone else's SharePlay page, as Music's Library has it: what you
/// played lately, your playlists, and what you added lately, each song ready to add to their
/// Up Next. Only once you've allowed Apple Music, which is optional: search works without a
/// library.
struct SharePlayLibraryLinks: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SearchSectionTitle("Your Library")
            VStack(spacing: 0) {
                row(.recentlyPlayed)
                Divider().padding(.leading, 40)
                row(.playlists)
                Divider().padding(.leading, 40)
                row(.recentlyAdded)
            }
        }
    }

    private func row(_ page: SharePlayLibraryPage) -> some View {
        NavigationLink(value: page) {
            HStack(spacing: 12) {
                Image(systemName: page.symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                Text(page.title)
                    .font(.title3)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 11)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// A page of your library on the SharePlay page.
enum SharePlayLibraryPage: Hashable {
    case recentlyPlayed
    case playlists
    case recentlyAdded
    case playlist(SharePlayLibraryPlaylist)

    var title: String {
        switch self {
        case .recentlyPlayed: String(localized: "Recently Played")
        case .playlists: String(localized: "Playlists")
        case .recentlyAdded: String(localized: "Recently Added")
        case .playlist(let playlist): playlist.name
        }
    }

    var symbol: String {
        switch self {
        case .recentlyPlayed: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .playlists: "music.note.list"
        case .recentlyAdded: "square.stack"
        case .playlist: "music.note.list"
        }
    }
}

/// One of your playlists: from Apple Music, or sample data's.
enum SharePlayLibraryPlaylist: Hashable {
    case appleMusic(Playlist)
    case sample(name: String, songs: [SharePlaySong])

    var name: String {
        switch self {
        case .appleMusic(let playlist): playlist.name
        case .sample(let name, _): name
        }
    }

    var cover: CoverArt {
        switch self {
        case .appleMusic(let playlist): playlist.artwork.map(CoverArt.artwork) ?? .url(nil, seed: playlist.name)
        case .sample(let name, let songs): .url(songs.first?.artworkURL, seed: name)
        }
    }
}

/// A page of your library: songs to add, or your playlists to open.
struct SharePlayLibraryPageView: View {
    let page: SharePlayLibraryPage
    @State private var songs: [SharePlaySong]?
    @State private var playlists: [SharePlayLibraryPlaylist]?
    @State private var failed = false
    private var sharePlay = SharePlayController.shared

    init(page: SharePlayLibraryPage) {
        self.page = page
    }

    var body: some View {
        content
            .navigationTitle(page.title)
            .navigationBarTitleDisplayMode(.inline)
            .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if failed {
            ContentUnavailableView {
                Label("Couldn't Load Your Library", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try Again") {
                    failed = false
                    Task { await load() }
                }
            }
        } else if case .playlists = page {
            playlistList
        } else {
            songList
        }
    }

    @ViewBuilder
    private var songList: some View {
        if let songs, songs.isEmpty {
            ContentUnavailableView(emptyTitle, systemImage: page.symbol, description: Text(emptyMessage))
        } else if let songs {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if sharePlay.guest.snapshot?.isStation == true {
                        SharePlayNotice(text: "A station is playing on their iPhone, so there's no queue to add to. You can add songs once they play something else.", systemImage: "dot.radiowaves.left.and.right")
                            .padding(.bottom, 10)
                    }
                    ForEach(songs, id: \.catalogID) { song in
                        SharePlayResultRow(song: song)
                    }
                }
                .padding(.horizontal, PlayMetrics.margin)
                .padding(.vertical, 12)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var playlistList: some View {
        if let playlists, playlists.isEmpty {
            ContentUnavailableView("No Playlists", systemImage: "music.note.list", description: Text("Playlists you make or add in Apple Music show up here."))
        } else if let playlists {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(playlists, id: \.self) { playlist in
                        NavigationLink(value: SharePlayLibraryPage.playlist(playlist)) {
                            HStack(spacing: 12) {
                                CoverImage(cover: playlist.cover, size: 56)
                                Text(playlist.name)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.forward")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 6)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, PlayMetrics.margin)
                .padding(.vertical, 12)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyTitle: LocalizedStringKey {
        switch page {
        case .recentlyPlayed: "Nothing Played Yet"
        case .playlist: "No Songs to Add"
        default: "No Songs"
        }
    }

    private var emptyMessage: LocalizedStringKey {
        switch page {
        case .recentlyPlayed: "Songs you play in Apple Music show up here."
        case .playlist: "None of this playlist's songs are in Apple Music's catalog, so their iPhone can't play them."
        default: "Songs you add to your Apple Music library show up here."
        }
    }

    private func load() async {
        guard songs == nil, playlists == nil else { return }
        #if DEBUG
        if let demo = sharePlay.demo {
            switch page {
            case .recentlyPlayed: songs = demo.library(0)
            case .recentlyAdded: songs = demo.library(2)
            case .playlists: playlists = demo.playlists.map { .sample(name: $0.name, songs: $0.songs) }
            case .playlist(let playlist):
                if case .sample(_, let found) = playlist { songs = found }
            }
            return
        }
        #endif
        do {
            switch page {
            case .recentlyPlayed:
                var request = MusicRecentlyPlayedRequest<Song>()
                request.limit = 30
                songs = Self.addable(try await request.response().items)
            case .recentlyAdded:
                var request = MusicLibraryRequest<Song>()
                request.sort(by: \.libraryAddedDate, ascending: false)
                request.limit = 100
                songs = Self.addable(try await request.response().items)
            case .playlists:
                var request = MusicLibraryRequest<Playlist>()
                request.sort(by: \.lastPlayedDate, ascending: false)
                playlists = try await request.response().items.map { .appleMusic($0) }
            case .playlist(let playlist):
                guard case .appleMusic(let found) = playlist else { return }
                let tracks = try await found.with([.tracks]).tracks ?? []
                songs = Self.addable(tracks.compactMap { if case .song(let song) = $0 { song } else { nil } })
            }
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
    }

    /// Songs their iPhone can find: each by its Apple Music catalog id, once. A song only in
    /// this library (one uploaded, say) has none, and is left out.
    private static func addable(_ songs: some Sequence<Song>) -> [SharePlaySong] {
        var seen = Set<String>()
        return songs.compactMap { song in
            guard let found = SharePlaySong(librarySong: song), seen.insert(found.identity).inserted else { return nil }
            return found
        }
    }
}

extension SharePlaySong {
    /// A song from your library or history, sent by its catalog id: the host can't see your
    /// library, and finds songs in Apple Music's catalog. Nil for one that isn't in it.
    init?(librarySong song: Song) {
        guard let catalogID = Self.catalogID(of: song) else { return nil }
        self.init(
            catalogID: catalogID,
            title: song.title,
            artistName: song.artistName,
            albumTitle: song.albumTitle,
            artworkURL: song.artwork.flatMap { CoverImage.loadableURL(of: $0, pixels: 300) }?.absoluteString,
            isExplicit: song.isExplicit
        )
    }

    /// A library song's catalog id sits in its play parameters, which MusicKit only hands over
    /// encoded.
    private static func catalogID(of song: Song) -> String? {
        let id = song.id.rawValue
        if MusicItemIdentity.isCatalogID(id) { return id }
        guard let parameters = song.playParameters,
              let data = try? JSONEncoder().encode(parameters),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let catalogID = object["catalogId"] as? String,
              MusicItemIdentity.isCatalogID(catalogID)
        else { return nil }
        return catalogID
    }
}
