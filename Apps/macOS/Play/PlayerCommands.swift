import SwiftUI
import TracksCore

/// Opens the full player over the window.
struct OpenFullPlayerAction {
    let run: @MainActor () -> Void

    @MainActor
    func callAsFunction() { run() }
}

extension EnvironmentValues {
    @Entry var openFullPlayer = OpenFullPlayerAction {}
}

/// What the frontmost main window can do for the menu bar: its panel, its full player and its
/// pages belong to the window, not the app.
struct PlayerWindowActions {
    var isShowingUpNext: Bool
    var isShowingHistory: Bool
    var showsFullPlayer: Bool
    var canGoBack: Bool
    var canGoForward: Bool
    let togglePanel: @MainActor (PlayerPanelPage) -> Void
    let toggleFullPlayer: @MainActor () -> Void
    let goToCurrentSong: @MainActor () -> Void
    let beginSearch: @MainActor () -> Void
    /// Pushes a page, out of the full player and the search.
    let open: @MainActor (PlayRoute) -> Void
    let goBack: @MainActor () -> Void
    let goForward: @MainActor () -> Void
}

extension FocusedValues {
    @Entry var playerWindow: PlayerWindowActions?
}

/// The window's Back and Forward, as a browser's: what Back left stays ahead until another
/// page is opened.
@MainActor
@Observable
final class NavigationHistory {
    private var ahead: [NavigationPath] = []
    /// The path Back or Forward set, so its own change isn't taken for a new page.
    private var expected: NavigationPath?

    var canGoForward: Bool { !ahead.isEmpty }

    func goBack(_ path: inout NavigationPath) {
        guard !path.isEmpty else { return }
        ahead.append(path)
        path.removeLast()
        expected = path
    }

    func goForward(_ path: inout NavigationPath) {
        guard let next = ahead.popLast() else { return }
        path = next
        expected = next
    }

    /// Forgets what's ahead, for a change of place in the sidebar.
    func reset() {
        ahead.removeAll()
        expected = NavigationPath()
    }

    /// Every change of the path: one step back by the window's own back button keeps what it
    /// left ahead, and anything else but Back and Forward starts afresh.
    func pathChanged(from old: NavigationPath, to new: NavigationPath) {
        defer { expected = nil }
        if new == expected { return }
        if new.count == old.count - 1 {
            ahead.append(old)
        } else {
            ahead.removeAll()
        }
    }
}

extension View {
    /// Publishes the window's player actions to the menu bar.
    func playerCommands(
        window: PlayerWindowState,
        isShowingFullPlayer: Bool,
        history: NavigationHistory,
        path: Binding<NavigationPath>,
        goToCurrentSong: @escaping @MainActor () -> Void,
        beginSearch: @escaping @MainActor () -> Void,
        open: @escaping @MainActor (PlayRoute) -> Void
    ) -> some View {
        modifier(PlayerCommandsModifier(
            window: window,
            isShowingFullPlayer: isShowingFullPlayer,
            history: history,
            path: path,
            goToCurrentSong: goToCurrentSong,
            beginSearch: beginSearch,
            open: open
        ))
    }
}

private struct PlayerCommandsModifier: ViewModifier {
    let window: PlayerWindowState
    let isShowingFullPlayer: Bool
    let history: NavigationHistory
    @Binding var path: NavigationPath
    let goToCurrentSong: @MainActor () -> Void
    let beginSearch: @MainActor () -> Void
    let open: @MainActor (PlayRoute) -> Void

    func body(content: Content) -> some View {
        // Read here, not in the closures, so the menu bar hears when they change.
        let inFullPlayer = isShowingFullPlayer
        let path = $path
        content
            .focusedSceneValue(\.playerWindow, PlayerWindowActions(
                isShowingUpNext: window.isShowing(.upNext, inFullPlayer: inFullPlayer),
                isShowingHistory: window.isShowing(.history, inFullPlayer: inFullPlayer),
                showsFullPlayer: window.showsFullPlayer,
                canGoBack: !inFullPlayer && !self.path.isEmpty,
                canGoForward: !inFullPlayer && history.canGoForward,
                togglePanel: { page in window.toggle(page, inFullPlayer: inFullPlayer) },
                toggleFullPlayer: { window.showsFullPlayer.toggle() },
                goToCurrentSong: goToCurrentSong,
                beginSearch: beginSearch,
                open: open,
                goBack: { history.goBack(&path.wrappedValue) },
                goForward: { history.goForward(&path.wrappedValue) }
            ))
            .environment(\.openFullPlayer, OpenFullPlayerAction { window.showsFullPlayer = true })
    }
}

