import CoreData
import Foundation

/// Folds in what iCloud brings down, as soon as it arrives.
///
/// Sync produces rows no local write can prevent: each device makes its own ``Station`` for
/// the same station, and a station playing on the Mac shows up in the iPhone's system player
/// too, so both capture the play. ``TracksStore/mergeDuplicateStations()`` and
/// ``TracksStore/mergeDuplicateCaptures(policy:)`` settle those, and every device reaches the
/// same answer from its own copy.
///
/// Until this existed, the merge only ran at launch and on a sixty-second timer that only
/// turns while capture is running, so a device that was open but idle showed the duplicates
/// until something else happened to it. Core Data posts
/// `NSPersistentStoreRemoteChange` when the CloudKit mirror writes to the store, which is the
/// actual moment there is something to reconcile.
///
/// The timer stays as a backstop: the notification is the fast path, not the only one.
@MainActor
public final class SyncReconciler {

    /// Posted after a batch of synced changes has been folded in, so the UI and the widgets
    /// can refresh. `userInfo[mergedCountKey]` is how many rows were merged away.
    public static let didReconcileNotification = Notification.Name("TracksDidReconcileSyncedChanges")
    public static let mergedCountKey = "merged"

    /// How long to let changes pile up before merging. A CloudKit import arrives as a burst
    /// of writes, and merging once at the end of it is both cheaper and less likely to churn
    /// rows the next write would have merged anyway.
    private static let settle: Duration = .seconds(2)

    private let store: TracksStore
    private var pending: Task<Void, Never>?
    private var merging: Task<Void, Never>?
    /// Asked for again while a merge was running, so another is owed.
    private var needsAnotherMerge = false
    private var observer: NSObjectProtocol?

    public init(store: TracksStore) {
        self.store = store
    }

    isolated deinit {
        pending?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Starts watching. Does nothing if the store isn't synced, since then nothing arrives
    /// from anywhere else and the launch-time merge is enough.
    public func start() {
        guard observer == nil, store.backing.isSynced else { return }
        // The notification's object is the persistent store coordinator, which SwiftData
        // doesn't expose, so this listens for any of them. There is only one in the process.
        observer = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.remoteChangeArrived() }
        }
    }

    private func remoteChangeArrived() {
        // The first change starts the clock; later ones in the same burst join it rather
        // than putting the merge off again, so a long import still reconciles as it goes.
        guard pending == nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled else { return }
            self?.reconcile()
        }
    }

    /// Merges now, whatever the timer is doing. Call it when the app comes back to the front,
    /// where the user is about to look at the result.
    ///
    /// Finding duplicate plays happens in the background (see
    /// ``TracksStore/mergeDuplicatePlays(policy:)``), so this returns straight away and posts
    /// ``didReconcileNotification`` when the merge is done. Asking again while one is running
    /// runs one more afterwards, rather than two at once.
    ///
    /// - Returns: the merge, for a caller that needs to wait for it.
    @discardableResult
    public func reconcile() -> Task<Void, Never> {
        pending?.cancel()
        pending = nil
        if let merging {
            needsAnotherMerge = true
            return merging
        }
        // Holds the store rather than the reconciler, so a merge that has started finishes
        // even if the reconciler is let go meanwhile.
        let task = Task { [weak self, store] in
            repeat {
                self?.needsAnotherMerge = false
                let merged = await Self.merge(store)
                NotificationCenter.default.post(
                    name: Self.didReconcileNotification,
                    object: self,
                    userInfo: [Self.mergedCountKey: merged]
                )
            } while self?.needsAnotherMerge == true
            self?.merging = nil
        }
        merging = task
        return task
    }

    /// Everything a reconcile folds in. Also used by the capture service's timer.
    public static func merge(_ store: TracksStore) async -> Int {
        var merged = (try? store.mergeDuplicateStations()) ?? 0
        merged += (try? await store.mergeDuplicatePlays()) ?? 0
        _ = try? store.clearUnloadableArtwork()
        return merged
    }
}
