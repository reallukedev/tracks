import Foundation

/// How a settings status line reads: plain, needs you (orange), or failed (red).
///
/// Only the line that states a problem carries a tone. The footer under it explains, in grey.
public enum SettingsTone: Sendable, Equatable {
    case plain
    case attention
    case failure
}