/// The Controls, Song and Go menus: everything the player does, with Music's shortcuts. And
/// Search, in the Edit menu where people look for Find, and the Mini Player in Window.
struct ControlsCommands: Commands {
    let model: AppModel
    @FocusedValue(\.playerWindow) private var window
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            // ⌘F, as in Music: the Search page, with the cursor in its field.
            Button("Search", systemImage: "magnifyingglass") { window?.beginSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(window == nil)
        }

        CommandMenu("Go") {
            Button("Back", systemImage: "chevron.backward") { window?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(window?.canGoBack != true)
            Button("Forward", systemImage: "chevron.forward") { window?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(window?.canGoForward != true)
        }

        // Views rather than the commands' own body, so the items follow the player as it
        // changes: a menu bar's commands only hear the window's focused values.
        CommandMenu("Controls") {
            ControlsMenuItems(model: model, window: window, openWindow: openWindow)
        }

        CommandMenu("Song") {
            PlayingSongMenuItems(model: model, window: window, openWindow: openWindow)
        }

        CommandGroup(before: .windowList) {
            WindowMenuItems(openWindow: openWindow, dismissWindow: dismissWindow)
        }
    }
}

private struct ControlsMenuItems: View {
    let model: AppModel
    let window: PlayerWindowActions?
    let openWindow: OpenWindowAction
    @AppStorage(PlayPreferences.tracksRadioKey) private var isRadioOn = true
    @AppStorage(PlayPreferences.autoplayKey) private var autoplay = true

    private var player: PlayerModel { model.player }

    var body: some View {
        Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause" : "play") {
            player.togglePlayPause()
        }
        .disabled(!player.hasQueue)

        // Music's Stop: the song paused and back at its start, ready to play again.
        Button("Stop", systemImage: "stop") {
            if player.isPlaying { player.togglePlayPause() }
            player.seek(to: 0)
        }
        .keyboardShortcut(".", modifiers: .command)
        .disabled(!player.hasQueue || player.current?.duration == nil)

        Button("Next", systemImage: "forward") { player.skipToNext() }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(!player.hasQueue)

        Button("Previous", systemImage: "backward") { player.skipToPrevious() }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(!player.hasQueue || player.context?.isStation == true)

        Button("Go to Current Song", systemImage: "arrow.forward.circle") { window?.goToCurrentSong() }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(!player.hasQueue || window == nil)

        Divider()

        Toggle(isOn: Binding(get: { player.isShuffled }, set: { _ in player.toggleShuffle() })) {
            Label("Shuffle", systemImage: "shuffle")
        }
        .disabled(!canReorder)

        Picker(selection: Binding(get: { player.repeatMode }, set: { player.setRepeat($0) })) {
            Text("Off").tag(PlayerRepeat.off)
            Text("All").tag(PlayerRepeat.all)
            Text("One").tag(PlayerRepeat.one)
        } label: {
            Label("Repeat", systemImage: "repeat")
        }
        .disabled(!canReorder)

        // Music's ∞: once the queue runs out, songs like it carry on.
        Toggle(isOn: Binding(get: { autoplay }, set: { player.setAutoplay($0) })) {
            Label("Autoplay", systemImage: "infinity")
        }

        Menu {
            SleepTimerItems(player: player)
        } label: {
            Label("Sleep Timer", systemImage: "moon.zzz")
        }
        .disabled(!player.hasQueue)

        PlayOnMenu(model: model)

        Divider()

        Button("Play Tracks Radio", systemImage: "dot.radiowaves.left.and.right") { player.playTracksRadio() }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(!isRadioOn)

        // The iPhone's shake, for the Mac.
        Button("Play Something New", systemImage: "sparkles") {
            Task { await player.playSomethingNew() }
        }
        .keyboardShortcut("n", modifiers: [.command, .option])

        Button("Play Back Today", systemImage: "play.circle") {
            Task { await model.playback?.playBackToday() }
        }
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .disabled(model.isShowingSampleData)

        // The song on Music's radio, kept in your history.
        Button("Save Current Radio Song", systemImage: "plus.circle") {
            Task { await model.capture?.captureCurrentSong() }
        }
        .keyboardShortcut("s", modifiers: [.command, .option])
        .disabled(model.isShowingSampleData || model.capture?.isPaused == true)

        Divider()

        Button(window?.isShowingUpNext == true ? "Hide Up Next" : "Show Up Next", systemImage: "list.bullet") {
            window?.togglePanel(.upNext)
        }
        .keyboardShortcut("u", modifiers: [.command, .option])
        .disabled(!player.hasQueue || window == nil)

        Button(window?.isShowingHistory == true ? "Hide Your History" : "Show Your History", systemImage: "clock.arrow.circlepath") {
            window?.togglePanel(.history)
        }
        .keyboardShortcut("y", modifiers: [.command, .option])
        .disabled(!player.hasQueue || window == nil)

