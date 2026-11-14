import SwiftUI
import Combine
import SwiftData
import TracksCore

/// Every play as a sortable table, with the selected song in an inspector.
///
/// The store filters, sorts and pages the rows, off the main actor, into plain values the
/// table shows. The table reads a page at a time, and the next as its last row scrolls into
/// view, so neither opening History nor clicking a column header costs more in a long history.
struct MacHistoryView: View {
    @State private var sort = HistorySort.played
    @State private var filter: HistoryFilter = .all
    @State private var limit = HistoryPage.size
    private var sources = SourceScopeSetting()

    var body: some View {
        MacHistoryTable(
            filter: $filter,
            sort: $sort,
            source: sources.scope,
            sourceSelection: sources.isOffered ? sources.selection : nil,
            limit: limit,
            loadMore: { limit += HistoryPage.size }
        )
        // A different filter or order starts again from the top.
        .onChange(of: filter) { limit = HistoryPage.size }
        .onChange(of: sources.scope) { limit = HistoryPage.size }
        .onChange(of: sort) { limit = HistoryPage.size }
    }
}

private struct MacHistoryTable: View {
    @Environment(AppModel.self) private var model
    @Binding var filter: HistoryFilter
    @Binding var sort: HistorySort
    let source: SourceScope
    /// Apple Music or Your Music alone, when the person has asked to see them apart.
    let sourceSelection: Binding<SourceScope>?
    let limit: Int
    let loadMore: () -> Void

    /// The page loaded, as values made off the main actor.
    @State private var rows: [HistoryRow] = []
    /// What ``rows`` were loaded for.
    @State private var loaded: HistoryLoad?
    @State private var selection = Set<PersistentIdentifier>()
    @State private var showsInspector = false
    @State private var pendingDelete: Capture?
    /// Plays waiting on the multiple-selection delete confirmation.
    @State private var pendingBulkDelete: Set<PersistentIdentifier> = []
    /// Every play the filter matches, not just the ones loaded, for the subtitle.
    @State private var total: Int?
    /// Bumped by each save and each batch of synced changes, so the rows and total follow them.
    @State private var storeChanges = 0
    @State private var isScrobbling = false
    private var playback = CapturePlayback()
    /// Written last when Settings connects or disconnects Last.fm, so the column follows it.
    @AppStorage(LastFMSessionStore.usernameDefaultsKey, store: CaptureSettings.sharedDefaults)
    private var lastFMUsername: String?
    @Environment(\.modelContext) private var context

