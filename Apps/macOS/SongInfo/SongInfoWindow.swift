import SwiftUI
import TracksCore

/// Get Info on the Mac: one window that shows whichever song was asked for last, as Finder's
/// inspector follows the selection rather than stacking a window per song.
struct SongInfoWindow: Scene {
    static let id = "song-info"
    let model: AppModel
    @AppStorage(PlayPreferences.songDestinationKey) private var songDestination = SongDestination.tracks

    var body: some Scene {
        Window("Song Info", id: Self.id) {
            if let store = model.store, let capture = model.capture, let playback = model.playback {
                SongInfoView(presenter: model.songInfo)
                    .frame(minWidth: 380, minHeight: 440)
                    .tracksOnScreen()
                    .modelContainer(store.container)
                    .environment(capture)
                    .environment(playback)
                    .playEnvironment(model, playsSongsInTracks: songDestination == .tracks)
                    // Pages open in the main window, brought forward for them.
                    .environment(\.openPlayRoute, OpenPlayRouteAction(stack: "songInfo") { route in
                        model.playNavigator.show(route)
                        if let openWindow = MacAppDelegate.openWindow {
                            MainWindow.bringForward(openWindow: openWindow)
                        }
                    })
            }
        }
        .defaultSize(width: 560, height: 760)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        // The Song menu's Get Info opens it.
        .commandsRemoved()
    }

    /// Shows the song in the window, opening it or bringing it forward.
    static func show(_ subject: SongInfoSubject, model: AppModel, openWindow: OpenWindowAction?) {
        model.songInfo.show(subject)
        if let openWindow = openWindow ?? MacAppDelegate.openWindow {
            openWindow(id: id)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension View {
    /// Get Info from any menu in this window opens the Song Info window.
    func opensSongInfo(_ model: AppModel) -> some View {
        modifier(OpensSongInfo(model: model))
    }
}

private struct OpensSongInfo: ViewModifier {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.environment(\.showSongInfo, ShowSongInfoAction { subject in
            SongInfoWindow.show(subject, model: model, openWindow: openWindow)
        })
    }
}
