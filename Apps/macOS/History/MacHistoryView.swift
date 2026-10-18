import SwiftUI
import SwiftData
import TracksCore

/// Every play as a sortable table, with the selected song in an inspector.
///
/// The store filters, sorts and pages the rows. The table reads a page at a time, and the
/// next as its last row scrolls into view, so neither opening History nor clicking a column
/// header costs more in a long history.
struct MacHistoryView: View {
    @State private var sortOrder = [SortDescriptor(\Capture.capturedAt, order: .reverse)]
    @State private var filter: HistoryFilter = .all
    @State private var limit = HistoryPage.size
    private var sources = SourceScopeSetting()

    var body: some View {
        MacHistoryTable(
            filter: $filter,
            sortOrder: $sortOrder,
            source: sources.scope,
            sourceSelection: sources.isOffered ? sources.selection : nil,
            limit: limit,
            loadMore: { limit += HistoryPage.size }
        )
        // A different filter or order starts again from the top.
        .onChange(of: filter) { limit = HistoryPage.size }
        .onChange(of: sources.scope) { limit = HistoryPage.size }
        .onChange(of: sortOrder) { limit = HistoryPage.size }
    }
}

private struct MacHistoryTable: View {
    @Environment(AppModel.self) private var model
    @Binding var filter: HistoryFilter
    @Binding var sortOrder: [SortDescriptor<Capture>]
    let source: SourceScope
    /// Apple Music or Your Music alone, when the person has asked to see them apart.
    let sourceSelection: Binding<SourceScope>?
    let limit: Int
    let loadMore: () -> Void

    /// Animated, so a song that just finished slides in at the top.
    @Query private var rows: [Capture]
    @State private var selection = Set<PersistentIdentifier>()
    @State private var showsInspector = false
    @State private var pendingDelete: Capture?
    /// Plays waiting on the multiple-selection delete confirmation.
    @State private var pendingBulkDelete: Set<PersistentIdentifier> = []
    /// Every play the filter matches, not just the ones loaded, for the subtitle.
    @State private var total: Int?
    /// Bumped by each save and each batch of synced changes, so the total follows them.
    @State private var storeChanges = 0
    @State private var isScrobbling = false
    private var playback = CapturePlayback()
    /// Written last when Settings connects or disconnects Last.fm, so the column follows it.
    @AppStorage(LastFMSessionStore.usernameDefaultsKey, store: CaptureSettings.sharedDefaults)
    private var lastFMUsername: String?
    @Environment(\.modelContext) private var context

    init(
        filter: Binding<HistoryFilter>,
        sortOrder: Binding<[SortDescriptor<Capture>]>,
        source: SourceScope,
        sourceSelection: Binding<SourceScope>?,
        limit: Int,
        loadMore: @escaping () -> Void
    ) {
        _filter = filter
        _sortOrder = sortOrder
        self.source = source
        self.sourceSelection = sourceSelection
        self.limit = limit
        self.loadMore = loadMore
        _rows = Query(
            filter.wrappedValue.descriptor(sortBy: sortOrder.wrappedValue, source: source, limit: limit),
            animation: .default
        )
    }

