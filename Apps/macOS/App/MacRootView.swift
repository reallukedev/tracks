import SwiftUI
import TracksCore

/// The main window: the sidebar of places, the page chosen, and the song playing at the foot
/// of it, with Up Next and the song's history in a popover rising from it.
struct MacRootView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(OpeningTab.storageKey) private var openingTab: OpeningTab = .standard
    @AppStorage(PlayPreferences.songDestinationKey) private var songDestination = SongDestination.tracks
    /// The panel and the full player: the window's, not the app's.
    @State private var playerWindow = PlayerWindowState()
    @State private var history = NavigationHistory()
    /// Tracks Radio's tuning, presented by the window from outside the full player and the
    /// bar's popover, whose looks mustn't reach it.
    @State private var showsTuner = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isOnScreen) private var isOnScreen
    #if DEBUG
    @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        if let store = model.store, let capture = model.capture, let playback = model.playback {
            @Bindable var navigator = model.playNavigator
            @Bindable var playerWindow = playerWindow
            let player = model.player
            NavigationSplitView {
                MacSidebar(
                    selection: $model.sidebarSelection,
                    opening: openingTab,
                    library: SidebarItem.library(for: model.musicSource, hasLidarr: model.lidarr.isSetUp),
                    libraryTitle: model.musicSource == .yourMusic ? "Your Music" : "Library"
                )
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
            } detail: {
                NavigationStack(path: $navigator.path) {
                    detail
                        .pageChrome()
                        .tracksDestinations()
                        .playDestinations()
                }
            }
            // Under the full player, the page and its bar stop ticking.
            .environment(\.isOnScreen, isOnScreen && !isShowingFullPlayer)
            .environment(playerWindow)
            .onChange(of: model.sidebarSelection) { _, selection in
                history.reset()
                navigator.path = NavigationPath()
                // Clicking Search puts the cursor in its field, as Podcasts does. Arrowing
                // through the sidebar past it doesn't, or the next arrow would type.
                if selection == .search, NSApp.currentEvent?.type != .keyDown {
                    model.search.wantsFocus = true
                }
            }
            // Siri's search too, which arrives without the window's help.
            .onChange(of: model.search.wantsFocus) { _, wants in
                if wants { playerWindow.showsFullPlayer = false }
            }
            .onChange(of: navigator.path) { old, new in
                history.pathChanged(from: old, to: new)
            }
            // Initial too, for a window the request itself had to open.
            .onChange(of: model.pendingRoute, initial: true) { _, route in
                guard let route else { return }
                model.pendingRoute = nil
                // The song Tracks is playing opens as it's playing, as Music's mini player
                // opens Now Playing: the menu bar's song asks for it this way.
                if case .song(let identity) = route, player.hasQueue, identity == player.current?.songIdentity {
                    playerWindow.showsFullPlayer = true
                    return
                }
                navigator.path = NavigationPath([route])
            }
            .onChange(of: model.musicSource) { old, source in
                follow(sourceChangeFrom: old, to: source)
            }
            .onChange(of: player.hasQueue) { _, hasQueue in
                if !hasQueue { playerWindow.showsPanel = false }
            }
            // The popover is the bar's, and the full player covers the bar. It opens again on
            // the song's details, the cover face up.
            .onChange(of: isShowingFullPlayer) { _, isShowing in
                if isShowing {
                    playerWindow.showsPanel = false
                } else {
                    playerWindow.fullPlayerShowsUpNext = false
                    playerWindow.fullPlayerShowsHistory = false
                }
            }
            // The full player takes the whole window: the toolbar, the keyboard and VoiceOver
            // leave the page behind it until it closes.
            .toolbarVisibility(isShowingFullPlayer ? .hidden : .automatic, for: .windowToolbar)
            .accessibilityHidden(isShowingFullPlayer)
            .overlay {
                if isShowingFullPlayer {
                    FullPlayer(window: playerWindow) { playerWindow.showsFullPlayer = false }
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 1.02)))
                }
            }
            #if DEBUG
            .overlay {
                if let style = BackdropLab.requested {
                    BackdropLab(style: style).ignoresSafeArea()
                }
            }
            #endif
            .animation(reduceMotion ? .easeOut(duration: 0.2) : PlayMotion.panel, value: isShowingFullPlayer)
            .playerFeedback()
            // Your devices, at the far end of the titlebar on every page, as Spotify keeps its
            // Connect button in reach wherever you are.
            .background {
                TitlebarAccessory(isHidden: isShowingFullPlayer) {
                    DevicesButton(opensAtLaunch: true)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .controlSize(.extraLarge)
                        .padding(.trailing, 12)
                        .padding(.leading, 6)
                        .frame(height: 52)
                        .environment(model)
                        .environment(model.player)
                }
            }
            // Songs being added to a playlist, from a menu anywhere.
            .sheet(item: Bindable(model.yourMusic.playlists).picking) { PlaylistPickerSheet(pick: $0) }
            .sheet(isPresented: $showsTuner) { RadioTunerSheet() }
            .environment(\.openRadioTuner, OpenRadioTunerAction {
                // The popover it was asked from goes first, so the sheet isn't left under it.
                guard playerWindow.showsPanel else {
                    showsTuner = true
                    return
                }
                playerWindow.showsPanel = false
                Task { showsTuner = true }
            })
            .playerCommands(
                window: playerWindow,
                isShowingFullPlayer: isShowingFullPlayer,
                history: history,
                path: $navigator.path,
                goToCurrentSong: goToCurrentSong,
                beginSearch: beginSearch,
                open: open
            )
            .opensDeepLinks(in: model)
            .modelContainer(store.container)
            .environment(capture)
            .environment(playback)
            .playEnvironment(model, playsSongsInTracks: songDestination == .tracks)
            .onAppear { MacAppDelegate.openWindow = openWindow }
            .task { await model.playFeed.followSubscription() }
            .task { await model.lidarr.check() }
            .task(id: model.musicSource) {
                if model.musicSource == .yourMusic { model.prepareYourMusic() }
            }
            .onChange(of: model.playFeed.builtRevision) {
                if model.musicSource == .yourMusic { model.prepareYourMusic() }
                LaunchScene.startDemoPlayback(model)
                LaunchScene.openMix(model)
            }
            // Through the Mac's one voice: Music may be the player your devices are shown.
            .onPlayingChange(of: model.player) {
                model.updateHandoff()
                Task { await NearbyMac.tell(model) }
            }
            // A song picked up from another of your devices through Handoff.
            .onContinueUserActivity(NowPlayingHandoff.activityType) { model.continueHandoff($0) }
            #if DEBUG
            .onChange(of: player.hasQueue) { _, hasQueue in
                if hasQueue, LaunchScene.opensStage { openWindow(id: StageWindow.id) }
            }
            .task {
                if UserDefaults.standard.bool(forKey: "TracksMenuBarPreview") {
                    openWindow(id: "menubar-preview")
                }
                // A launch from a script isn't activated, so screenshots show a greyed-out window.
                // Only the deprecated form still takes focus from another app on macOS 27.
                if LaunchScene.activates {
                    NSApp.activate(ignoringOtherApps: true)
                }
                CollectionScreenshotSetup.apply()
                if UserDefaults.standard.bool(forKey: "TracksMiniPlayer") {
                    // Once the main window is up, as someone would open it.
                    try? await Task.sleep(for: .seconds(2))
                    openWindow(id: MiniPlayerWindow.id)
                }
                if LaunchScene.opensSettings {
                    MenuBarFooter.bringSettingsForward(openSettings: openSettings)
                }
            }
            .onChange(of: model.library.isLoaded, initial: true) { _, isLoaded in
                if isLoaded, let subject = SongInfoSamples.requested(in: model.library.history) {
                    SongInfoWindow.show(subject, model: model, openWindow: openWindow)
                }
            }
            #endif
        } else {
            ContentUnavailableView {
                Label("Tracks Can't Open Your History", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Quit Tracks and open it again. If that doesn’t help, restart your Mac.")
            }
        }
    }

    /// Pages pushed for one source mean nothing in the other. A library row the other source
    /// also has (Albums, Songs) stays chosen and shows that source's; one it doesn't have
    /// (Downloads, Lidarr) goes back to Listen Now.
    private func follow(sourceChangeFrom old: MusicSource, to source: MusicSource) {
        guard old != source else { return }
        history.reset()
        model.playNavigator.path = NavigationPath()
        if let selection = model.sidebarSelection,
           SidebarItem.library(for: old, hasLidarr: true).contains(selection),
           !SidebarItem.library(for: source, hasLidarr: model.lidarr.isSetUp).contains(selection) {
            model.sidebarSelection = .listenNow
        }
        if source == .yourMusic { model.prepareYourMusic() }
    }

    private var isShowingFullPlayer: Bool {
        playerWindow.showsFullPlayer && model.player.hasQueue
    }

    /// The Search page with the cursor in its field, out of the full player.
    private func beginSearch() {
        playerWindow.showsFullPlayer = false
        model.beginSearch()
    }

    /// A page from the menu bar, over whatever the window shows.
    private func open(_ route: PlayRoute) {
        playerWindow.showsFullPlayer = false
        model.playNavigator.show(route)
    }

    /// The playing song's album, or its stats when there's no album to show.
    private func goToCurrentSong() {
        guard let track = model.player.current else { return }
        playerWindow.showsFullPlayer = false
        let navigator = model.playNavigator
        if let local = track.local {
            navigator.show(.localAlbum(local.albumKey))
        } else if let song = track.song {
            Task {
                if let album = await SongLinks.album(of: song) {
                    navigator.show(.album(album))
                } else {
                    navigator.show(.stats(.song(track.songIdentity)))
                }
            }
        } else {
            navigator.show(.stats(.song(track.songIdentity)))
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.sidebarSelection ?? SidebarItem.opening {
        case .search: SearchPage()
        case .listenNow: ListenNowPage()
        case .radio: RadioPage()
        case .summary: MacSummaryView()
        case .history: MacHistoryView()
        case .topSongs: TopChartView(kind: .songs)
        case .topArtists: TopChartView(kind: .artists)
        case .topAlbums: TopChartView(kind: .albums)
        case .recentlyAdded, .playlists, .albums, .artists, .songs, .downloads, .lidarr:
            LibraryPage(item: model.sidebarSelection ?? .playlists, source: model.musicSource)
        }
    }
}

