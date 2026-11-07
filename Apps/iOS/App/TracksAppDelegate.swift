import UIKit
import Intents

/// Hands Siri's "play" requests to Tracks, which handles them itself rather than in an
/// extension: the player lives in the app. And finishes downloads from your servers that
/// completed while Tracks wasn't running.
final class TracksAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Here rather than on the window, since CarPlay can start Tracks with no window at all.
        SpeedVolume.shared.start(AppModel.shared)
        return true
    }

    /// Upright everywhere but Stage, which turns as its settings say.
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        StagePresenter.shared.orientations
    }

    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        switch intent {
        case is INPlayMediaIntent: PlayMediaIntentHandler()
        case is INUpdateMediaAffinityIntent: UpdateMediaAffinityIntentHandler()
        case is INAddMediaIntent: AddMediaIntentHandler()
        default: nil
        }
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Downloads.sessionIdentifier else {
            completionHandler()
            return
        }
        // Making the downloads reconnects to the session, whose delegate calls this once the
        // finished files are in place.
        AppModel.shared.yourMusic.downloads.backgroundCompletion = completionHandler
    }
}
