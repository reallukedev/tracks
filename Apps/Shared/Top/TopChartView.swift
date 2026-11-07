import SwiftUI
import TracksCore

/// Top songs, artists or albums for any day, week, month or year, or all time.
///
/// The page travels through time: the arrows step to the nearest period with listening, the
/// title opens a calendar to pick any day, and Today (or This Week) comes back. Each entry
/// shows how it moved since the period before, and the chart plays in order or shuffled.
struct TopChartView: View {
    let kind: ChartKind
    /// When set, a Songs / Artists / Albums switcher sits at the top of the list.
    var kindSelection: Binding<ChartKind>?
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openPlayRoute) private var openPlayRoute
    @AppStorage(ChartSpan.storageKey) private var span: ChartSpan = .week
    /// A day inside the period on show, or nil to follow now as the days go by.
    @State private var anchor: Date? = LaunchScene.chartDate
    @State private var snapshot: ChartSnapshot?
    @State private var isPickingDate = false
    /// The page's width, to choose between its column layout and its stacked one.
    @State private var width: CGFloat = 0
    private var sources = SourceScopeSetting()
    private var playback = ChartPlayback()

    init(kind: ChartKind, kindSelection: Binding<ChartKind>? = nil) {
        self.kind = kind
        self.kindSelection = kindSelection
    }

    private var period: ChartPeriod {
        ChartPeriod.containing(anchor ?? .now, span: span)
    }

    var body: some View {
        page
            .navigationTitle(kindSelection == nil ? kind.navigationTitle : "Charts")
            .sourceScopeSubtitle(sources.scope)
            .toolbar { toolbar }
            .task(id: "\(kind.rawValue)|\(span.rawValue)|\(period.interval?.start.timeIntervalSinceReferenceDate ?? 0)|\(sources.scope.rawValue)|\(model.library.revision)") {
                // Until the first read there's nothing to chart, and an empty chart would say
                // "No Charts Yet" to someone with years of listening.
                guard model.library.isLoaded else { return }
                let (kind, period, scope, history) = (kind, period, sources.scope, model.library.history)
                let next = await OffMainActor.run {
                    ChartSnapshot.make(kind: kind, period: period, scope: scope, history: history.scoped(to: scope))
                }
                guard !Task.isCancelled, next != snapshot else { return }
                // New listening in the same chart rolls in; a different chart just appears.
                let isLive = snapshot?.identity == next.identity && snapshot?.playCount != next.playCount
                LiveUpdate.apply(isLive: isLive, reduceMotion: reduceMotion) {
                    snapshot = next
                }
            }
    }

    // MARK: - Moving through time

    private func show(_ target: ChartPeriod?) {
        guard let target else { return }
        anchor = target.isCurrent() ? nil : target.interval?.start
    }

    /// The snapshot, only while it's the chart on screen. Between a switch and its new
    /// snapshot the old one would put last week's songs under this week's title, or songs
    /// in artist tiles.
    ///
    /// The steps wait for it too, so a quick double press can't run past the period it meant.
    private var shown: ChartSnapshot? {
        guard let snapshot, snapshot.kind == kind, snapshot.period == period, snapshot.scope == sources.scope else {
            return nil
        }
        return snapshot
    }
    private var hasEntries: Bool { shown?.entries.isEmpty == false }
    private var canGoBack: Bool { shown?.earlier != nil }
    private var canGoForward: Bool { shown?.later != nil }
    private var isCurrent: Bool { period.isCurrent() }

    private var earlierHelp: Text {
        Text("The \(Text(span.unitName)) before with listening")
    }

    private var laterHelp: Text {
        Text("The \(Text(span.unitName)) after with listening")
    }

    private var pickedDay: Binding<Date> {
        Binding(
            get: { anchor ?? .now },
            set: { day in
                anchor = Calendar.current.isDateInToday(day) ? nil : day
                isPickingDate = false
            }
        )
    }

    /// From the first play to today.
    private var pickableDays: ClosedRange<Date> {
        let first = model.library.history.first?.capturedAt ?? .now
        return min(first, .now)...Date.now
    }

    private var datePicker: some View {
        DatePicker("Go to Date", selection: pickedDay, in: pickableDays, displayedComponents: .date)
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding()
            #if os(iOS)
            .frame(minWidth: 320)
            .presentationCompactAdaptation(.popover)
            #else
            .frame(width: 280)
            #endif
    }

    /// The period's name, which opens the calendar.
    private var titleButton: some View {
        Button {
            isPickingDate = true
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(period.title())
                    .font(titleFont)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if span != .allTime {
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(span == .allTime)
        .help("Go to a date")
        .accessibilityHint(span == .allTime ? Text(verbatim: "") : Text("Opens a calendar to pick a date."))
        .popover(isPresented: $isPickingDate, arrowEdge: .bottom) { datePicker }
    }

    /// The dates the title leaves out, like the days of This Week.
    @ViewBuilder
    private var datesLine: some View {
        if let dates = period.dates() {
            Text(dates)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var playTitle: String {
        String(localized: "\(String(localized: kind.navigationTitleResource)), \(period.title())")
    }

    private var playButtons: some View {
        let songs = playback.playable(shown?.songs ?? [])
        return HStack(spacing: 10) {
            Button {
                playback.play(songs, title: playTitle)
            } label: {
                Label("Play", systemImage: "play.fill")
                    #if os(iOS)
                    .frame(maxWidth: .infinity)
                    #endif
            }
            .buttonStyle(.glassProminent)
            Button {
                playback.play(songs, shuffled: true, title: playTitle)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    #if os(iOS)
                    .frame(maxWidth: .infinity)
                    #endif
            }
            .buttonStyle(.glass)
        }
        .buttonBorderShape(.capsule)
        #if os(iOS)
        .controlSize(.large)
        #endif
        .disabled(songs.isEmpty)
        .help("Play the songs of this chart in order, or shuffled")
    }

    private func empty(_ snapshot: ChartSnapshot) -> some View {
        ContentUnavailableView {
            Label(snapshot.hasHistory ? snapshot.period.emptyTitle : "No Charts Yet", systemImage: "waveform")
        } description: {
            if !snapshot.hasHistory {
                Text("Your top \(Text(kind.title)) appear here once you've listened to some music.")
            } else if sources.scope != .all {
                Text("Nothing from \(Text(sources.scope.title)) was played in this \(Text(span.unitName)).")
            }
        } actions: {
            if let earlier = snapshot.earlier {
                Button("Go to \(earlier.title())") { show(earlier) }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
            }
            if !snapshot.period.isCurrent() {
                Button(span.currentLabel) { anchor = nil }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        #if os(macOS)
        // Calendar's controls, where Calendar has them: back, Today and forward together.
        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                Button("Earlier", systemImage: "chevron.backward") { show(shown?.earlier) }
                    .disabled(!canGoBack)
                    .help(Text("\(earlierHelp) (⌥⌘←)"))
                    // Through time. ⌘[ and ⌘] are the window's Back and Forward.
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button(span.currentLabel) { anchor = nil }
                    .disabled(isCurrent)
                    .help(Text("Go to \(Text(span.currentLabel)) (⌘T)"))
                    // Calendar's Go to Today.
                    .keyboardShortcut("t", modifiers: .command)
                Button("Later", systemImage: "chevron.forward") { show(shown?.later) }
                    .disabled(!canGoForward)
                    .help(Text("\(laterHelp) (⌥⌘→)"))
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            }
            .controlGroupStyle(.navigation)
        }
        ToolbarItem(placement: .principal) {
            spanPicker
                .fixedSize()
        }
        if sources.isOffered {
            ToolbarItem(placement: .primaryAction) {
                SourceScopeMenu(scope: sources.selection)
            }
        }
        #else
        if !isCurrent {
            ToolbarItem(placement: .topBarLeading) {
                Button(span.currentLabel) { anchor = nil }
            }
        }
        if sources.isOffered {
            ToolbarItem(placement: .topBarTrailing) {
                SourceScopeMenu(scope: sources.selection)
            }
        }
        #endif
    }

    private var spanPicker: some View {
        Picker("Period", selection: $span) {
            ForEach(ChartSpan.allCases) { span in
                Text(span.label).tag(span)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Page

    /// An artist's or album's songs from the period, most played first.
    private func playSongs(of entry: ChartEntry) {
        playback.play(songs(of: entry), title: entry.title)
    }

    private func songs(of entry: ChartEntry) -> [MixSong] {
        entry.song.map { [$0] } ?? entry.songs
    }

    private func canPlay(_ entry: ChartEntry) -> Bool {
        !playback.playable(songs(of: entry)).isEmpty
    }

    private func open(_ entry: ChartEntry) {
        openPlayRoute(.stats(entry.route))
    }

    private func open(_ period: ChartPeriod) {
        withAnimation(reduceMotion ? nil : .snappy) {
            if period.span != span { span = period.span }
            show(period)
        }
    }

    @ViewBuilder
    private var activity: some View {
        if let shown {
            // A period with nothing in it says so straight under its title: a card of zeros
            // and an empty chart would push that below the fold.
            if !shown.entries.isEmpty || shown.activity.plays > 0 {
                ChartActivityCard(kind: kind, period: period, activity: shown.activity, entries: shown.entries, open: open)
            }
        } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.cardFill)
                .frame(height: 290)
        }
    }

    @ViewBuilder
    private var chart: some View {
        if let shown {
            if shown.entries.isEmpty {
                empty(shown)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                switch kind {
                case .songs: ChartList(entries: shown.entries, open: open)
                case .artists: ArtistChartGrid(entries: shown.entries, open: open, canPlay: canPlay, play: playSongs(of:))
                case .albums: AlbumChartGrid(entries: shown.entries, open: open, canPlay: canPlay, play: playSongs(of:))
                }
            }
        } else {
            LoadingRows()
        }
    }

    #if os(iOS)
    private var titleFont: Font { .title.bold() }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(spacing: 12) {
                    if let kindSelection {
                        Picker("Chart", selection: kindSelection) {
                            ForEach(ChartKind.allCases) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    spanPicker
                }

                header
                activity
                if hasEntries {
                    playButtons
                }
                chart
            }
            .padding(.horizontal, PlayMetrics.margin)
            .padding(.bottom, 24)
        }
        .background(Color.pageBackground)
    }

    /// The period's name and dates, with the steps either side.
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                titleButton
                datesLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if span != .allTime {
                HStack(spacing: 8) {
                    Button("Earlier", systemImage: "chevron.backward") { show(shown?.earlier) }
                        .disabled(!canGoBack)
                        .accessibilityHint(earlierHelp)
                    Button("Later", systemImage: "chevron.forward") { show(shown?.later) }
                        .disabled(!canGoForward)
                        .accessibilityHint(laterHelp)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .fontWeight(.semibold)
            }
        }
    }
    #else
    private var titleFont: Font { .largeTitle.bold() }

    /// On a wide window the period sits in a column of its own beside the chart, as a
    /// dashboard does; narrower, one above the other.
    private var page: some View {
        Group {
            if width >= 1_100 {
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            VStack(alignment: .leading, spacing: 14) {
                                headerTitle
                                if hasEntries { playButtons }
                            }
                            activity
                        }
                        .padding(PlayMetrics.margin)
                    }
                    .scrollIndicators(.never)
                    .frame(width: 460)

                    ScrollView {
                        chart
                            .frame(maxWidth: kind == .songs ? 960 : .infinity, alignment: .leading)
                            .padding(.leading, kind == .songs ? 8 : 18)
                            .padding(.trailing, PlayMetrics.margin - 10)
                            .padding(.vertical, PlayMetrics.margin - 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(alignment: .bottom, spacing: 16) {
                            headerTitle
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if hasEntries { playButtons }
                        }
                        activity
                        chart
                            // A song row's highlight reaches past the text's margin.
                            .padding(.horizontal, kind == .songs ? -10 : 0)
                    }
                    .padding(.horizontal, PlayMetrics.margin)
                    .padding(.vertical, 20)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(Color.pageBackground)
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            titleButton
            datesLine
        }
    }
    #endif
}

extension ChartKind {
    /// "Top Songs", as a resource, for building a sentence around it.
    var navigationTitleResource: LocalizedStringResource {
        switch self {
        case .songs: "Top Songs"
        case .artists: "Top Artists"
        case .albums: "Top Albums"
        }
    }
}
