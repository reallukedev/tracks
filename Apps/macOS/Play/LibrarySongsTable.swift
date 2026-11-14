import SwiftUI
import MusicKit
import TracksCore

/// Songs as Music lists them on the Mac: a table whose columns sort, where a click selects,
/// a double-click or Return plays from that song in the table's order, and a right-click
/// offers the song's menu. Rows drag out as songs.
struct LibrarySongsTable<Menu: View>: View {
    /// In the order shown.
    let rows: [LibrarySongRow]
    @Binding var order: LibraryOrder
    @Binding var selection: Set<LibrarySongRow.ID>
    let source: LibrarySongSource
    var showsAdded = false
    let play: (LibrarySongRow) -> Void
    /// A row near the end came into view: time for the next page.
    var nearEnd: (() -> Void)?
    var delete: ((Set<LibrarySongRow.ID>) -> Void)?
    @ViewBuilder var menu: (Set<LibrarySongRow.ID>) -> Menu
    @Environment(PlayerModel.self) private var player

    var body: some View {
        Table(of: LibrarySongRow.self, selection: $selection, sortOrder: sortOrder) {
            TableColumn("Title", value: \.title) { row in
                LibrarySongTitleCell(row: row, player: player)
                    .onAppear { if let nearEnd, isNearEnd(row) { nearEnd() } }
            }
            .width(min: 140, ideal: 220)
            TableColumn("Artist", value: \.artist) { row in
                ArtistLinks(artist: row.artist, title: row.title, linkStyle: .cell).lineLimit(1).dimmed(!row.isPlayable)
            }
            .width(min: 90, ideal: 130)
            TableColumn("Album", value: \.album) { row in
                Text(row.album).lineLimit(1).dimmed(!row.isPlayable)
            }
            .width(min: 90, ideal: 150)
            TableColumn("Time", value: \.duration) { row in
                Text(LibraryTime.text(row.duration))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .dimmed(!row.isPlayable)
            }
            .width(min: 44, ideal: 52, max: 70)
            .alignment(.trailing)
            TableColumn("Your Plays", value: \.plays) { row in
                Text(row.plays > 0 ? row.plays.formatted() : "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .dimmed(!row.isPlayable)
            }
            .width(min: 64, ideal: 76, max: 96)
            .alignment(.numeric)
            if showsAdded {
                TableColumn("Date Added", value: \.added) { row in
                    Text(row.added == .distantPast ? "" : row.added.formatted(date: .abbreviated, time: .omitted))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .dimmed(!row.isPlayable)
                }
                .width(min: 86, ideal: 104, max: 140)
            }
        } rows: {
            ForEach(rows) { row in
                TableRow(row)
                    .draggable(drag(from: row))
            }
        }
        .contextMenu(forSelectionType: LibrarySongRow.ID.self) { ids in
            menu(ids)
        } primaryAction: { ids in
            if let first = rows.first(where: { ids.contains($0.id) }) { play(first) }
        }
        .onDeleteCommand {
            if let delete, !selection.isEmpty { delete(selection) }
        }
        .focusedSceneValue(\.songInfoSelection, selectedSubject)
    }

    /// The table's sort descriptors, as the one order the page keeps. A column clicked for the
    /// first time starts in its natural order: names A to Z, numbers and dates biggest first.
    private var sortOrder: Binding<[KeyPathComparator<LibrarySongRow>]> {
        Binding {
            [order.comparator]
        } set: { comparators in
            guard let first = comparators.first, let chosen = LibraryOrder(first) else { return }
            order = chosen.field == order.field ? chosen : .natural(chosen.field)
        }
    }

    /// Only the last rows are looked through: every row's cell asks as it scrolls into view.
    private func isNearEnd(_ row: LibrarySongRow) -> Bool {
        rows.suffix(30).contains { $0.id == row.id }
    }

    /// The one row selected, for Get Info.
    private var selectedSubject: SongInfoSubject? {
        guard selection.count == 1, let row = rows.first(where: { selection.contains($0.id) }) else { return nil }
        return SongInfoSubject(title: row.title, artistName: row.artist, albumTitle: row.album, cover: row.cover)
    }

    /// The row dragged, with the rest of the selection when it's part of it.
    private func drag(from row: LibrarySongRow) -> SongDrag {
        let dragged = selection.contains(row.id) ? rows.filter { selection.contains($0.id) } : [row]
        return SongDrag(rows: dragged, from: source)
    }
}

/// The title column: a small cover, the title, and Explicit. The playing song's cover shows
/// the waveform and its title the accent, except on a selected row, where the accent wouldn't
/// read. The cell watches the player itself, so a new song redraws two cells rather than the
/// whole table. The player is handed in: a table's cells are hosted apart from the page and
/// don't always see the objects in its environment, and reading a missing one ends the app.
private struct LibrarySongTitleCell: View {
    let row: LibrarySongRow
    let player: PlayerModel
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let isCurrent = player.current?.songIdentity == row.identity
        HStack(spacing: 8) {
            CoverImage(cover: row.cover, size: 22)
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: CoverImage.radius(for: 22), style: .continuous)
                            .fill(.black.opacity(0.45))
                        PlayingWaveform(isActive: player.isPlaying, color: .white)
                            .font(.system(size: 10, weight: .bold))
                    }
                }
            Text(row.title)
                .lineLimit(1)
                .foregroundStyle(isCurrent && prominence != .increased ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            if row.isExplicit {
                ExplicitBadge()
            }
        }
        .dimmed(!row.isPlayable)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// A song that can't play right now (its server is offline, and it isn't downloaded)
    /// recedes in every column.
    fileprivate func dimmed(_ isDimmed: Bool) -> some View {
        opacity(isDimmed ? 0.45 : 1)
    }
}

