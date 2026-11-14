import Foundation
import SwiftData

/// The store's capture, queue and reconcile work, off the main actor.
///
/// Each call works in a `ModelContext` of its own and saves before it returns, so no model
/// crosses to another actor: callers hand over and get back identifiers and plain values.
/// Calls run one at a time, so these writes never race each other.
///
/// The main context doesn't take in what these save. Its objects keep their old values until
/// it fetches them again, and saving one of them while it's stale writes those values back.
/// So main-actor code that changes a row fetches it first (see
/// ``TracksStore/existingCaptures(_:)``), and the work that changes rows often lives here.
actor HistoryWriter {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    /// Reads in a context of its own.
    func read<T: Sendable>(_ body: @Sendable (ModelContext) throws -> T) rethrows -> T {
        try body(ModelContext(container))
    }

    /// Changes rows in a context of its own, then saves. Nothing is saved if `body` throws.
    @discardableResult
    func write<T: Sendable>(_ body: @Sendable (ModelContext) throws -> T) throws -> T {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let result = try body(context)
        if context.hasChanges { try context.save() }
        return result
    }

    /// Changes one capture, if it still exists. Sync can merge a row away at any time.
    /// - Returns: whether the change was saved.
    @discardableResult
    func updateCapture(_ id: PersistentIdentifier, _ change: @Sendable (Capture) -> Void) -> Bool {
        (try? write { context in
            guard let capture = TracksStore.existingCaptures([id], in: context)[id] else { return false }
            change(capture)
            return true
        }) ?? false
    }

    // MARK: - Capture

    /// What ``recordCapture(_:)`` needs to keep a play.
    struct NewCapture: Sendable {
        var songKey: String
        var catalogSongID: String?
        var observation: NowPlayingObservation
        var kind: CaptureKind
        /// The station the play's session is for. Nil keeps the play out of any session.
        var session: SessionRequest?
        var now: Date
        /// Why the play is held out of the scrobble queue, if it is.
        var scrobbleHold: String?
    }

    struct SessionRequest: Sendable {
        var stationName: String?
        var policy: SessionPolicy
    }

    /// See ``TracksStore/lastCaptureDate(songKey:in:)``.
    func lastCaptureDate(songKey: String) throws -> Date? {
        try read { try TracksStore.lastCaptureDate(songKey: songKey, in: $0) }
    }

    /// Opens or extends this device's session if asked, and keeps the play, in one save.
    /// - Returns: the play's lasting identity.
    func recordCapture(_ new: NewCapture) throws -> PersistentIdentifier {
        try write { context in
            // As before the move here: a session that can't be opened doesn't lose the play.
            let session = new.session.flatMap {
                try? TracksStore.openSession(in: context, stationName: $0.stationName, policy: $0.policy, now: new.now)
            }
            let capture = TracksStore.insertCapture(
                in: context,
                songKey: new.songKey,
                catalogSongID: new.catalogSongID,
                observation: new.observation,
                kind: new.kind,
                session: session,
                now: new.now
            )
            if let reason = new.scrobbleHold { capture.holdFromScrobbling(reason: reason) }
            // Saved here rather than by `write`, so the identity handed back is the lasting one.
            try context.save()
            return capture.persistentModelID
        }
    }

    /// See ``TracksStore/closeStaleSessions(in:policy:now:deviceID:)``.
    /// - Returns: how many were closed.
    func closeStaleSessions(policy: SessionPolicy, now: Date, deviceID: String) throws -> Int {
        try write { try TracksStore.closeStaleSessions(in: $0, policy: policy, now: now, deviceID: deviceID).count }
    }

    // MARK: - Reconciling

    /// Everything a reconcile folds in. See ``SyncReconciler``.
    func reconcile(reader: ListeningHistoryReader, policy: DedupePolicy) async -> Int {
        var merged = (try? mergeDuplicateStations()) ?? 0
        merged += (try? await mergeDuplicatePlays(reader: reader, policy: policy)) ?? 0
        _ = try? await clearUnloadableArtwork(reader: reader)
        return merged
    }

    /// See ``TracksStore/mergeDuplicateStations(in:)``.
    func mergeDuplicateStations() throws -> Int {
        try write { try TracksStore.mergeDuplicateStations(in: $0) }
    }

    /// The songs `reader` finds with plays close enough to merge, merged by the same rules as
    /// ``TracksStore/mergeDuplicateCaptures(policy:)``.
    ///
    /// The reader is asked first and the rows are fetched afterwards, in one step with the
    /// merge and its save, so what's merged is the store as it is then.
    func mergeDuplicatePlays(reader: ListeningHistoryReader, policy: DedupePolicy) async throws -> Int {
        let groups = try await reader.duplicatePlayGroups(policy: policy)
        guard !groups.isEmpty else { return 0 }
        return try write { try TracksStore.mergeDuplicatePlays(groups, in: $0, policy: policy) }
    }

    /// Forgets covers nothing can load, found by `reader`, so the backfill fetches them again.
    func clearUnloadableArtwork(reader: ListeningHistoryReader) async throws -> Int {
        let ids = try await reader.captureIDsWithUnloadableArtwork()
        guard !ids.isEmpty else { return 0 }
        return try write { context in
            // Checked again, in case a cover was found since the reader looked.
            let rows = TracksStore.existingCaptures(ids, in: context).values.filter {
                $0.artworkURL != nil && !TracksStore.isLoadableArtwork($0.artworkURL)
            }
            for row in rows { row.artworkURL = nil }
            return rows.count
        }
    }
}
