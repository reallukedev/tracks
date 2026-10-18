import Foundation

/// Where iCloud sync stands, and how Settings says it.
///
/// CloudKit failures (an ungranted container, a signed-out account, a refused export) otherwise
/// look the same as having nothing new to sync. The setting is read once when the store opens,
/// so what the switch says and what's running can differ until Tracks opens again.
public enum CloudSyncStatus: Sendable, Equatable {
    /// This build has no iCloud container.
    case unavailable
    case off
    /// Switched off, but the store opened with sync, so it keeps syncing until Tracks reopens.
    case stopsNextLaunch
    /// Switched on, but the store opened without sync.
    case startsNextLaunch
    /// Switched on, and the store couldn't open with sync.
    case couldNotStart(String)
    case checking
    case notSignedIn
    case restricted
    /// iCloud answered that it's temporarily unavailable.
    case waiting
    case accountError(String)
    case failed(CloudSyncMonitor.Activity, String)
    case on(lastSynced: Date?)

    /// What CloudKit said about the iCloud account.
    public enum Account: Sendable, Equatable {
        case available
        case noAccount
        case restricted
        case temporarilyUnavailable
        case unknown
    }

    /// Checks the build, then the setting against what's running, then the account, then
    /// what the mirror reported, in that order: each earlier problem explains the later ones.
    public static func resolve(
        isConfigured: Bool,
        wantsSync: Bool,
        isRunning: Bool,
        startFailure: String?,
        account: Account?,
        accountError: String?,
        failure: CloudSyncMonitor.Failure?,
        lastSynced: Date?
    ) -> CloudSyncStatus {
        guard isConfigured else { return .unavailable }
        guard wantsSync else { return isRunning ? .stopsNextLaunch : .off }
        guard isRunning else { return startFailure.map(CloudSyncStatus.couldNotStart) ?? .startsNextLaunch }
        if let accountError { return .accountError(accountError) }
        switch account {
        case nil, .unknown: return .checking
        case .noAccount: return .notSignedIn
        case .restricted: return .restricted
        case .temporarilyUnavailable: return .waiting
        case .available:
            if let failure { return .failed(failure.activity, failure.message) }
            return .on(lastSynced: lastSynced)
        }
    }

    /// The status line under the name.
    public func line(now: Date = .now) -> String {
        switch self {
        case .unavailable:
            String(localized: "Sync isn’t available in this copy of Tracks.")
        case .off:
            String(localized: "Keep your history on all your devices, and safe if you lose this one.")
        case .stopsNextLaunch:
            String(localized: "Sync stops the next time Tracks opens.")
        case .startsNextLaunch:
            String(localized: "Sync starts the next time Tracks opens.")
        case .couldNotStart:
            String(localized: "iCloud sync couldn’t start.")
        case .checking:
            String(localized: "Checking iCloud…")
        case .notSignedIn:
            String(localized: "Sign in to iCloud to sync your history.")
        case .restricted:
            String(localized: "iCloud is restricted on this device, so Tracks can’t sync.")
        case .waiting:
            String(localized: "iCloud isn’t reachable right now. Tracks will try again.")
        case .accountError:
            String(localized: "Tracks couldn’t reach iCloud.")
        case .failed(.setup, _):
            String(localized: "Sync couldn’t start, so this device isn’t sending or receiving history.")
        case .failed(.export, _):
            String(localized: "iCloud isn’t accepting this device’s history, so your other devices won’t see it.")
        case .failed(.import, _):
            String(localized: "This device couldn’t fetch history from iCloud.")
        case .on(let lastSynced?):
            now.timeIntervalSince(lastSynced) < 60
                ? String(localized: "On · synced just now")
                : String(localized: "On · synced \(lastSynced.formatted(.relative(presentation: .named, unitsStyle: .wide)))")
        case .on(nil):
            String(localized: "On · your history syncs to all your devices")
        }
    }

    /// iCloud's own words for a failure, shown under the status, if there are any.
    public var reason: String? {
        switch self {
        case .couldNotStart(let reason), .accountError(let reason), .failed(_, let reason): reason
        default: nil
        }
    }

    /// The root row's value.
    public var short: String {
        switch self {
        case .unavailable: String(localized: "Unavailable")
        case .off, .stopsNextLaunch: String(localized: "Off")
        case .startsNextLaunch, .on: String(localized: "On")
        case .checking: String(localized: "Checking…")
        case .notSignedIn: String(localized: "Not Signed In")
        case .restricted: String(localized: "Restricted")
        case .waiting: String(localized: "Waiting")
        case .couldNotStart, .accountError, .failed: String(localized: "Not Syncing")
        }
    }

    public var tone: SettingsTone {
        switch self {
        case .couldNotStart, .accountError, .failed: .failure
        case .notSignedIn, .restricted: .attention
        default: .plain
        }
    }

    /// The symbol beside the status on the page.
    public var symbol: String {
        switch self {
        case .on: "checkmark.icloud"
        case .off, .stopsNextLaunch, .unavailable: "icloud.slash"
        case .startsNextLaunch, .checking, .waiting: "arrow.clockwise.icloud"
        case .couldNotStart, .accountError, .failed, .notSignedIn, .restricted: "exclamationmark.icloud"
        }
    }
}