// MARK: - Apple Music

/// The Apple Music library's songs on the Mac. The whole library is read once, unsorted, and
/// every column sorts here in Swift, your plays included: a sorted library request can end the
/// app on the Mac. Rows are made off the main actor, once per order or filter, not per redraw.
struct LibrarySongsTablePage: View {
    let query: String
    @AppStorage(PlayPreferences.allowsExplicitKey) private var allowsExplicit = true
    @AppStorage("macLibrarySongOrder") private var order = LibraryOrder.title
    @State private var pager = LibraryPager<Song>()
    @State private var rows: [LibrarySongRow] = []
    @State private var selection: Set<LibrarySongRow.ID> = []
    @Environment(PlayerModel.self) private var player
    @Environment(PlayFeed.self) private var feed

    var body: some View {
        VStack(spacing: 0) {
            LibraryPageHeader(
                title: String(localized: "Songs"),
                subtitle: pager.count(Self.count),
                play: rows.isEmpty ? nil : { play(nil) },
                shuffle: rows.isEmpty ? nil : { shuffleAll() }
            )
            LibraryPagerContent(pager: pager, query: query, section: .songs) {
                LibraryTablePlaceholder()
            } content: {
                LibrarySongsTable(
                    rows: rows,
                    order: $order,
                    selection: $selection,
                    source: .appleMusic,
                    showsAdded: true,
                    play: { play($0) },
                    menu: { ids in menu(for: ids) }
                )
            }
        }
        .loads(pager, query: query, order: order, key: "\(feed.builtRevision ?? 0)") { [facts = feed.facts] song in
            LibrarySortKeys(song: song, plays: facts[HistoryImport.key(title: song.title, artistName: song.artistName)]?.plays ?? 0)
        }
        .task(id: "\(pager.revision)\u{1F}\(allowsExplicit)\u{1F}\(feed.builtRevision ?? 0)") {
            let made = await Self.rows(of: pager.items, facts: feed.facts, allowsExplicit: allowsExplicit)
            // Most new plays change no row here; the table is left alone unless one did.
            if made != rows { rows = made }
        }
    }

    /// The table's rows, in the pager's order, leaving out explicit songs when they're off.
    @concurrent
    private nonisolated static func rows(of songs: [Song], facts: [String: SongFacts], allowsExplicit: Bool) async -> [LibrarySongRow] {
        songs.compactMap { song in
            guard allowsExplicit || !song.isExplicit else { return nil }
            return LibrarySongRow(song: song, plays: facts[HistoryImport.key(title: song.title, artistName: song.artistName)]?.plays ?? 0)
        }
    }

