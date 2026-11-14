import Foundation
import Observation

/// How often a moving background draws: every frame the display shows, so slow motion glides
/// at 120 Hz on ProMotion as it does at 60 elsewhere. Reduce Motion's calmer movement needs
/// fewer, and so does Low Power Mode, which keeps the motion at fewer frames.
enum BackdropFrameRate {
    /// For what moves with the music, Living Cover and Stage: every frame the display shows,
    /// as often as it refreshes, up to 120 times a second on ProMotion. Low Power Mode keeps
    /// the motion at 20.
    static var everyFrame: Double? {
        LowPowerMode.shared.isOn ? 1 / 20 : nil
    }

    static func interval(reduceMotion: Bool) -> Double? {
        reduceMotion ? 1 / 20 : everyFrame
    }
}

/// Whether Low Power Mode is on, for views to read as it changes.
@Observable
final class LowPowerMode {
    static let shared = LowPowerMode()
    private(set) var isOn = ProcessInfo.processInfo.isLowPowerModeEnabled
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { _ in
            Task { @MainActor in
                LowPowerMode.shared.isOn = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
    }
}
