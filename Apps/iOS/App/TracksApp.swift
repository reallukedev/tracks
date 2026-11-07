import SwiftUI
import TracksCore

/// iOS has no headless mode, so `@main` lives here. On the Mac it's `Main.swift`.
@main
struct TracksApp: App {
    /// Shared with CarPlay and Siri, which can start Tracks without a window.
    @State private var model = AppModel.shared
    @UIApplicationDelegateAdaptor(TracksAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .tracksOnScreen()
                // SharePlay sessions: one this iPhone starts, or one it's invited to, which
                // can be what opened the app.
                .task { SharePlayController.shared.start(model: model) }
        }
        .onChange(of: scenePhase) { _, phase in
            guard !model.isDemoLaunch else { return }
            switch phase {
            case .active:
                // iOS suspends the app within about thirty seconds of it going away, so
                // nothing has been pulled from iCloud since. Catch up before the user looks.
                model.syncOnForeground()
            case .background:
                // Flush before iOS suspends the app, which can happen inside the settle delay.
                WidgetRefresher.shared?.reloadIfChanged()
                // Where the music is, for a launch after iOS or a swipe ends the app.
                model.player.saveSession()
                Task { await BackgroundRefresh.schedule() }
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) { [model] in
            // Ask for the next one first, so a refresh that runs out of time still has one.
            await BackgroundRefresh.schedule()
            await BackgroundRefresh.run(model)
        }
    }
}