    /// The songs in the table's order, from `row` (the top when nil).
    private func play(_ row: LibrarySongRow?) {
        let byID = Dictionary(pager.items.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
        let queue = rows.compactMap { byID[$0.id] }
        let start = row.flatMap { row in queue.firstIndex { $0.id.rawValue == row.id } } ?? 0
        player.play(.songs(queue, startingAt: start), from: .songs(String(localized: "Songs")))
    }

    private func shuffleAll() {
        Task {
            let all = await pager.all(upTo: 5_000).filter { allowsExplicit || !$0.isExplicit }
            player.play(.songs(all), from: .songs(String(localized: "Songs")), shuffled: true)
        }
    }

    @ViewBuilder
    private func menu(for ids: Set<LibrarySongRow.ID>) -> some View {
        let chosen = pager.items.filter { ids.contains($0.id.rawValue) }
        if chosen.count == 1, let song = chosen.first {
            SongMenu(song: song, play: { play(rows.first { $0.id == song.id.rawValue }) })
        } else if !chosen.isEmpty {
            let title = String(AttributedString(localized: "^[\(chosen.count) song](inflect: true)").characters)
            Button("Play", systemImage: "play") {
                player.play(.songs(chosen), from: .songs(title))
            }
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                player.enqueue(.songs(chosen), next: true, title: title)
            }
            Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") {
                player.enqueue(.songs(chosen), next: false, title: title)
            }
        }
    }

    private static func count(_ count: Int) -> String {
        String(AttributedString(localized: "^[\(count) song](inflect: true)").characters)
    }
}

/// A table's shape while it loads: a header's worth of space, then rows with a small square
/// where the cover goes and bars in the columns, at the table's own row height.
struct LibraryTablePlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 28)
            ForEach(0..<18, id: \.self) { index in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: CoverImage.radius(for: 22), style: .continuous)
                        .fill(Color.placeholderFill)
                        .frame(width: 22, height: 22)
                    HStack(spacing: 0) {
                        bar(Self.titles[index % Self.titles.count]).frame(maxWidth: .infinity, alignment: .leading)
                        bar(Self.artists[index % Self.artists.count]).frame(maxWidth: .infinity, alignment: .leading)
                        bar(Self.albums[index % Self.albums.count]).frame(maxWidth: .infinity, alignment: .leading)
                        bar("0:00").frame(width: 60, alignment: .trailing)
                    }
                }
                .frame(height: 28)
                .padding(.horizontal, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .accessibilityElement()
        .accessibilityLabel(Text("Loading"))
    }

    private func bar(_ text: String) -> some View {
        Text(verbatim: text)
            .lineLimit(1)
            .redacted(reason: .placeholder)
    }

    private static let titles = ["A Song Title", "Name", "A Longer Song Title", "Title Here", "Song"]
    private static let artists = ["Artist", "Artist Name", "Someone", "Band"]
    private static let albums = ["Album Title", "Record", "A Longer Album", "Album"]
}

// MARK: - Your Music

/// Every song in your music on the Mac, as a table, with the date each was added. Rows are
/// filtered, made and sorted off the main actor, once per change, not per redraw.
struct LibraryYourSongsTablePage: View {
    @Environment(YourMusic.self) private var music
    @Environment(PlayFeed.self) private var feed
    @Environment(PlayerModel.self) private var player
    @AppStorage("macYourSongOrder") private var order = LibraryOrder.title
    @State private var query = ""
    @State private var selection: Set<LibrarySongRow.ID> = []
    @State private var deleting: [LocalTrack] = []
    /// Nil until first made.
    @State private var shown: YourSongsRows?

