#if os(macOS)
import Foundation
import CoreGraphics

/// Whether someone is at the machine.
///
/// Automatic playback checks this first so Tracks never logs plays for an empty room.
/// Uses the HID idle time (the screensaver's clock), which needs no entitlement or
/// accessibility permission.
public enum UserPresence {
    /// Seconds since the last keyboard or mouse event, or nil if unknown.
    /// Automatic playback treats nil as absent.
    public static var secondsSinceInput: TimeInterval? {
        let seconds = CGEventSource.secondsSinceLastEventType(
            .hidSystemState,
            eventType: .init(rawValue: ~0)!
        )
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }

    /// Whether someone has touched the machine recently enough to be listening.
    public static func isPresent(within window: TimeInterval = 300) -> Bool {
        guard let seconds = secondsSinceInput else { return false }
        return seconds < window
    }
}
#endif