    var body: some View {
        Table(of: HistoryRow.self, selection: $selection, sortOrder: sortOrder) {
            TableColumn("Title", sortUsing: HistorySort.Field.title.comparator) { row in
                HStack(spacing: 8) {
                    ArtworkView(url: row.artworkURL, seed: row.albumTitle ?? row.title, size: 26)
                    Text(row.title)
                }
                .onAppear {
                    if rows.count >= limit, row.id == rows.last?.id {
                        loadMore()
                    }
                }
            }
            .width(min: 110, ideal: 240)

            TableColumn("Artist", sortUsing: HistorySort.Field.artist.comparator) { row in
                CreditedText(text: row.artistName, credits: row.credits, linkStyle: .cell)
            }
            .width(min: 70, ideal: 160)

            TableColumn("Album", sortUsing: HistorySort.Field.album.comparator) { row in
                Text(row.album)
            }
            .width(min: 70, ideal: 150)

            TableColumn("Source", sortUsing: HistorySort.Field.source.comparator) { row in
                    // A song you chose from your own music says so, rather than "On Demand".
                    if row.kind == .onDemand, row.isYourMusic {
                        Label(SourceScope.yourMusic.title, systemImage: SourceScope.yourMusic.symbol)
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Label(row.kind.label, systemImage: row.kind.symbol)
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(row.kind == .onDemand ? .secondary : row.kind.tint)
                            .lineLimit(1)
                    }
                }
                .width(min: 96, ideal: 124)
    
            TableColumn("Played", sortUsing: HistorySort.Field.played.comparator) { row in
                Text(row.played)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // No wider than its longest date, so spare width goes to the names.
            .width(min: 140, ideal: 150, max: 170)

            // Only while Last.fm is connected: otherwise every row would be blank.
            if isScrobbling {
                TableColumn("Last.fm") { row in
                    scrobbleState(row)
                }
                .width(56)
            }
        } rows: {
            ForEach(rows) { row in
                TableRow(row)
                    .draggable(drag(from: row))
            }
        }
        .fixedTableRowHeight(34)
        // The columns are fixed once the table is made: AppKit's header falls out of step with
        // the rows when they change under it. Connecting Last.fm makes the table afresh.
        .id(isScrobbling)
        .contextMenu(forSelectionType: PersistentIdentifier.self) { ids in
            if ids.count == 1, let capture = captures(ids).first {
                PlayActions(capture: capture, onDelete: { pendingDelete = capture })
            } else if !ids.isEmpty {
                selectionMenu(ids)
            }
        } primaryAction: { ids in
            // Double-click or Return plays, as in Music; ⌘I gets its info.
            if canPlay(ids) { playback.play(captures(ids)) }
        }
        .focusedSceneValue(\.songInfoSelection, single(selection).map { SongInfoSubject(MixSong($0)) })
        .onDeleteCommand {
            guard !model.isShowingSampleData else { return }
            if selection.count == 1, let capture = captures(selection).first {
                pendingDelete = capture
            } else if !selection.isEmpty {
                pendingBulkDelete = selection
            }
        }
        .overlay {
            if rows.isEmpty, total != nil {
                if filter == .all, source != .all {
                    ContentUnavailableView("Nothing from \(Text(source.title))", systemImage: source.symbol)
                } else if filter == .all {
                    ContentUnavailableView(
                        "No History Yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Songs you play in Music will collect here.")
                    )
                } else {
                    ContentUnavailableView("No \(Text(filter.title))", systemImage: filter.symbol)
                }
            }
        }
        .inspector(isPresented: $showsInspector) {
            Group {
                if let row = single(selection) {
                    SongDetailView(songID: row.songIdentity)
                } else if selection.isEmpty {
                    ContentUnavailableView(
                        "No Selection",
                        systemImage: "music.note",
                        description: Text("Select a song to see its plays.")
                    )
                } else {
                    ContentUnavailableView("^[\(selection.count) Song](inflect: true) Selected", systemImage: "music.note.list")
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
        .navigationTitle("History")
        // Blank until counted: the loaded page's size would flash up first as the total.
        .navigationSubtitle(total.map { String(AttributedString(localized: "^[\($0) play](inflect: true)").characters) } ?? "")
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Show", selection: $filter) {
                        ForEach(HistoryFilter.allCases) { filter in
                            Label(filter.title, systemImage: filter.symbol).tag(filter)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelStyle(.titleAndIcon)
                    if let sourceSelection {
                        Section("Music") {
                            Picker("Music", selection: sourceSelection) {
                                ForEach(SourceScope.allCases) { scope in
                                    Label(scope.title, systemImage: scope.symbol).tag(scope)
                                }
                            }
                            .pickerStyle(.inline)
                            .labelStyle(.titleAndIcon)
                        }
                    }
                } label: {
                    Label("Filter", systemImage: filter == .all && source == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                }
                .help(sourceSelection == nil
                    ? "Show only radio, on demand or recovered songs"
                    : "Show only radio, on demand or recovered songs, or Apple Music or Your Music alone")
            }
            ToolbarItem {
                Button("Inspector", systemImage: "sidebar.trailing") {
                    showsInspector.toggle()
                }
                // ⌘I is Get Info, as in Music.
                .keyboardShortcut("i", modifiers: [.command, .control])
                .help("Show or hide the song inspector (⌃⌘I)")
            }
        }
        .deleteConfirmation(for: $pendingDelete)
        // No undo, so the confirmation is the safeguard. The store's one context is shared
        // with capture and sync: with an undo manager left attached, undo also reverts their
        // saves, and detaching it after the delete throws the registration away.
        .confirmationDialog(
            "Delete ^[\(pendingBulkDelete.count) Play](inflect: true)?",
            isPresented: Binding(
                get: { !pendingBulkDelete.isEmpty },
                set: { if !$0 { pendingBulkDelete = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete ^[\(pendingBulkDelete.count) Play](inflect: true)", role: .destructive) {
                deleteAll(pendingBulkDelete)
            }
            // Return cancels, so a keyboard confirmation can't delete by accident.
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("This can't be undone. Scrobbles already sent stay on Last.fm.")
        }
        .task(id: HistoryLoad(filter: filter, source: source, sort: sort, limit: limit, storeChanges: storeChanges)) {
            let load = HistoryLoad(filter: filter, source: source, sort: sort, limit: limit, storeChanges: storeChanges)
            // A burst of saves or synced changes loads once, at its end; anything asked for
            // loads at once.
            let isLive = loaded?.isSamePage(as: load) == true
            if isLive {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            // A count query uses the kind and date index, so it stays quick in a long history.
            let page = await HistoryRow.load(
                filter.descriptor(sortBy: sort.descriptors, source: source, limit: limit),
                counting: filter.descriptor(source: source),
                in: context.container,
                maxAttempts: TracksStore.maxScrobbleAttempts
            )
            guard !Task.isCancelled else { return }
            if isLive, page.rows != rows {
                // A song that just finished slides in at the top.
                withAnimation(.default) { rows = page.rows }
            } else if page.rows != rows {
                rows = page.rows
            }
            total = page.total
            loaded = load
        }
        .onStoreChange(of: context) { storeChanges += 1 }
        // Other contexts' saves (an import, a background write) and synced rows, which a
        // query used to pick up. The load above waits out a burst of them.
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave).receive(on: DispatchQueue.main)) { note in
            guard let saver = note.object as? ModelContext, saver !== context,
                  saver.container === context.container
            else { return }
            storeChanges += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange).receive(on: DispatchQueue.main)) { _ in
            storeChanges += 1
        }
        .onChange(of: lastFMUsername, initial: true) {
            isScrobbling = LastFMKeyCheck.isConnected(as: lastFMUsername)
        }
    }

    /// The table's sort, as the one order the page keeps.
    private var sortOrder: Binding<[KeyPathComparator<HistoryRow>]> {
        Binding {
            [sort.comparator]
        } set: { comparators in
            guard let first = comparators.first, let chosen = HistorySort(first) else { return }
            sort = chosen
        }
    }

    /// The plays behind `ids`, read from the store when they're acted on, in the table's order.
    private func captures(_ ids: Set<PersistentIdentifier>) -> [Capture] {
        let chosen = Array(ids)
        let found = (try? context.fetch(FetchDescriptor<Capture>(predicate: #Predicate { chosen.contains($0.persistentModelID) }))) ?? []
        let byID = Dictionary(found.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { first, _ in first })
        return rows.compactMap { byID[$0.id] }
    }

    /// Whether any of them can play, from the rows alone, as ``CapturePlayback/canPlay(_:)``.
    private func canPlay(_ ids: Set<PersistentIdentifier>) -> Bool {
        !model.isShowingSampleData && rows.contains { ids.contains($0.id) && !$0.songID.isEmpty }
    }

    /// The row dragged, with the rest of the selection when it's part of it.
    private func drag(from row: HistoryRow) -> SongDrag {
        let dragged = selection.contains(row.id) ? rows.filter { selection.contains($0.id) } : [row]
        return SongDrag(dragged.map {
            HistorySong(songID: $0.songID, title: $0.title, artistName: $0.artistName, albumTitle: $0.albumTitle, artworkURL: $0.artworkURL)
        })
    }

    /// Several plays: play them or queue them in the table's order, or delete them.
    @ViewBuilder
    private func selectionMenu(_ ids: Set<PersistentIdentifier>) -> some View {
        let playable = canPlay(ids)
        if playable {
            Button("Play", systemImage: "play") { playback.play(captures(ids)) }
            if playback.canQueue {
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { playback.enqueue(captures(ids), next: true) }
                Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") { playback.enqueue(captures(ids), next: false) }
            }
        }
        if !model.isShowingSampleData {
            if playable { Divider() }
            Button("Delete ^[\(ids.count) Play](inflect: true)…", systemImage: "trash", role: .destructive) {
                pendingBulkDelete = ids
            }
        }
    }

    private func single(_ ids: Set<PersistentIdentifier>) -> HistoryRow? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return rows.first { $0.id == id }
    }

    private func deleteAll(_ ids: Set<PersistentIdentifier>) {
        for capture in captures(ids) {
            try? model.store?.deletePlay(capture)
        }
        selection.removeAll()
    }

    @ViewBuilder
    private func scrobbleState(_ row: HistoryRow) -> some View {
        switch row.scrobble {
        case .scrobbled:
            Image(systemName: "checkmark")
                .foregroundStyle(.secondary)
                .help("Scrobbled")
                .accessibilityLabel("Scrobbled")
        case .held:
            // Kept, but too short for Last.fm's rule: nothing went wrong, and nothing's waiting.
            Image(systemName: "minus")
                .foregroundStyle(.tertiary)
                .help("Not long enough for Last.fm to count")
                .accessibilityLabel("Not long enough for Last.fm to count")
        case .failed(let error):
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.orange)
                .help(error ?? "Last.fm didn't accept this one")
                .accessibilityLabel("Not scrobbled")
                .accessibilityValue(error ?? "Last.fm didn't accept this one")
        case .waiting:
            Image(systemName: "clock")
                .foregroundStyle(.tertiary)
                .help("Waiting to be scrobbled")
                .accessibilityLabel("Waiting to be scrobbled")
        }
    }
}

/// What a page of rows was loaded for.
private struct HistoryLoad: Equatable {
    let filter: HistoryFilter
    let source: SourceScope
    let sort: HistorySort
    let limit: Int
    let storeChanges: Int

    /// The same rows asked for, with only the store changed since.
    func isSamePage(as other: HistoryLoad) -> Bool {
        filter == other.filter && source == other.source && sort == other.sort && limit == other.limit
            && storeChanges != other.storeChanges
    }
}

/// The order History's table is in: one column, either way.
private nonisolated struct HistorySort: Equatable {
    enum Field: CaseIterable {
        case title, artist, album, source, played

        /// The column's comparator, in the order a first click on it gives: names A to Z,
        /// the newest plays first.
        var comparator: KeyPathComparator<HistoryRow> {
            switch self {
            case .title: KeyPathComparator(\HistoryRow.title, comparator: .localizedStandard)
            case .artist: KeyPathComparator(\HistoryRow.artistName, comparator: .localizedStandard)
            case .album: KeyPathComparator(\HistoryRow.album, comparator: .localizedStandard)
            case .source: KeyPathComparator(\HistoryRow.kindRawValue)
            case .played: KeyPathComparator(\HistoryRow.capturedAt, order: .reverse)
            }
        }
    }

    var field: Field
    var order: SortOrder

    static let played = HistorySort(field: .played, order: .reverse)

    init(field: Field, order: SortOrder) {
        self.field = field
        self.order = order
    }

    init?(_ comparator: KeyPathComparator<HistoryRow>) {
        guard let field = Field.allCases.first(where: { $0.comparator.keyPath == comparator.keyPath }) else { return nil }
        self.init(field: field, order: comparator.order)
    }

    var comparator: KeyPathComparator<HistoryRow> {
        var comparator = field.comparator
        comparator.order = order
        return comparator
    }

    /// The same order, for the store to sort by.
    var descriptors: [SortDescriptor<Capture>] {
        switch field {
        case .title: [SortDescriptor(\Capture.title, comparator: .localizedStandard, order: order)]
        case .artist: [SortDescriptor(\Capture.artistName, comparator: .localizedStandard, order: order)]
        case .album: [SortDescriptor(\Capture.albumTitle, comparator: .localizedStandard, order: order)]
        case .source: [SortDescriptor(\Capture.kindRawValue, order: order)]
        case .played: [SortDescriptor(\Capture.capturedAt, order: order)]
        }
    }
}

/// A play as History's table shows it: plain values, read and worked out off the main actor,
/// so drawing a row never touches the store.
private nonisolated struct HistoryRow: Identifiable, Equatable, Sendable {
    enum Scrobble: Equatable, Sendable {
        case scrobbled, held, failed(String?), waiting
    }

    let id: PersistentIdentifier
    let songID: String
    let title: String
    let artistName: String
    let albumTitle: String?
    /// The album, or empty, to sort by.
    let album: String
    let artworkURL: String?
    let kindRawValue: String
    let kind: CaptureKind
    let isYourMusic: Bool
    let capturedAt: Date
    /// "Sep 13, 9:24 PM", with the year only for past years.
    let played: String
    let credits: [ArtistCredit]
    let songIdentity: String
    let scrobble: Scrobble

    init(_ capture: Capture, now: Date, maxAttempts: Int) {
        id = capture.persistentModelID
        songID = capture.songID
        title = capture.title
        artistName = capture.artistName
        albumTitle = capture.albumTitle
        album = capture.albumTitle ?? ""
        artworkURL = capture.artworkURL
        kindRawValue = capture.kindRawValue
        kind = capture.kind
        isYourMusic = capture.source == .yourMusic
        capturedAt = capture.capturedAt
        played = Calendar.current.isDate(capture.capturedAt, equalTo: now, toGranularity: .year)
            ? capture.capturedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            : capture.capturedAt.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
        credits = ArtistCredits.song(artist: capture.artistName, title: capture.title)
        songIdentity = HistoryImport.key(title: capture.title, artistName: capture.artistName)
        scrobble = if capture.scrobbledAt != nil {
            .scrobbled
        } else if capture.isHeldFromScrobbling {
            .held
        } else if capture.scrobbleAttempts >= maxAttempts {
            .failed(capture.lastScrobbleError)
        } else {
            .waiting
        }
    }

    /// A page of plays and how many the filter matches, from a context of its own.
    @concurrent
    static func load(
        _ descriptor: FetchDescriptor<Capture>,
        counting: FetchDescriptor<Capture>,
        in container: ModelContainer,
        maxAttempts: Int
    ) async -> (rows: [HistoryRow], total: Int?) {
        let context = ModelContext(container)
        let now = Date.now
        let rows = ((try? context.fetch(descriptor)) ?? []).map { HistoryRow($0, now: now, maxAttempts: maxAttempts) }
        return (rows, try? context.fetchCount(counting))
    }
}

extension MixSong {
    /// A row of History's table, as a song.
    fileprivate init(_ row: HistoryRow) {
        self.init(
            songIdentity: row.songIdentity,
            songID: row.songID,
            title: row.title,
            artistName: row.artistName,
            albumTitle: row.albumTitle,
            artworkURL: row.artworkURL,
            plays: 0,
            lastHeard: row.capturedAt,
            genre: nil
        )
    }
}

/// Whether Last.fm is connected, read from the keychain once per account rather than each time
/// History opens: a keychain read waits on another process, on the main thread.
@MainActor
private enum LastFMKeyCheck {
    private static var last: (username: String?, isConnected: Bool)?

    static func isConnected(as username: String?) -> Bool {
        if let last, last.username == username { return last.isConnected }
        let isConnected = LastFMSessionStore.current != nil
        last = (username, isConnected)
        return isConnected
    }
}