    var body: some View {
        let rows = shown?.rows ?? []
        let byID = shown?.byID ?? [:]
        VStack(spacing: 0) {
            LibraryPageHeader(
                title: String(localized: "Songs"),
                subtitle: music.index.isEmpty ? nil : String(AttributedString(localized: "^[\(music.index.tracks.count) song](inflect: true)").characters),
                play: rows.isEmpty ? nil : { play(from: nil, rows: rows, byID: byID) },
                shuffle: rows.isEmpty ? nil : { player.play(.local(queue(rows, byID)), from: context, shuffled: true) }
            )
            if music.index.isEmpty {
                if music.hasScanned || !music.servers.servers.isEmpty {
                    LibraryEmptyYourMusic(title: String(localized: "No Songs Yet"))
                } else {
                    LoadingRows(count: 12)
                        .padding(.horizontal, PlayMetrics.margin)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            } else if shown == nil {
                LibraryTablePlaceholder()
            } else if rows.isEmpty {
                LibraryNoMatches(query: query)
            } else {
                LibrarySongsTable(
                    rows: rows,
                    order: $order,
                    selection: $selection,
                    source: .yourMusic,
                    showsAdded: true,
                    play: { play(from: $0, rows: rows, byID: byID) },
                    delete: { ids in
                        deleting = ids.compactMap { byID[$0] }.filter { !$0.isFromServer }
                    }
                ) { ids in
                    menu(for: ids.compactMap { byID[$0] }, rows: rows, byID: byID)
                }
            }
        }
        .navigationTitle("Songs")
        .toolbar(removing: .title)
        .searchable(text: $query, placement: .toolbar, prompt: "Filter Songs")
        .libraryToolbar()
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deleting.forEach(music.deleteFile)
                selection.subtract(deleting.map(\.id))
                deleting = []
            }
        } message: {
            Text("The files are removed from the Tracks music folder. Your plays of them stay in your history.")
        }
        .task(id: rowsKey) {
            let key = rowsKey
            // Typing on from a filter already shown waits for a pause; the first letter and
            // clearing it don't.
            if let shown, shown.query != key.query, !key.query.isEmpty, !shown.query.isEmpty {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            let made = await YourSongsRows.make(
                index: music.index,
                revision: key.index,
                query: key.query,
                order: key.order,
                facts: feed.facts,
                playability: key.playability,
                clients: music.servers.servers.reduce(into: [:]) { clients, server in
                    clients[server.id] = music.servers.client(for: server.id)
                }
            )
            guard !Task.isCancelled else { return }
            if made != shown { shown = made }
        }
    }

    /// Everything the rows are made from, cheap to compare: a new play, a download finishing
    /// or a server going offline makes them again; a redraw doesn't.
    private var rowsKey: YourSongsRows.Key {
        YourSongsRows.Key(
            query: query,
            order: order,
            index: music.indexRevision,
            facts: feed.builtRevision,
            playability: YourSongsRows.Playability(music: music)
        )
    }

    private var context: PlayContext { .songs(String(localized: "Your Songs")) }

    private var deleteTitle: String {
        if deleting.count == 1, let track = deleting.first {
            return String(localized: "Delete \u{201C}\(track.title)\u{201D}?")
        }
        return String(localized: "Delete ^[\(deleting.count) Song](inflect: true)?")
    }

    private func queue(_ rows: [LibrarySongRow], _ byID: [String: LocalTrack]) -> [LocalTrack] {
        rows.compactMap { byID[$0.id] }.filter(music.isPlayable)
    }

    private func play(from row: LibrarySongRow?, rows: [LibrarySongRow], byID: [String: LocalTrack]) {
        let queue = queue(rows, byID)
        let start = row.flatMap { row in queue.firstIndex { $0.id == row.id } } ?? 0
        player.play(.local(queue, startingAt: start), from: context)
    }