/// Places, in the order Open To gives them, then the library of the music Play is on, as
/// Music's sidebar ends with its library.
private struct MacSidebar: View {
    @Binding var selection: SidebarItem?
    let opening: OpeningTab
    let library: [SidebarItem]
    let libraryTitle: LocalizedStringKey

    var body: some View {
        List(selection: $selection) {
            Section { rows([.search]) }
            let leading = SidebarItem.leading(opening: opening)
            let playing = leading.filter { $0 == .listenNow || $0 == .radio }
            let listening = leading.filter { $0 != .listenNow && $0 != .radio }
            if opening == .play {
                Section { rows(playing) }
                Section("Your Listening") { rows(listening) }
            } else {
                Section { rows(listening) }
                Section("Play") { rows(playing) }
            }
            Section(libraryTitle) { rows(library) }
        }
    }

    private func rows(_ items: [SidebarItem]) -> some View {
        ForEach(items) { item in
            Label(item.title, systemImage: item.symbol)
                .tag(item)
        }
    }
}

extension View {
    /// Everything a page that plays music reads: the player and what it plays from, and where
    /// its pages push.
    func playEnvironment(_ model: AppModel, playsSongsInTracks: Bool) -> some View {
        modifier(PlayEnvironment(model: model, playsSongsInTracks: playsSongsInTracks))
    }
}

private struct PlayEnvironment: ViewModifier {
    let model: AppModel
    let playsSongsInTracks: Bool

    func body(content: Content) -> some View {
        let player = model.player
        let navigator = model.playNavigator
        content
            .environment(model)
            .environment(player)
            .environment(model.playFeed)
            .environment(model.discovery)
            .environment(model.yourMusic)
            .environment(model.lidarr)
            .environment(navigator)
            .environment(\.openPlayRoute, OpenPlayRouteAction(stack: "main") { navigator.show($0) })
            // A song's Play button plays in Tracks, where every play is kept, unless Settings
            // sends songs to Music.
            .environment(\.playSongs, playsSongsInTracks ? PlaySongsAction { items, title in
                player.play(.history(items.map(HistorySong.init)), from: .songs(title))
            } : nil)
    }
}
