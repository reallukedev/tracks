import UIKit
import Observation

/// Whether iOS will give Tracks background time for ``BackgroundRefresh``, kept current as it
/// changes in Settings or Control Center.
@Observable
final class BackgroundRefreshAvailability {
    static let shared = BackgroundRefreshAvailability()

    enum Blocker {
        case lowPowerMode
        /// The person turned Background App Refresh off, for Tracks or for everything.
        case turnedOff
        /// Screen Time or a device profile doesn't allow it.
        case restricted
    }

    /// Why refresh won't run, or nil when it can.
    private(set) var blocker: Blocker?

    private init() {
        blocker = Self.currentBlocker()
        // Lives as long as the process, so the observers are never removed.
        let names = [UIApplication.backgroundRefreshStatusDidChangeNotification, .NSProcessInfoPowerStateDidChange]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.blocker = Self.currentBlocker() }
            }
        }
    }

    private static func currentBlocker() -> Blocker? {
        // First, since it pauses refresh while leaving the switch as it was.
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return .lowPowerMode }
        switch UIApplication.shared.backgroundRefreshStatus {
        case .denied: return .turnedOff
        case .restricted: return .restricted
        case .available: return nil
        @unknown default: return nil
        }
    }
}
