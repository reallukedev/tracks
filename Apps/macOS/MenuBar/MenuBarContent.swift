import SwiftUI
import SwiftData
import TracksCore
import TracksMusic

/// The window that drops down from the menu bar: what's playing, today at a glance, and the
/// last few songs.
///
/// The width is fixed and the scrolling part has a definite height. A `ScrollView` has no
/// intrinsic height and a `.window` MenuBarExtra sizes itself to its content, so without one
/// the list collapsed to nothing (see docs/PlatformNotes.md).
struct MenuBarContent: View {
    let model: AppModel
    let monitor: NowPlayingMonitor

    static let width: CGFloat = 340

    var body: some View {
        if let store = model.store, let capture = model.capture, let playback = model.playback {
            MenuBarBody(monitor: monitor)
                .frame(width: Self.width)
                .modelContainer(store.container)
                .environment(model)
                .environment(capture)
                .environment(playback)
                .environment(model.player)
                .environment(model.playFeed)
        } else {
            ContentUnavailableView {
                Label("Tracks Can't Open Your History", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Quit Tracks and open it again. If that doesn’t help, restart your Mac.")
            }
            .frame(width: Self.width)
            .padding(.vertical)
        }
    }
}

private struct MenuBarBody: View {
    let monitor: NowPlayingMonitor
    @Environment(PlayerModel.self) private var player
    @Environment(CaptureService.self) private var capture
    @Environment(UnexpectedQuitMonitor.self) private var quitMonitor
    /// Only what the list shows. Today's figures have their own query in ``TodaySummary``,
    /// so opening the menu never loads the whole history.
    @Query private var recent: [Capture]
    /// The day ``TodaySummary`` counts. Moved on at midnight and whenever the window opens,
    /// since the window's views can outlive the day they were made on.
    @State private var day = Calendar.current.startOfDay(for: .now)
    @Environment(\.isOnScreen) private var isOnScreen

    static let recentLimit = 12

    init(monitor: NowPlayingMonitor) {
        self.monitor = monitor
        var descriptor = FetchDescriptor<Capture>(sortBy: [SortDescriptor(\.capturedAt, order: .reverse)])
        descriptor.fetchLimit = Self.recentLimit
        _recent = Query(descriptor)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tracks’ own player, while it has something on; Music otherwise.
            Group {
                if player.hasQueue {
                    TracksPlayerHeader()
                } else {
                    NowPlayingHeader(monitor: monitor, latest: recent.first)
                }
            }
            .padding(14)

            NearbyMenuSection()

            if quitMonitor.notice != nil {
                UnexpectedQuitNotice()
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }

            if !capture.isRunning {
                HistoryPausedNote()
            }

            PlaybackErrorNote()

            Divider().padding(.horizontal, 14)

            // A new identity each day, so the query's cutoff moves with it.
            TodaySummary(day: day)
                .id(day)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            Divider().padding(.horizontal, 14)

            RecentList(captures: recent)

            Divider()

            MenuBarFooter()
        }
        // Polling Music costs an Apple event, so only while the window is open. The panel's
        // views outlive its closing, so `.task` alone would keep polling after it.
        .task(id: isOnScreen) {
            guard isOnScreen else { return }
            moveToToday()
            await monitor.follow()
        }
        // Posted on whichever thread noticed the change, so read on the main actor.
        .task {
            for await _ in NotificationCenter.default.notifications(named: .NSCalendarDayChanged) {
                moveToToday()
            }
        }
    }

    private func moveToToday() {
        let today = Calendar.current.startOfDay(for: .now)
        if today != day { day = today }
    }
}

/// Says capture is paused, where it can't be missed, with the way back.
private struct HistoryPausedNote: View {
    @Environment(CaptureService.self) private var capture

    var body: some View {
        HStack(spacing: 8) {
            Label("History paused. Songs you play aren't being kept.", systemImage: "record.circle")
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Resume") { Task { await capture.resume() } }
                .controlSize(.small)
                .accessibilityLabel("Resume History")
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }
}

// MARK: - Now playing

/// What Tracks itself is playing, with its controls, in the shape of Music's card below.
private struct TracksPlayerHeader: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(CaptureSettings.showsMenuBarProgressKey, store: CaptureSettings.sharedDefaults)
    private var showsProgress = true
    @State private var previousPresses = 0
    @State private var nextPresses = 0

