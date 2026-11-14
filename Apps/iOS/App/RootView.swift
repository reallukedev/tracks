import SwiftUI
import MusicKit
import TracksCore
import TracksMusic

struct RootView: View {
    @Bindable var model: AppModel
    @AppStorage(PlayPreferences.songDestinationKey) private var songDestination = SongDestination.tracks
    @State private var summaryPath = LaunchScene.route.map { NavigationPath([$0]) } ?? NavigationPath()
    /// So a link inside a row, like an artist's name on a collaboration, can push.
    @State private var historyPath = NavigationPath()
    @State private var chartsPath = NavigationPath()
    /// Where the app opens also decides where Play sits: first when it's where Tracks opens,
    /// last otherwise, so the opening tab is always far left.
    @AppStorage(OpeningTab.storageKey) private var openingTab: OpeningTab = .standard
    @State private var showsNowPlaying = false
    @State private var nowPlayingReopens = 0
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasInBackground = false
    /// The tab open when iOS last saved the scene. iOS keeps it when it ends Tracks in the
    /// background and drops it when someone swipes Tracks away, so a quiet relaunch comes
    /// back where you were and a fresh start opens where Settings says.
    @SceneStorage("selectedTab") private var savedTab = ""

    var body: some View {
        if let store = model.store, let capture = model.capture, let playback = model.playback {
            @Bindable var player = model.player
            let navigator = model.playNavigator
            // A stable identity per tab, so moving Play between the ends keeps each tab's
            // state, and any sheet open on it, rather than rebuilding it.
            TabView(selection: $model.selectedTab) {
                ForEach(tabOrder, id: \.self) { tab in
                    Tab(tab.title, systemImage: tab.symbol, value: tab) {
                        stack(for: tab, navigator: navigator)
                    }
                }
                // At the bar's far end, on its own, as in Music.
                Tab(value: AppTab.search, role: .search) {
                    stack(for: .search, navigator: navigator)
                }
            }
            .tabBarMinimizeBehavior(.onScrollDown)
            .tabViewBottomAccessory(isEnabled: player.hasQueue || model.controlledDevice != nil) {
                // Another device's song while it's the one being controlled, as Spotify
                // Connect shows it; otherwise this iPhone's.
                if let device = model.controlledDevice {
                    RemoteMiniPlayer(device: device)
                } else {
                    MiniPlayer(open: openNowPlaying)
                }
            }
            .fullScreenCover(isPresented: $showsNowPlaying) {
                NowPlayingView(onNavigate: go(to:), reopenRequests: nowPlayingReopens)
                    // Clear, so the tabs show above the player as it's pulled down.
                    .presentationBackground(.clear)
                    .songInfoSheet(model) { route in
                        showsNowPlaying = false
                        go(to: .play(route))
                    }
            }
            #if DEBUG
            .overlay {
                if let style = BackdropLab.requested {
                    BackdropLab(style: style).ignoresSafeArea()
                }
            }
            #endif
            // The song a shake finds plays in Now Playing, so you see what it is.
            .shakeToPlay(model.player, onPlay: openNowPlaying)
            // Songs being added to a playlist, from a menu anywhere.
            .sheet(item: Bindable(model.yourMusic.playlists).picking) { PlaylistPickerSheet(pick: $0) }
            // Get Info, from any song's menu. Now Playing shows its own over itself.
            .songInfoSheet(model, isActive: !showsNowPlaying) { go(to: .play($0)) }
            // Under Now Playing while it's open; it shows its own.
            .playerFeedback(isActive: !showsNowPlaying)
            // Someone else's SharePlay, joined from Messages.
            .sharePlayGuestPage(closing: $showsNowPlaying)
            .opensDeepLinks(in: model)
            .onAppear(perform: restoreTab)
            .onChange(of: model.selectedTab) { _, tab in savedTab = tab.rawValue }
            // A song from a widget. Summary is the tab whose stack can be pushed from here.
            // Initial too, for a link that launched the app.
            .onChange(of: model.pendingRoute, initial: true) { _, route in
                guard let route else { return }
                model.selectedTab = .summary
                summaryPath = NavigationPath([route])
                model.pendingRoute = nil
            }
            // The history and the mixes follow the store in AppModel, for the whole process:
            // Tracks also plays with no window, for CarPlay and Siri.
            .onChange(of: model.playFeed.builtRevision) {
                // Sample data's own music is made from the sample history, now it's read.
                if model.musicSource == .yourMusic { model.prepareYourMusic() }
                LaunchScene.startDemoPlayback(model)
                LaunchScene.openMix(model)
                #if DEBUG
                Task { await CarPlayImages.writeSampleSheet(model) }
                #endif
            }
            .task { await model.playFeed.followSubscription() }
            #if DEBUG
            .onChange(of: model.library.isLoaded, initial: true) { _, isLoaded in
                if isLoaded, let subject = SongInfoSamples.requested(in: model.library.history) {
                    model.songInfo.show(subject)
                }
            }
            #endif
            .onChange(of: player.hasQueue) { _, hasQueue in
                if hasQueue, LaunchScene.opensNowPlaying { openNowPlaying() }
            }
            .modelContainer(store.container)
            .environment(model)
            .environment(capture)
            .environment(playback)
            .environment(model.player)
            .environment(model.playFeed)
            .environment(model.discovery)
            .environment(model.yourMusic)
            .environment(model.lidarr)
            .environment(model.downloadedSongs)
            .environment(model.playNavigator)
            // A song's Play button plays here, where the play is kept, unless Settings sends
            // songs to Apple Music.
            .environment(\.playSongs, songDestination == .tracks ? PlaySongsAction { items, title in
                player.play(.history(items.map(HistorySong.init)), from: .songs(title))
            } : nil)
            .environment(\.showSongInfo, ShowSongInfoAction { model.songInfo.show($0) })
            .task { await model.startCapture() }
            // Lidarr's actions show wherever music does, whatever the source.
            .task { await model.lidarr.check() }
            // Your other devices nearby, and what's playing here for them.
            .task {
                guard !model.isDemoLaunch else { return }
                model.nearby.start()
                model.followSpeakers()
            }
            .onPlayingChange(of: player) { model.tellNearby() }
            // A song picked up from another of your devices through Handoff.
            .onContinueUserActivity(NowPlayingHandoff.activityType) { model.continueHandoff($0) }
            // Playlists merged with Apple Music, once your servers have had a moment to answer.
            .task {
                guard !model.isDemoLaunch else { return }
                try? await Task.sleep(for: .seconds(5))
                await model.yourMusic.playlistMerge.mergeIfOn()
            }
            .onChange(of: model.musicSource, initial: true) { old, source in
                // Pages pushed for one source mean nothing in the other.
                if old != source {
                    model.playNavigator.path = NavigationPath()
                    model.search.path = NavigationPath()
                }
                if source == .yourMusic { model.prepareYourMusic() }
            }
            .onChange(of: scenePhase) { _, phase in
                // iOS only sees music while Tracks is open, so pick up what was missed each
                // time it comes back. Launch is covered by `startCapture`.
                if phase == .background {
                    wasInBackground = true
                } else if phase == .active, wasInBackground, !model.isDemoLaunch {
                    wasInBackground = false
                    Task {
                        await PlayerQuiet.settled()
                        await capture.catchUp()
                    }
                    Task {
                        await PlayerQuiet.settled()
                        await model.yourMusic.playlistMerge.mergeIfOn()
                    }
                    model.nearby.resume()
                    // Songs dropped into Files while Tracks was away.
                    if model.musicSource == .yourMusic { Task { await model.yourMusic.scan() } }
                }
            }
        } else {
            ContentUnavailableView {
                Label("Tracks Can't Open Your History", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Close Tracks and open it again. If that doesn’t help, restart your iPhone.")
            }
        }
    }

    /// Back on the saved tab, unless the launch itself asked for a place.
    private func restoreTab() {
        guard let tab = AppTab(rawValue: savedTab), model.pendingRoute == nil,
              LaunchScene.tab == nil, LaunchScene.route == nil,
              !LaunchScene.opensSearch, LaunchScene.searchText == nil
        else { return }
        model.selectedTab = tab
    }

    /// The tab Tracks opens to is far left: Play first when it opens to Play, last otherwise.
    private var tabOrder: [AppTab] {
        openingTab == .play ? [.play, .summary, .history, .charts] : [.summary, .history, .charts, .play]
    }

    @ViewBuilder
    private func stack(for tab: AppTab, navigator: PlayNavigator) -> some View {
        switch tab {
        case .summary:
            NavigationStack(path: $summaryPath) {
                SummaryScreen()
                    .tracksDestinations()
                    .playDestinations()
            }
            .environment(\.openPlayRoute, OpenPlayRouteAction(stack: "summary") { summaryPath.append($0) })
        case .play:
            @Bindable var navigator = navigator
            NavigationStack(path: $navigator.path) {
                Group {
                    if model.musicSource == .yourMusic {
                        YourMusicScreen()
                    } else {
                        AppleMusicPlayScreen()
                    }
                }
                .quickSourceSwitch()
                .playDestinations()
                .tracksDestinations()
            }
            .environment(\.openPlayRoute, OpenPlayRouteAction(stack: "play") { navigator.show($0) })
        case .history:
            NavigationStack(path: $historyPath) {
                HistoryScreen()
                    .tracksDestinations()
                    .playDestinations()
            }
            .environment(\.openPlayRoute, OpenPlayRouteAction(stack: "history") { historyPath.append($0) })
        case .charts:
            NavigationStack(path: $chartsPath) {
                ChartsScreen()
                    .tracksDestinations()
                    .playDestinations()
            }
            .environment(\.openPlayRoute, OpenPlayRouteAction(stack: "charts") { chartsPath.append($0) })
        case .search:
            @Bindable var search = model.search
            NavigationStack(path: $search.path) {
                SearchPage()
                    .playDestinations()
                    .tracksDestinations()
            }
            .environment(\.openPlayRoute, OpenPlayRouteAction(stack: "search") { search.path.append($0) })
        }
    }

    /// Without the system's animation: Now Playing slides itself up (see PullToClose), and
    /// takes touches while it does. Tapped while it's still sliding away, it comes back.
    private func openNowPlaying() {
        guard !showsNowPlaying else { return nowPlayingReopens += 1 }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { showsNowPlaying = true }
    }

    /// After Now Playing closes: onto the Play tab's stack, or Summary's for your stats.
    private func go(to destination: NowPlayingDestination) {
        switch destination {
        case .play(let route):
            model.selectedTab = .play
            model.playNavigator.show(route)
        case .stats(let route):
            model.selectedTab = .summary
            summaryPath.append(route)
        }
    }
}
