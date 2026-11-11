import Foundation
#if os(iOS)
import UIKit
#endif

/// Where Local Network is turned on for Tracks: its page in iPhone Settings, or Privacy &
/// Security's Local Network list on the Mac.
enum DevicesSettingsLinks {
    @MainActor
    static var localNetwork: URL? {
        #if os(iOS)
        URL(string: UIApplication.openSettingsURLString)
        #else
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
        #endif
    }

    #if os(macOS)
    /// Privacy & Security's Automation list, where Tracks is let control Music, for its
    /// speakers.
    static let automation = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    #endif
}