    var body: some View {
        if let track = player.current {
            VStack(spacing: 12) {
                MenuBarSongButton(songIdentity: track.songIdentity) {
                    CoverImage(cover: track.cover, size: 58)
                    VStack(alignment: .leading, spacing: 2) {
                        Label {
                            Text(player.context.map { "\($0.title)" } ?? String(localized: "Playing in Tracks"))
                        } icon: {
                            PlayingWaveform(isActive: player.isPlaying)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                        Text(track.title)
                            .font(.headline)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(track.artistName)
                                .lineLimit(1)
                            PlayCountLine(track: track, showsSince: false)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
                .animation(LiveUpdate.animation(reduceMotion: reduceMotion), value: track.id)

                if showsProgress, let duration = track.duration, duration > 0 {
                    MenuBarProgress(
                        duration: duration,
                        isPlaying: player.isPlaying,
                        time: { player.playbackTime },
                        onSeek: { player.seek(to: $0) }
                    )
                    .id(track.id)
                }

                GlassEffectContainer(spacing: 18) {
                    HStack(spacing: 18) {
                        Button {
                            previousPresses += 1
                            player.skipToPrevious()
                        } label: {
                            SkipArrows(direction: .backward, height: 11, trigger: previousPresses)
                                .frame(width: 18, height: 18)
                        }
                        .disabled(player.context?.isStation == true)
                        .help("Previous")
                        .accessibilityLabel("Previous")

                        Button {
                            player.togglePlayPause()
                        } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                                .frame(width: 24, height: 24)
                        }
                        .keyboardShortcut(.space, modifiers: [])
                        .help(player.isPlaying ? "Pause" : "Play")
                        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                        Button {
                            nextPresses += 1
                            player.skipToNext()
                        } label: {
                            SkipArrows(direction: .forward, height: 11, trigger: nextPresses)
                                .frame(width: 18, height: 18)
                        }
                        .help("Next")
                        .accessibilityLabel("Next")
                    }
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
            }
        }
    }
}

private struct NowPlayingHeader: View {
    let monitor: NowPlayingMonitor
    let latest: Capture?
    @Environment(CaptureService.self) private var capture
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(CaptureSettings.showsMenuBarProgressKey, store: CaptureSettings.sharedDefaults)
    private var showsProgress = true

    var body: some View {
        VStack(spacing: 12) {
            MenuBarSongButton(songIdentity: songIdentity) {
                artwork
                    .opacity(isStale ? 0.55 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    sourceLine
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .opacity(isStale ? 0.7 : 1)
            }
            // The next song crossfades in rather than snapping.
            .animation(LiveUpdate.animation(reduceMotion: reduceMotion), value: title)

            // Only for the song Music has on, playing or paused, when it says how long that
            // is: a station has no length, and the last song kept isn't on.
            if showsProgress, capture.nowPlaying != nil, monitor.music.state == .playing || monitor.music.state == .paused,
               !monitor.music.isRadio, let duration = monitor.music.duration, monitor.music.position != nil {
                MenuBarProgress(
                    duration: duration,
                    isPlaying: monitor.music.isPlaying,
                    time: { monitor.position() ?? 0 },
                    onSeek: { monitor.seek(to: $0) }
                )
                .id(title)
            }

            TransportControls(monitor: monitor)
        }
    }

    // What to show, in order of preference: what Music is playing (captured or not yet),
    // then the last song Tracks kept.

    /// Nothing is audible, as far as we know. Before the first read we don't claim either way.
    private var isStale: Bool {
        monitor.hasRead && !monitor.music.isPlaying
    }

    /// The song shown, for its page in the main window. Nil before anything has played.
    private var songIdentity: String? {
        if let song = capture.nowPlaying { return HistoryImport.key(title: song.title, artistName: song.artistName) }
        return latest.map { HistoryImport.key(title: $0.title, artistName: $0.artistName) }
    }

    private var title: String {
        if let song = capture.nowPlaying { return song.title }
        return latest?.title ?? String(localized: "Nothing Played Yet")
    }

    private var subtitle: String {
        if let song = capture.nowPlaying {
            return [song.artistName, song.albumTitle].compactMap { $0 }.joined(separator: " · ")
        }
        guard let latest else { return String(localized: "Play something in Music") }
        return [latest.artistName, latest.albumTitle].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var artwork: some View {
        if let song = capture.nowPlaying {
            ArtworkView(url: song.artworkURL, seed: song.albumTitle ?? song.title, size: 58)
        } else if let latest {
            ArtworkView(url: latest.artworkURL, seed: latest.albumTitle ?? latest.title, size: 58)
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.quaternary)
                .frame(width: 58, height: 58)
                .overlay { Image(systemName: "music.note").foregroundStyle(.secondary) }
                .accessibilityHidden(true)
        }
    }

    /// "Radio · Chill Station", "Now Playing", or why nothing is.
    @ViewBuilder
    private var sourceLine: some View {
        Group {
            if !capture.isRunning {
                // Not a pause glyph: that reads as the music being paused.
                Label("History Paused", systemImage: "record.circle")
                    .foregroundStyle(.orange)
            } else if isStale {
                Label("Last Played", systemImage: "clock")
                    .foregroundStyle(.secondary)
            } else if monitor.music.isRadio {
                Label(radioLine, systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.pink)
            } else {
                Label {
                    Text("Now Playing")
                } icon: {
                    PlayingWaveform(isActive: monitor.music.isPlaying)
                }
                .foregroundStyle(.tint)
            }
        }
        .font(.caption.weight(.semibold))
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
    }

    private var radioLine: String {
        let station = capture.currentStation ?? String(localized: "Radio")
        if let session = capture.openSession, let count = session.captures?.count, count > 0 {
            return String(AttributedString(localized: "\(station) · ^[\(count) song](inflect: true)").characters)
        }
        return station
    }
}

/// The song at the top of the menu: a click opens its page in the main window and closes the
/// menu, as clicking the song in Music's mini player shows it. It highlights under the pointer
/// as the rows below do.
private struct MenuBarSongButton<Content: View>: View {
    /// Nil before anything has played, when there's no page to open.
    let songIdentity: String?
    @ViewBuilder var content: Content
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var isHovered = false

    var body: some View {
        Button {
            guard let songIdentity else { return }
            model.pendingRoute = .song(songIdentity)
            MainWindow.bringForward(openWindow: openWindow)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                content
                Spacer(minLength: 0)
            }
            .padding(6)
            .contentShape(.rect)
            .background(.quaternary.opacity(isHovered && songIdentity != nil ? 0.6 : 0), in: .rect(cornerRadius: 10))
            .padding(-6)
        }
        .buttonStyle(.plain)
        // Not disabled: that would grey out "Nothing Played Yet" too.
        .allowsHitTesting(songIdentity != nil)
        .onHover { isHovered = $0 }
        .help("Show in Tracks")
        .accessibilityHint("Opens the song in Tracks")
    }
}

/// Why the song someone just clicked didn't start. Shown for a few seconds, and only for a
/// failure that happens while the window is open, not a stale one from earlier.
private struct PlaybackErrorNote: View {
    @Environment(PlaybackController.self) private var playback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var message: String?
    @State private var isArmed = false

    var body: some View {
        Group {
            if let message {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .task(id: playback.lastError) {
            defer { isArmed = true }
            guard isArmed, let error = playback.lastError else { return }
            withAnimation(LiveUpdate.animation(reduceMotion: reduceMotion)) { message = error }
            try? await Task.sleep(for: .seconds(6))
            withAnimation(LiveUpdate.animation(reduceMotion: reduceMotion)) { message = nil }
        }
    }
}

// MARK: - Today

/// Today's songs, listening time and streak, from today's rows only.
private struct TodaySummary: View {
    let day: Date
    @Query private var todays: [Capture]
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stats: TodayStats?

    init(day: Date) {
        self.day = day
        _todays = Query(filter: #Predicate<Capture> { $0.capturedAt >= day }, sort: \Capture.capturedAt)
    }

    var body: some View {
        TodayStrip(stats: stats ?? TodayStats())
            .task(id: "\(todays.count)|\(todays.last?.capturedAt.timeIntervalSinceReferenceDate ?? 0)") {
                let next = TodayStats(
                    todays: todays,
                    streak: TodayStats.currentStreak(day: day, playedToday: !todays.isEmpty, context: context)
                )
                LiveUpdate.apply(isLive: stats != nil, reduceMotion: reduceMotion) { stats = next }
            }
    }
}

private struct TodayStats: Equatable {
    var songs = 0
    var seconds: TimeInterval = 0
    var streak = 0

    init() {}

    /// - Parameter todays: today's rows, oldest first.
    init(todays: [Capture], streak: Int) {
        let stats = todays.map(\.stat)
        songs = stats.count
        seconds = ListeningEstimate.seconds(for: stats).reduce(0, +)
        self.streak = streak
    }

    /// Days in a row with a play, counted back from today, or from yesterday when nothing has
    /// played yet today: the current streak as ``StatsCalculator/streak(in:calendar:now:)``
    /// counts it.
    ///
    /// Reads only play dates, a few weeks at a time and further back only while the streak
    /// continues, instead of loading the whole history.
    static func currentStreak(
        day: Date,
        playedToday: Bool,
        context: ModelContext,
        calendar: Calendar = .current
    ) -> Int {
        var run = playedToday ? 1 : 0
        var days = Set<Date>()
        var fetchedFrom = day
        var span = 32
        guard var cursor = calendar.date(byAdding: .day, value: -1, to: day) else { return run }

        while true {
            if cursor < fetchedFrom {
                guard let from = calendar.date(byAdding: .day, value: -span, to: fetchedFrom) else { break }
                let upTo = fetchedFrom
                var descriptor = FetchDescriptor<Capture>(
                    predicate: #Predicate { $0.capturedAt >= from && $0.capturedAt < upTo }
                )
                descriptor.propertiesToFetch = [\.capturedAt]
                let rows = (try? context.fetch(descriptor)) ?? []
                days.formUnion(rows.map { calendar.startOfDay(for: $0.capturedAt) })
                fetchedFrom = from
                span *= 2
            }
            guard days.contains(cursor),
                  let before = calendar.date(byAdding: .day, value: -1, to: cursor)
            else { break }
            run += 1
            cursor = before
        }
        return run
    }
}

private struct TodayStrip: View {
    let stats: TodayStats

    var body: some View {
        HStack(spacing: 0) {
            stat(value: stats.songs.formatted(), label: "Songs Today", symbol: "music.note", tint: .accentColor)
            stat(value: Format.listening(stats.seconds), label: "Listening", symbol: "headphones", tint: .blue)
            stat(
                value: String(AttributedString(localized: "^[\(stats.streak) day](inflect: true)").characters),
                label: "Streak",
                symbol: "flame.fill",
                tint: .orange
            )
        }
    }

    private func stat(value: String, label: LocalizedStringKey, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Recent

private struct RecentList: View {
    let captures: [Capture]
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(PlaybackController.self) private var playback
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    /// Which rows Music can play, found when the window opens. Music can only be told to
    /// play songs in the library; the rest are opened in Music instead. Missing while
    /// unknown, which is treated as playable: a click finds out and falls back.
    @State private var isInLibrary: [PersistentIdentifier: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Recently Played")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Show All") {
                    model.sidebarSelection = .history
                    MainWindow.bringForward(openWindow: openWindow)
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .font(.subheadline)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            if captures.isEmpty {
                Text("Songs you play in Music show up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(captures) { item in
                            row(item)
                                .transition(.push(from: .top))
                                .contextMenu { menu(for: item) }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                    // A new song pushes in at the top and the rest slide down to make room.
                    .animation(LiveUpdate.animation(reduceMotion: reduceMotion), value: captures.map(\.persistentModelID))
                }
            }
        }
        .frame(height: 300)
        .task(id: captures.map(\.persistentModelID)) { await checkLibrary() }
    }

    /// One round of Apple events for every row that could be played or opened.
    private func checkLibrary() async {
        let rows = captures.filter { !$0.songID.isEmpty && isInLibrary[$0.persistentModelID] == nil }
        guard !rows.isEmpty else { return }
        let tracks = rows.map { MusicLibraryPlayback.Track(name: $0.title, artist: $0.artistName) }
        let playlist = CaptureSettings().playlistName
        guard case .success(let locations) = await ScriptingQueue.run({
            MusicLibraryPlayback.locateAll(tracks, inPlaylist: playlist)
        }) else { return }
        for (row, location) in zip(rows, locations) {
            isInLibrary[row.persistentModelID] = location != .missing
        }
    }

    /// Whether this row's song can only be opened, not played.
    private func opensInMusic(_ item: Capture) -> Bool {
        isInLibrary[item.persistentModelID] == false
    }

    /// Plays the song, or opens it in Music when it isn't in the library. The playback
    /// service makes the same call, so a row that wasn't checked yet still does the right one.
    private func activate(_ item: Capture) {
        if opensInMusic(item) {
            MusicLibraryPlayback.openInMusic(songID: item.songID)
        } else {
            Task { await playback.play(item) }
        }
    }

    /// Clicking plays the song. One the catalog never identified can't be played, so it
    /// isn't a button; its menu still leads to the stats.
    @ViewBuilder
    private func row(_ item: Capture) -> some View {
        if item.songID.isEmpty {
            RecentRow(capture: item)
        } else {
            Button {
                activate(item)
            } label: {
                RecentRow(capture: item)
            }
            // The system's own press feedback. Rows are content, so no glass: that's for
            // the controls floating above it.
            .buttonStyle(.plain)
            .help(opensInMusic(item) ? "Open in Music" : "Play")
            .accessibilityHint(opensInMusic(item) ? "Opens the song in Music" : "Plays the song")
        }
    }

    /// The song's menu, as everywhere else, with its pages opening in the main window.
    private func menu(for item: Capture) -> some View {
        let song = MixSong(item)
        let artist = StatsCalculator.folded(item.artistName)
        var actions = SongActions(
            stats: { show(.song(song.songIdentity)) },
            share: .song(id: item.songID, title: item.title, artist: item.artistName),
            suggestLess: song.songIdentity,
            block: item.artistName
        )
        if !item.songID.isEmpty {
            if opensInMusic(item) {
                actions.reveal.append(SongMenuButton(title: "Show in Music", systemImage: "arrow.up.forward.app") { activate(item) })
            } else {
                actions.play = { activate(item) }
                // No API can take a song back out of a playlist, so point at the app that can.
                actions.reveal.append(SongMenuButton(title: "Show in Music", systemImage: "arrow.up.forward.app") {
                    MusicLibraryPlayback.openInMusic(songID: item.songID)
                })
            }
        }
        if let album = item.albumTitle.map(StatsCalculator.folded), !album.isEmpty {
            actions.goToAlbum = { show(.album("\(album)\u{1F}\(artist)")) }
        }
        actions.goToArtist = { show(.artist(artist)) }
        return SongMenuItems(actions)
    }

    /// Opens a page in the main window and closes this one.
    private func show(_ route: Route) {
        model.pendingRoute = route
        MainWindow.bringForward(openWindow: openWindow)
        dismiss()
    }
}

/// A compact history row that highlights on hover, like a menu item.
private struct RecentRow: View {
    let capture: Capture
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(url: capture.artworkURL, seed: capture.albumTitle ?? capture.title, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(capture.title)
                    .font(.callout)
                    .lineLimit(1)
                HStack(spacing: 3) {
                    if capture.kind == .radio {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.pink)
                            .accessibilityLabel("Radio")
                    }
                    Text(capture.artistName)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(Format.relativeTime(capture.capturedAt))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        // The whole row is the click target, not just its text.
        .contentShape(.rect)
        .background(isHovering ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7))
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Footer

struct MenuBarFooter: View {
    @Environment(CaptureService.self) private var capture
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    /// Closes the menu bar window. Anything that brings up another window calls it, so the
    /// menu doesn't stay open over what it just opened.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 6) {
            Button("Open Tracks") {
                MainWindow.bringForward(openWindow: openWindow)
                dismiss()
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)

            Spacer()

            // Glass circles, like the transport controls, so every control here answers a
            // press the same way. Plain glyphs: a circled one inside a circle reads double.
            Group {
                // A record glyph, not pause and play: those sit just above on the transport
                // controls and would read as pausing the music. The one circled glyph here,
                // since without its ring a record symbol is only a dot. Red while history is
                // being kept, like a recording light.
                Button(capture.isRunning ? "Pause History" : "Resume History",
                       systemImage: capture.isRunning ? "record.circle.fill" : "record.circle") {
                    if capture.isPaused { Task { await capture.resume() } } else { capture.pause() }
                }
                .foregroundStyle(capture.isRunning ? AnyShapeStyle(.red) : AnyShapeStyle(.orange))
                .accessibilityValue(capture.isRunning ? "Keeping what you play" : "Paused")
                .help(capture.isRunning ? "Pause History: stop keeping what you play for now" : "Resume History: keep what you play again")
                Button("Settings", systemImage: "gearshape") {
                    Self.bringSettingsForward(openSettings: openSettings)
                    dismiss()
                }
                .help("Settings")
                Button("Quit Tracks", systemImage: "power") { NSApp.terminate(nil) }
                    .help("Quit Tracks")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
        }
        .padding(12)
    }

    /// Opens Settings and puts it in front.
    ///
    /// `openSettings()` on its own makes the window but leaves Tracks in the background, which
    /// from the menu bar it almost always is. The window then sat behind whatever the user
    /// was in and only appeared when they pressed "Open Tracks", which activates Tracks as a
    /// side effect. Activating first means SwiftUI opens the window into an app that is
    /// already frontmost; the second pass covers a window that was made before the activation
    /// landed, and raises one left over from a previous visit.
    static func bringSettingsForward(openSettings: OpenSettingsAction) {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow?.makeKeyAndOrderFront(nil)
        }
    }

    /// The window the `Settings` scene puts up.
    ///
    /// SwiftUI gives it no public identity; AppKit calls it `com_apple_SwiftUI_Settings_window`.
    /// Matched loosely so a rename between releases doesn't quietly stop this working. No
    /// other Tracks window has "Settings" in its identifier. A miss is harmless: the window
    /// may not exist yet, and activation alone usually brings it up.
    private static var settingsWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.contains("Settings") == true }
    }
}