    @ViewBuilder
    private func menu(for tracks: [LocalTrack], rows: [LibrarySongRow], byID: [String: LocalTrack]) -> some View {
        if tracks.count == 1, let track = tracks.first {
            LocalTrackMenu(track: track, showsStats: true, onDelete: { deleting = [$0] }) { actions in
                actions.play = music.isPlayable(track) ? { play(from: rows.first { $0.id == track.id }, rows: rows, byID: byID) } : nil
            }
        } else if !tracks.isEmpty {
            let playable = tracks.filter(music.isPlayable)
            let title = String(AttributedString(localized: "^[\(tracks.count) song](inflect: true)").characters)
            if !playable.isEmpty {
                Button("Play", systemImage: "play") {
                    player.play(.local(playable), from: .songs(title))
                }
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    player.enqueue(.local(playable), next: true, title: title)
                }
                Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") {
                    player.enqueue(.local(playable), next: false, title: title)
                }
                Divider()
            }
            AddToPlaylistMenu(tracks: tracks)
            let server = tracks.filter { $0.isFromServer && !music.downloads.isDownloaded($0.id) }
            if !server.isEmpty {
                Button("Download", systemImage: "arrow.down.circle") { music.downloads.download(server) }
            }
            let files = tracks.filter { !$0.isFromServer }
            if !files.isEmpty {
                Divider()
                Button("Delete ^[\(files.count) Song](inflect: true)…", systemImage: "trash", role: .destructive) {
                    deleting = files
                }
            }
        }
    }
}

/// The Your Music table's rows, with the songs they stand for, as made for one filter.
private nonisolated struct YourSongsRows: Equatable, Sendable {
    let query: String
    /// The index's revision they're from: a new index always replaces them, so the songs
    /// behind the rows are never an older index's.
    let index: Int
    let rows: [LibrarySongRow]
    let byID: [String: LocalTrack]

    /// Most new plays change no row: the table is left alone unless one did.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.query == rhs.query && lhs.index == rhs.index && lhs.rows == rhs.rows
    }

    struct Key: Equatable {
        let query: String
        let order: LibraryOrder
        let index: Int
        let facts: Int?
        let playability: Playability
    }

    /// What ``YourMusic/isPlayable(_:)`` goes by, taken on the main actor so rows can be made
    /// off it.
    struct Playability: Equatable, Sendable {
        let downloaded: Set<String>
        /// Servers that can be reached now, with a client to reach them.
        let reachable: Set<String>

        @MainActor
        init(music: YourMusic) {
            downloaded = Set(music.downloads.items.keys)
            guard music.network.isOnline else {
                reachable = []
                return
            }
            reachable = Set(music.servers.servers.map(\.id).filter { id in
                guard music.servers.client(for: id) != nil else { return false }
                switch music.servers.status[id] {
                case .offline, .wrongPassword, .failed: return false
                case .online, .connecting, nil: return true
                }
            })
        }

        func isPlayable(_ track: LocalTrack) -> Bool {
            switch track.origin {
            case .file: true
            case .server(let serverID, _): downloaded.contains(track.id) || reachable.contains(serverID)
            }
        }
    }

    /// As the main actor made them before: the index's own search when filtered, then the
    /// order chosen. Covers are addressed once each, not once per song on the album.
    @concurrent
    static func make(
        index: LocalLibraryIndex,
        revision: Int,
        query: String,
        order: LibraryOrder,
        facts: [String: SongFacts],
        playability: Playability,
        clients: [String: SubsonicClient]
    ) async -> YourSongsRows {
        let tracks = query.isEmpty ? index.tracks : index.search(query, limit: 1_000).tracks
        var covers: [LocalTrack.Artwork: String] = [:]
        func cover(_ artwork: LocalTrack.Artwork?) -> String? {
            guard let artwork else { return nil }
            if let known = covers[artwork] { return known }
            let url: URL? = switch artwork {
            case .file(let name): LibraryFolders.artwork.appending(path: name)
            case .server(let serverID, let coverID): clients[serverID]?.coverArtURL(id: coverID, size: 600)
            }
            let address = url?.absoluteString
            if let address { covers[artwork] = address }
            return address
        }
        let rows = tracks.map { track in
            // Field by field: the `init(track:)` shorthand is the main actor's.
            LibrarySongRow(
                id: track.id,
                title: track.title,
                artist: track.artist,
                album: track.album ?? "",
                duration: track.duration ?? 0,
                plays: facts[track.identity]?.plays ?? 0,
                added: track.addedAt,
                cover: .url(cover(track.artwork), seed: track.album ?? track.title),
                isPlayable: playability.isPlayable(track),
                identity: track.identity
            )
        }
        return YourSongsRows(
            query: query,
            index: revision,
            rows: LibrarySort.sorted(rows, by: order) { $0.sortKeys },
            byID: Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        )
    }
}
