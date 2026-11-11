import AppIntents
#if os(macOS)
import AppKit
#endif

// The app's half of ControlIntents.swift: the work, which needs the app model.

extension StartPlayChoiceIntent {
    @MainActor static func start(_ choice: PlayChoice) async throws {
        // The same as asking Siri, so a control and "Play My Mix in Tracks" can't disagree.
        _ = try await PlayInTracksIntent(choice: choice).perform()
    }
}

extension SaveRadioSongControlIntent {
    @MainActor static func save() async throws -> String {
        try await SaveCurrentRadioSongIntent.saveNow()
    }
}

extension IdentifySongIntent {
    @MainActor static func open() async throws {
        let model = AppModel.shared
        model.beginSearch()
        // Listening, not typing: no keyboard over the listening view.
        model.search.wantsFocus = false
        model.search.isIdentifying = true
        await AppWindow.bringForward()
    }
}

/// Shows the main window for an intent that opens a page.
enum AppWindow {
    @MainActor static func bringForward() async {
        #if os(macOS)
        // Tracks may be living in the menu bar with no window to show it in.
        if let openWindow = MacAppDelegate.openWindow {
            MainWindow.bringForward(openWindow: openWindow)
        } else {
            // No window has been shown yet to open another: reopening the app makes its main
            // window, which picks up what was asked for.
            _ = try? await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
        }
        #endif
    }
}
