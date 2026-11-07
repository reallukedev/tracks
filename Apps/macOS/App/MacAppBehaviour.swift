import SwiftUI
import AppKit
import OSLog
import ServiceManagement

/// Whether the app shows in the Dock, and whether it starts at login.
@MainActor
@Observable
final class MacAppBehaviour {
    static let showsDockIconKey = "showsDockIcon"

    /// On by default, since the window is the main way to use the app.
    var showsDockIcon: Bool {
        didSet {
            UserDefaults.standard.set(showsDockIcon, forKey: Self.showsDockIconKey)
            applyActivationPolicy()
        }
    }

    private(set) var launchAtLoginError: String?

    /// The login item's status as last read. Kept here, rather than read from
    /// `SMAppService` in a view, so Settings redraws when it changes.
    private(set) var loginItemStatus: SMAppService.Status = SMAppService.mainApp.status

    init() {
        showsDockIcon = UserDefaults.standard.object(forKey: Self.showsDockIconKey) as? Bool ?? true
    }

    /// `.accessory` hides the Dock icon and app menu but keeps windows usable. Applied at
    /// launch as well as on change.
    func applyActivationPolicy() {
        NSApp.setActivationPolicy(showsDockIcon ? .regular : .accessory)
    }

    /// Whether Tracks is set to open at login. Waiting for approval in System Settings counts:
    /// the choice has been made, and showing the switch off would invite a second attempt.
    var launchesAtLogin: Bool {
        loginItemStatus == .enabled || loginItemStatus == .requiresApproval
    }

    /// Registered, but the user still has to allow it under Login Items.
    var launchAtLoginNeedsApproval: Bool {
        loginItemStatus == .requiresApproval
    }

    /// Reads the status again without registering anything. The user can change it in
    /// System Settings at any time.
    func refreshLoginItemStatus() {
        loginItemStatus = SMAppService.mainApp.status
    }

    /// Registers or unregisters the login item. On failure the status stays as it was and
    /// ``launchAtLoginError`` says why.
    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            // Fails for unsigned or unnotarised builds, such as development copies.
            Self.log.error("Couldn't change the login item: \(error, privacy: .public)")
            launchAtLoginError = Self.loginItemMessage(for: error)
        }
        refreshLoginItemStatus()
    }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Tracks", category: "Login Item")

    /// Why Open at Login couldn't change, and what to do, in place of the system's words.
    nonisolated static func loginItemMessage(for error: any Error) -> String {
        switch (error as NSError).code {
        case kSMErrorLaunchDeniedByUser:
            String(localized: "Couldn’t change Open at Login. Allow Tracks under Login Items in System Settings.")
        case kSMErrorInvalidSignature:
            String(localized: "This copy of Tracks isn’t signed, so it can’t open at login.")
        default:
            String(localized: "Couldn’t change Open at Login. Try again, or change it under Login Items in System Settings.")
        }
    }
}
