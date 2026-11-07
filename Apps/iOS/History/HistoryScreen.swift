import SwiftUI
import SwiftData
import TracksCore

/// Every play, newest first, grouped by day.
///
/// Reads a page of plays at a time, and the next page as the end of the list scrolls into
/// view, so opening History costs the same however long the history is.
struct HistoryScreen: View {
    @Environment(AppModel.self) private var model
    @State private var filter: HistoryFilter = LaunchScene.historyFilter.flatMap(HistoryFilter.init(rawValue:)) ?? .all
    @State private var limit = HistoryPage.size
    @State private var pendingDelete: Capture?
    @State private var isScrobbling = false
    /// Written last when Settings connects or disconnects Last.fm, so the rows follow it.
    @AppStorage(LastFMSessionStore.usernameDefaultsKey, store: CaptureSettings.sharedDefaults)
    private var lastFMUsername: String?
    private var sources = SourceScopeSetting()

    var body: some View {
        HistoryList(
            filter: filter,
            source: sources.scope,
            limit: limit,
            isScrobbling: isScrobbling,
            canDelete: !model.isShowingSampleData,
            pendingDelete: $pendingDelete,
            loadMore: { limit += HistoryPage.size }
        )
        .navigationTitle("History")
        .sourceScopeSubtitle(sources.scope)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Filter", systemImage: isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease") {
                    Picker("Show", selection: $filter) {
                        ForEach(HistoryFilter.allCases) { filter in
                            Label(filter.title, systemImage: filter.symbol).tag(filter)
                        }
                    }
                    if sources.isOffered {
                        Section("Music") {
                            Picker("Music", selection: sources.selection) {
                                ForEach(SourceScope.allCases) { scope in
                                    Label(scope.title, systemImage: scope.symbol).tag(scope)
                                }
                            }
                        }
                    }
                }
            }
        }
        .deleteConfirmation(for: $pendingDelete)
        // A different filter starts again from the top.
        .onChange(of: filter) { limit = HistoryPage.size }
        .onChange(of: sources.scope) { limit = HistoryPage.size }
        .onChange(of: lastFMUsername, initial: true) {
            isScrobbling = LastFMSessionStore.current != nil
        }
    }

    private var isFiltered: Bool {
        filter != .all || sources.scope != .all
    }
}

/// The list itself, whose query is rebuilt when the filter or the page count changes.
private struct HistoryList: View {
    let filter: HistoryFilter
    let source: SourceScope
    let limit: Int
    let isScrobbling: Bool
    let canDelete: Bool
    @Binding var pendingDelete: Capture?
    let loadMore: () -> Void

    /// Animated, so a song that just finished slides in at the top.
    @Query private var captures: [Capture]
    /// The list's sections, grouped once per change rather than on every render.
    @State private var groupedDays = Memo<HistoryDaysKey, [HistoryDay]>()
    /// Bumped by each save and each batch of synced changes, which can move a play between
    /// filters without changing how many plays there are.
    @State private var storeChanges = 0
    @Environment(\.modelContext) private var context

    init(
        filter: HistoryFilter,
        source: SourceScope,
        limit: Int,
        isScrobbling: Bool,
        canDelete: Bool,
        pendingDelete: Binding<Capture?>,
        loadMore: @escaping () -> Void
    ) {
        self.filter = filter
        self.source = source
        self.limit = limit
        self.isScrobbling = isScrobbling
        self.canDelete = canDelete
        _pendingDelete = pendingDelete
        self.loadMore = loadMore
        _captures = Query(filter.descriptor(source: source, limit: limit), animation: .default)
    }

