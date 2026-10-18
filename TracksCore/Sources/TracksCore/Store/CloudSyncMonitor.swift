import CloudKit
import CoreData
import Foundation
import Observation

/// What the CloudKit mirror last said about itself.
///
/// A store that opened with sync can still fail to sync. The container opens, and only
/// afterwards does the mirror find out CloudKit won't take its records, as happened when
/// the Production schema was missing `CD_scrobbledAt`. Every export failed, setup never
/// finished, nothing was imported, and Settings still said "On", while the Mac and the iPhone
/// quietly grew two different histories. This listens to the events the mirror posts so that
/// failure can be shown.
@MainActor
@Observable
public final class CloudSyncMonitor {

    /// One of the mirror's three kinds of work.
    public enum Activity: String, Sendable, Equatable {
        case setup, `import`, export
    }

    public struct Failure: Sendable, Equatable {
        public let activity: Activity
        public let message: String
        public let date: Date
    }

    /// The most recent failure that nothing of the same kind has succeeded since, if any.
    public private(set) var failure: Failure?

    /// When an import or export last finished without a problem, since launch.
    public private(set) var lastSynced: Date?

    @ObservationIgnored private var observer: NSObjectProtocol?

    public init() {}

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Starts listening. Call it before the store opens: setup is reported as soon as the
    /// container is made, and a setup failure is the one that stops everything else.
    public func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[
                NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            ] as? NSPersistentCloudKitContainer.Event,
                  let activity = Activity(event.type),
                  // Posted once when the work starts and again when it ends.
                  let endDate = event.endDate
            else { return }
            let succeeded = event.succeeded
            let message = event.error.map(Self.message(for:))
            MainActor.assumeIsolated {
                self?.record(activity, succeeded: succeeded, message: message, at: endDate)
            }
        }
    }

    /// Folds in one finished piece of work.
    ///
    /// A success clears only a failure of the same kind. An import can succeed while every
    /// export is being refused, and that must still show.
    func record(_ activity: Activity, succeeded: Bool, message: String?, at date: Date) {
        if succeeded {
            if failure?.activity == activity { failure = nil }
            // Setup only opens the mirror; nothing has moved yet.
            if activity != .setup { lastSynced = max(lastSynced ?? date, date) }
            return
        }
        failure = Failure(
            activity: activity,
            message: message ?? Self.words(for: nil),
            date: date
        )
    }

    /// A CloudKit error in words: what happened and what to do. CloudKit's own description
    /// and the server's message only go to the log, where CloudKit also writes the reason
    /// for each refused record.
    ///
    /// A refused save arrives as a partial failure whose own description is only "Failed to
    /// modify some records". The reason is on one of the records inside it, surrounded by
    /// dozens of "Batch Request Failed" errors that only mean they were sent alongside it.
    public nonisolated static func message(for error: any Error) -> String {
        Log.iCloud.error("iCloud sync failed: \(String(describing: error), privacy: .public)")
        guard let error = error as? CKError else { return words(for: nil) }
        let cause = error.partialErrorsByItemID?.values
            .compactMap { $0 as? CKError }
            .filter { $0.code != .batchRequestFailed }
            // Dictionary order isn't stable, so pick the same one every time.
            .min { $0.code.rawValue < $1.code.rawValue }
        return words(for: (cause ?? error).code)
    }

    /// Why the store couldn't open with iCloud, in words. The error goes to the log.
    public nonisolated static func startFailure(for error: any Error) -> String {
        if error is CKError { return message(for: error) }
        Log.iCloud.error("The store couldn't open with iCloud: \(String(describing: error), privacy: .public)")
        return String(localized: "Tracks couldn’t open your history with iCloud. Check you’re signed in to iCloud, then open Tracks again.")
    }

    private nonisolated static func words(for code: CKError.Code?) -> String {
        switch code {
        case .notAuthenticated:
            String(localized: "You’re signed out of iCloud. Sign in to iCloud in Settings to sync your history.")
        case .networkUnavailable, .networkFailure:
            String(localized: "You’re offline. Tracks will sync when you’re back online.")
        case .serviceUnavailable, .requestRateLimited, .zoneBusy:
            String(localized: "iCloud is busy. Tracks will try again shortly.")
        case .quotaExceeded:
            String(localized: "Your iCloud storage is full. Free up space in iCloud to keep syncing.")
        case .permissionFailure, .managedAccountRestricted:
            String(localized: "iCloud isn’t letting Tracks sync on this device. Check iCloud in Settings.")
        case .incompatibleVersion:
            String(localized: "This version of Tracks can’t sync. Update Tracks on all your devices.")
        // A record the Production schema doesn't have a field for, as when a build's new
        // field hasn't been deployed.
        case .invalidArguments, .serverRejectedRequest:
            String(localized: "iCloud wouldn’t take this device’s history. Update Tracks on all your devices.")
        case .accountTemporarilyUnavailable:
            String(localized: "iCloud isn’t available right now. Tracks will try again.")
        default:
            String(localized: "iCloud sync ran into a problem. Tracks will try again.")
        }
    }
}

extension CloudSyncMonitor.Activity {
    init?(_ type: NSPersistentCloudKitContainer.EventType) {
        switch type {
        case .setup: self = .setup
        case .import: self = .import
        case .export: self = .export
        @unknown default: return nil
        }
    }
}