    var body: some View {
        Table(of: Capture.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Title", sortUsing: SortDescriptor(\Capture.title, comparator: .localizedStandard)) { capture in
                HStack(spacing: 8) {
                    ArtworkView(url: capture.artworkURL, seed: capture.albumTitle ?? capture.title, size: 26)
                    Text(capture.title)
                }
                .onAppear {
                    if rows.count >= limit, capture.persistentModelID == rows.last?.persistentModelID {
                        loadMore()
                    }
                }
            }
            .width(min: 110, ideal: 240)

            TableColumn("Artist", sortUsing: SortDescriptor(\Capture.artistName, comparator: .localizedStandard)) { capture in
                CreditedText(
                    text: capture.artistName,
                    credits: ArtistCredits.song(artist: capture.artistName, title: capture.title),
                    linkStyle: .cell
                )
            }
            .width(min: 70, ideal: 160)

            TableColumn("Album", sortUsing: SortDescriptor(\Capture.albumTitle, comparator: .localizedStandard)) { capture in
                Text(capture.albumTitle ?? "")
            }
            .width(min: 70, ideal: 150)

            TableColumn("Source", sortUsing: SortDescriptor(\Capture.kindRawValue)) { capture in
                    // A song you chose from your own music says so, rather than "On Demand".
                    if capture.kind == .onDemand, capture.source == .yourMusic {
                        Label(SourceScope.yourMusic.title, systemImage: SourceScope.yourMusic.symbol)
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Label(capture.kind.label, systemImage: capture.kind.symbol)
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(capture.kind == .onDemand ? .secondary : capture.kind.tint)
                            .lineLimit(1)
                    }
                }
                .width(min: 96, ideal: 124)
    
            TableColumn("Played", sortUsing: SortDescriptor(\Capture.capturedAt, order: .reverse)) { capture in
                Text(Format.shortDateTime(capture.capturedAt))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // No wider than its longest date, so spare width goes to the names.
            .width(min: 140, ideal: 150, max: 170)

            // Only while Last.fm is connected: otherwise every row would be blank.
            if isScrobbling {
                TableColumn("Last.fm") { capture in
                    scrobbleState(capture)
                }
                .width(56)
            }
        } rows: {
            ForEach(rows) { capture in
                TableRow(capture)
                    .draggable(drag(from: capture))
            }
        }
        // The columns are fixed once the table is made: AppKit's header falls out of step with
        // the rows when they change under it. Connecting Last.fm makes the table afresh.
        .id(isScrobbling)
        .contextMenu(forSelectionType: PersistentIdentifier.self) { ids in
            if let capture = single(ids) {
                PlayActions(capture: capture, onDelete: { pendingDelete = capture })
            } else if !ids.isEmpty {
                selectionMenu(ids)
            }
        } primaryAction: { ids in
            // Double-click or Return plays, as in Music; ⌘I gets its info.
            let chosen = ordered(ids)
            if playback.canPlay(chosen) { playback.play(chosen) }
        }
        .focusedSceneValue(\.songInfoSelection, single(selection).map { SongInfoSubject(MixSong($0)) })
        .onDeleteCommand {
            guard !model.isShowingSampleData else { return }
            if let capture = single(selection) {
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
                if let capture = single(selection) {
                    SongDetailView(songID: HistoryImport.key(title: capture.title, artistName: capture.artistName))
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
        .navigationSubtitle(String(AttributedString(localized: "^[\(total ?? rows.count) play](inflect: true)").characters))
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
        // A count query uses the kind and date index, so it stays quick in a long history.
        .task(id: "\(filter.rawValue)|\(source.rawValue)|\(storeChanges)") {
            total = try? context.fetchCount(filter.descriptor(source: source))
        }
        .onStoreChange(of: context) { storeChanges += 1 }
        .onChange(of: lastFMUsername, initial: true) {
            isScrobbling = LastFMSessionStore.current != nil
        }
    }

    /// The plays chosen, in the table's order.
    private func ordered(_ ids: Set<PersistentIdentifier>) -> [Capture] {
        rows.filter { ids.contains($0.persistentModelID) }
    }

    /// The row dragged, with the rest of the selection when it's part of it.
    private func drag(from capture: Capture) -> SongDrag {
        let dragged = selection.contains(capture.persistentModelID) ? ordered(selection) : [capture]
        return SongDrag(dragged.map {
            HistorySong(songID: $0.songID, title: $0.title, artistName: $0.artistName, albumTitle: $0.albumTitle, artworkURL: $0.artworkURL)
        })
    }

    /// Several plays: play them or queue them in the table's order, or delete them.
    @ViewBuilder
    private func selectionMenu(_ ids: Set<PersistentIdentifier>) -> some View {
        let chosen = ordered(ids)
        if playback.canPlay(chosen) {
            Button("Play", systemImage: "play") { playback.play(chosen) }
            if playback.canQueue {
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { playback.enqueue(chosen, next: true) }
                Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") { playback.enqueue(chosen, next: false) }
            }
        }
        if !model.isShowingSampleData {
            if playback.canPlay(chosen) { Divider() }
            Button("Delete ^[\(ids.count) Play](inflect: true)…", systemImage: "trash", role: .destructive) {
                pendingBulkDelete = ids
            }
        }
    }

    private func single(_ ids: Set<PersistentIdentifier>) -> Capture? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return rows.first { $0.persistentModelID == id }
    }

    private func deleteAll(_ ids: Set<PersistentIdentifier>) {
        for capture in rows where ids.contains(capture.persistentModelID) {
            try? model.store?.deletePlay(capture)
        }
        selection.removeAll()
    }

    @ViewBuilder
    private func scrobbleState(_ capture: Capture) -> some View {
        if !isScrobbling {
            EmptyView()
        } else if capture.scrobbledAt != nil {
            Image(systemName: "checkmark")
                .foregroundStyle(.secondary)
                .help("Scrobbled")
                .accessibilityLabel("Scrobbled")
        } else if capture.isHeldFromScrobbling {
            // Kept, but too short for Last.fm's rule: nothing went wrong, and nothing's waiting.
            Image(systemName: "minus")
                .foregroundStyle(.tertiary)
                .help("Not long enough for Last.fm to count")
                .accessibilityLabel("Not long enough for Last.fm to count")
        } else if capture.scrobbleAttempts >= TracksStore.maxScrobbleAttempts {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.orange)
                .help(capture.lastScrobbleError ?? "Last.fm didn't accept this one")
                .accessibilityLabel("Not scrobbled")
                .accessibilityValue(capture.lastScrobbleError ?? "Last.fm didn't accept this one")
        } else {
            Image(systemName: "clock")
                .foregroundStyle(.tertiary)
                .help("Waiting to be scrobbled")
                .accessibilityLabel("Waiting to be scrobbled")
        }
    }
}