        Button(window?.showsFullPlayer == true ? "Exit Full Player" : "Full Player", systemImage: "arrow.up.left.and.arrow.down.right") {
            window?.toggleFullPlayer()
        }
        // Music's shortcut. ⌃⌘F is the window's own Enter Full Screen.
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .disabled(!player.hasQueue || window == nil)

        Button("Stage", systemImage: "tv") {
            openWindow(id: StageWindow.id)
        }
        // Keynote's Play Slideshow: the song, presented.
        .keyboardShortcut("p", modifiers: [.command, .option])
        .disabled(!player.hasQueue)
    }

    /// A station or a live mix picks as it goes: there's no order to shuffle or end to repeat.
    private var canReorder: Bool {
        player.hasQueue && player.context?.isStation != true && !player.isLive
    }
}

/// The playing song, as Music's Song menu has it: keep it, find where it's from, see your
/// history with it, share it.
private struct PlayingSongMenuItems: View {
    let model: AppModel
    let window: PlayerWindowActions?
    let openWindow: OpenWindowAction

    private var player: PlayerModel { model.player }

    var body: some View {
        let track = player.current
        let song = track?.song
        Group {
            if let song {
                FavoriteMenuItem(song: song)
            } else {
                Button("Favorite", systemImage: "star") {}
                    .disabled(true)
            }
            Button("Add to Library", systemImage: "plus") {
                if let song { player.addToLibrary(song) }
            }
            .disabled(song == nil)
            // Your own songs go into Tracks' playlists, picked in the main window.
            Button("Add to Playlist…", systemImage: "text.badge.plus") {
                guard let local = track?.local else { return }
                model.yourMusic.playlists.picking = PlaylistPick(tracks: [local])
                MainWindow.bringForward(openWindow: openWindow)
            }
            .disabled(track?.local == nil)

            Divider()

            Button("Go to Album", systemImage: "square.stack") {
                if let local = track?.local {
                    open(.localAlbum(local.albumKey))
                } else if let song {
                    Task { if let album = await SongLinks.album(of: song) { open(.album(album)) } }
                }
            }
            .disabled(track?.local == nil && song == nil)
            Button("Go to Artist", systemImage: "music.microphone") {
                if let local = track?.local {
                    open(.localArtist(local.artistKey))
                } else if let song {
                    Task { if let artist = await SongLinks.artist(of: song) { open(.artist(artist)) } }
                }
            }
            .disabled(track?.local == nil && song == nil)
            // ⌘I is the selection's, as Music's Get Info is: History's inspector has it.
            Button("Your Stats", systemImage: "chart.bar.xaxis") {
                if let track { open(.stats(.song(track.songIdentity))) }
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(track == nil)

            Divider()

            if let url = song?.url {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
            } else {
                Button("Share", systemImage: "square.and.arrow.up") {}
                    .disabled(true)
            }
            Button("Create Station", systemImage: "dot.radiowaves.left.and.right") {
                if let song { player.playStation(from: song) }
            }
            .disabled(song == nil)
        }
        // FavoriteMenuItem reads the player from the environment, which the menu bar lacks.
        .environment(player)
    }

    /// In the window in front, or the main window brought forward from the Mini Player.
    private func open(_ route: PlayRoute) {
        if let window {
            window.open(route)
        } else {
            model.playNavigator.show(route)
            MainWindow.bringForward(openWindow: openWindow)
        }
    }
}

/// The main window, and the Mini Player in its place or beside it, as Music's Window menu has.
private struct WindowMenuItems: View {
    let openWindow: OpenWindowAction
    let dismissWindow: DismissWindowAction

    var body: some View {
        let isMiniOpen = MiniPlayerWindow.presence.isOpen
        // Brings back the window when it's been closed, which the list of open windows can't.
        Button("Tracks", systemImage: "macwindow") { MainWindow.bringForward(openWindow: openWindow) }
            .keyboardShortcut("0", modifiers: .command)
        Button(isMiniOpen ? "Switch from Mini Player" : "Switch to Mini Player", systemImage: "rectangle.inset.bottomright.filled") {
            if isMiniOpen {
                dismissWindow(id: MiniPlayerWindow.id)
                MainWindow.bringForward(openWindow: openWindow)
            } else {
                openWindow(id: MiniPlayerWindow.id)
                MainWindow.open?.performClose(nil)
            }
        }
        .keyboardShortcut("m", modifiers: [.command, .shift])
        Button("Mini Player", systemImage: "rectangle.inset.bottomright.filled") { openWindow(id: MiniPlayerWindow.id) }
            .keyboardShortcut("m", modifiers: [.command, .option])
            .disabled(isMiniOpen)
        Divider()
    }
}
