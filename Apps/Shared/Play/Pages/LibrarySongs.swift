import SwiftUI
import MusicKit
import TracksCore

/// A song in a library's table: the same columns for Apple Music and your own music.
nonisolated struct LibrarySongRow: Identifiable, Sendable {
    let id: String
    let title: String
    let artist: String
    let album: String
    /// Seconds; zero when it isn't known.
    let duration: TimeInterval
    /// Your plays, from Tracks’ history.
    let plays: Int
    let added: Date
    let cover: CoverArt
    var isExplicit = false
    var isPlayable = true
    /// The history's key for it, to know it's the one playing.
    let identity: String

    /// What the table's columns sort by.
    var sortKeys: LibrarySortKeys {
        LibrarySortKeys(
            title: title,
            artist: artist,
            album: album,
            added: added == .distantPast ? nil : added,
            duration: duration,
            plays: plays
        )
    }
}

extension LibrarySongRow {
    nonisolated init(song: Song, plays: Int) {
        self.init(
            id: song.id.rawValue,
            title: song.title,
            artist: song.artistName,
            album: song.albumTitle ?? "",
            duration: song.duration ?? 0,
            plays: plays,
            added: song.libraryAddedDate ?? LibraryDemo.added(song.id) ?? .distantPast,
            cover: song.artwork.map(CoverArt.artwork) ?? .url(nil, seed: song.albumTitle ?? song.title),
            isExplicit: song.isExplicit,
            identity: HistoryImport.key(title: song.title, artistName: song.artistName)
        )
    }

    init(track: LocalTrack, plays: Int, isPlayable: Bool, artworkURL: String?) {
        self.init(
            id: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album ?? "",
            duration: track.duration ?? 0,
            plays: plays,
            added: track.addedAt,
            cover: .url(artworkURL, seed: track.album ?? track.title),
            isPlayable: isPlayable,
            identity: track.identity
        )
    }
}

extension LibraryOrder {
    /// The orders a list of songs offers on iPhone, where there's no table to click.
    static let songOrders: [LibraryOrder] = [.title, .natural(.artist), .natural(.album), .natural(.added), .natural(.played)]

    /// The same order as a table's sort descriptor.
    var comparator: KeyPathComparator<LibrarySongRow> {
        let order: SortOrder = ascending ? .forward : .reverse
        return switch field {
        case .artist: KeyPathComparator(\LibrarySongRow.artist, order: order)
        case .album: KeyPathComparator(\LibrarySongRow.album, order: order)
        case .time: KeyPathComparator(\LibrarySongRow.duration, order: order)
        case .plays: KeyPathComparator(\LibrarySongRow.plays, order: order)
        case .added, .played, .year: KeyPathComparator(\LibrarySongRow.added, order: order)
        case .title: KeyPathComparator(\LibrarySongRow.title, order: order)
        }
    }

    /// The order a table's clicked column asks for.
    init?(_ comparator: KeyPathComparator<LibrarySongRow>) {
        let fields: [(PartialKeyPath<LibrarySongRow>, Field)] = [
            (\LibrarySongRow.title, .title), (\LibrarySongRow.artist, .artist), (\LibrarySongRow.album, .album),
            (\LibrarySongRow.duration, .time), (\LibrarySongRow.plays, .plays), (\LibrarySongRow.added, .added),
        ]
        guard let field = fields.first(where: { $0.0 == comparator.keyPath })?.1 else { return nil }
        self.init(field, ascending: comparator.order == .forward)
    }

    /// Rows in this order, as Music sorts names.
    func sorted(_ rows: [LibrarySongRow]) -> [LibrarySongRow] {
        LibrarySort.sorted(rows, by: self) { $0.sortKeys }
    }
}

/// Where a library table's songs come from, so a drag says how to find them again.
nonisolated enum LibrarySongSource {
    case appleMusic, yourMusic
}

extension SongDrag {
    /// Rows dragged out of a library table, onto Up Next or the player, or into another app
    /// as text.
    init(rows: [LibrarySongRow], from source: LibrarySongSource) {
        self.init(songs: rows.map { row in
            SongDrag.Song(
                title: row.title,
                artistName: row.artist,
                albumTitle: row.album.isEmpty ? nil : row.album,
                libraryID: source == .appleMusic ? row.id : nil,
                localID: source == .yourMusic ? row.id : nil
            )
        })
    }
}