    var body: some View {
        List {
            ForEach(days, id: \.day) { day in
                Section {
                    ForEach(day.captures) { capture in
                        NavigationLink(value: Route.song(HistoryImport.key(title: capture.title, artistName: capture.artistName))) {
                            CaptureRow(capture: capture, showsScrobbleState: isScrobbling)
                        }
                        .swipeActions(edge: .trailing) {
                            if canDelete {
                                // Not `role: .destructive`: that removes the row the moment
                                // it's tapped, before the confirmation. The rows then no
                                // longer match the query and the list throws when the
                                // delete lands, or strands the row if it's cancelled.
                                Button("Delete", systemImage: "trash") {
                                    pendingDelete = capture
                                }
                                .tint(.red)
                            }
                        }
                        .contextMenu { PlayActions(capture: capture, onDelete: { pendingDelete = capture }) }
                        .onAppear {
                            if hasMore, capture.persistentModelID == captures.last?.persistentModelID {
                                loadMore()
                            }
                        }
                    }
                } header: {
                    DayHeader(day: day.day, count: day.count)
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if captures.isEmpty {
                if filter == .all, source != .all {
                    ContentUnavailableView("Nothing from \(Text(source.title))", systemImage: source.symbol)
                } else if filter == .all {
                    ContentUnavailableView(
                        "No History Yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Songs you play in Apple Music will collect here.")
                    )
                } else {
                    ContentUnavailableView("No \(Text(filter.title))", systemImage: filter.symbol)
                }
            }
        }
        .onStoreChange(of: context) { storeChanges += 1 }
        // Day headers move at midnight even when no play does.
        .task {
            for await _ in NotificationCenter.default.notifications(named: .NSCalendarDayChanged) {
                storeChanges += 1
            }
        }
    }

    /// Whether the page is full, so there may be older plays still to read.
    private var hasMore: Bool {
        captures.count >= limit
    }

    /// Worked out in the same pass as the query it comes from, so a deleted play is never
    /// drawn from a stale copy.
    private var days: [HistoryDay] {
        groupedDays.value(for: daysKey) {
            var days = HistoryDay.group(captures)
            // The oldest day on the page may carry on past it, so its count comes from the
            // store rather than from the rows that happen to be loaded.
            if hasMore, let last = days.last,
               let interval = Calendar.current.dateInterval(of: .day, for: last.day),
               let count = try? context.fetchCount(filter.descriptor(in: interval, source: source)) {
                days[days.count - 1].count = count
            }
            return days
        }
    }

    /// What the sections depend on, cheap to compare: the query's size and ends rather
    /// than every row, plus the store's saves for changes in place.
    private var daysKey: HistoryDaysKey {
        HistoryDaysKey(
            count: captures.count,
            newest: captures.first?.persistentModelID,
            oldest: captures.last?.persistentModelID,
            storeChanges: storeChanges,
            filter: filter,
            source: source
        )
    }
}

struct HistoryDaysKey: Equatable {
    var count: Int
    var newest: PersistentIdentifier?
    var oldest: PersistentIdentifier?
    var storeChanges: Int
    var filter: HistoryFilter
    var source: SourceScope
}

/// One day's plays, newest first.
struct HistoryDay {
    let day: Date
    var captures: [Capture]
    /// How many plays the day has in all, which for the last day on a page can be more than
    /// are loaded.
    var count: Int

    /// Groups plays that are already newest first by the day they were played.
    static func group(_ captures: [Capture], calendar: Calendar = .current) -> [HistoryDay] {
        var groups: [HistoryDay] = []
        var days = CalendarUnitCursor(calendar: calendar, unit: .day)
        for capture in captures {
            let day = days.start(of: capture.capturedAt) ?? calendar.startOfDay(for: capture.capturedAt)
            if groups.last?.day == day {
                groups[groups.count - 1].captures.append(capture)
                groups[groups.count - 1].count += 1
            } else {
                groups.append(HistoryDay(day: day, captures: [capture], count: 1))
            }
        }
        return groups
    }
}

struct DayHeader: View {
    let day: Date
    let count: Int

    var body: some View {
        AdaptiveStack {
            Text(Format.day(day))
            Spacer(minLength: 0)
            Text("^[\(count) song](inflect: true)")
                .monospacedDigit()
        }
    }
}
