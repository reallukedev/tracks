import SwiftUI

/// Tracks’ App Clip: SharePlay for a passenger without Tracks. Their Camera reads the code on
/// the car's screen or the host's iPhone, iOS opens this with the code's link, and they pick
/// songs for the host's Up Next, with nothing to install or sign in to.
///
/// It reaches the host over SharePlay's relay: App Clips can't look for iPhones nearby.
@main
struct TracksClipApp: App {
    @State private var model = ClipModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ClipView(model: model)
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    model.open(activity.webpageURL)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.resume() }
        }
    }
}