nonisolated extension SongDrag.Song {
    /// An Apple Music song by its id: the catalog's, or the library's ("i." and the like).
    init(appleMusicID id: String, title: String, artistName: String, albumTitle: String?) {
        let isCatalog = id.allSatisfy(\.isNumber)
        self.init(songID: isCatalog ? id : "", title: title, artistName: artistName, albumTitle: albumTitle, libraryID: isCatalog ? nil : id)
    }
}

extension SongDrag {
    /// An Apple Music song, dragged on its own.
    init(_ song: MusicKit.Song) {
        self.init(songs: [SongDrag.Song(appleMusicID: song.id.rawValue, title: song.title, artistName: song.artistName, albumTitle: song.albumTitle)])
    }
}

/// "3:46", as a song's time reads in a table.
enum LibraryTime {
    static func text(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "" }
        return Duration.seconds(seconds.rounded()).formatted(.time(pattern: seconds >= 3_600 ? .hourMinuteSecond : .minuteSecond))
    }
}

#if os(iOS)
/// The Apple Music library's songs on iPhone: Play and Shuffle across the top, then every song
/// with its cover and your plays. Swipe right to play one next, left to play it last.
struct LibrarySongsList: View {
    let query: String
    @AppStorage(PlayPreferences.allowsExplicitKey) private var allowsExplicit = true
    @AppStorage("librarySongOrder") private var order = LibraryOrder.title
    @State private var pager = LibraryPager<Song>()
    @Environment(PlayerModel.self) private var player
    @Environment(PlayFeed.self) private var feed

    var body: some View {
        LibraryPagerContent(pager: pager, query: query, section: .songs, isList: true) {
            LoadingRows(count: 10)
                .padding(.horizontal, PlayMetrics.margin)
        } content: {
            rows
        }
        .toolbar {
            ToolbarItem(placement: .libraryAction) {
                LibrarySortMenu(selection: $order, options: LibraryOrder.songOrders) { $0.menuTitle }
            }
        }
        .loads(pager, query: query, order: order, server: LibraryServerSort.songs(order)) { [facts = feed.facts] song in
            LibrarySortKeys(song: song, plays: facts[HistoryImport.key(title: song.title, artistName: song.artistName)]?.plays ?? 0)
        }
    }

    private var context: PlayContext { .songs(String(localized: "Songs")) }

    /// The list's rows: Play and Shuffle, then the songs.
    @ViewBuilder
    private var rows: some View {
        // Explicit songs are left out when they're off; playing goes by the song, not the row.
        let songs = pager.items.filter { allowsExplicit || !$0.isExplicit }
        if query.isEmpty {
            LibraryPlayButtons {
                player.play(.songs(songs), from: context)
            } shuffle: {
                Task {
                    let all = await pager.all(upTo: 2_000).filter { allowsExplicit || !$0.isExplicit }
                    player.play(.songs(all), from: context, shuffled: true)
                }
            }
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: PlayMetrics.margin, bottom: 12, trailing: PlayMetrics.margin))
        }
        ForEach(songs) { song in
            let identity = HistoryImport.key(title: song.title, artistName: song.artistName)
            Button {
                player.play(.songs(songs, startingAt: songs.firstIndex(of: song) ?? 0), from: context)
            } label: {
                TrackRow(
                    title: song.title,
                    subtitle: song.artistName,
                    cover: song.artwork.map(CoverArt.artwork) ?? .url(nil, seed: song.albumTitle ?? song.title),
                    // The title needs the width at the largest sizes; the plays can go.
                    plays: nil,
                    isExplicit: song.isExplicit,
                    isCurrent: player.current?.songIdentity == identity,
                    artist: song.artistName
                )
            }
            .buttonStyle(.plain)
            .libraryRowInsets()
            .contextMenu { SongMenu(song: song) }
            .swipeActions(edge: .leading) {
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    player.enqueue(.songs([song]), next: true, title: song.title)
                }
                .tint(.indigo)
            }
            .swipeActions(edge: .trailing) {
                Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") {
                    player.enqueue(.songs([song]), next: false, title: song.title)
                }
                .tint(.orange)
            }
        }
        // The next page, as the end comes into view. A row of its own, since with explicit
        // songs off the last ones loaded may all be hidden.
        if pager.hasMore, pager.gatherer == nil {
            if pager.loadMoreFailed {
                LoadMoreFailedRow { Task { await pager.loadNext() } }
                    .listRowSeparator(.hidden)
            } else {
                LoadingRow()
                    .listRowSeparator(.hidden)
                    // A new identity per page, so it asks again if it's still in view after one.
                    .id(pager.items.count)
                    .onAppear { Task { await pager.loadNext() } }
            }
        }
    }
}
#endif
