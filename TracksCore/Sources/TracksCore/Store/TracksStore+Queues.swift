import Foundation
import SwiftData

/// Queries the retry queues need that the rest of the store doesn't.
extension TracksStore {

    /// The rows among `ids` that still exist, by identity.
    ///
    /// The playlist and scrobble queues fetch rows, wait on the network, then write the result
    /// back. While they wait, ``SyncReconciler`` can merge a synced duplicate away and delete
    /// the very row that was sent, and touching a deleted model traps. So the queues keep
    /// identities across the wait and come back through here, and a row that has gone is
    /// simply missing from the result.
    ///
    /// Only saved rows have a lasting identity (an unsaved one's changes when it's saved), so
    /// save before collecting the identities.
    func existingCaptures(_ ids: [PersistentIdentifier]) -> [PersistentIdentifier: Capture] {
        guard !ids.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<Capture>(
            predicate: #Predicate { ids.contains($0.persistentModelID) }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        return Dictionary(
            rows.filter { !$0.isDeleted }.map { ($0.persistentModelID, $0) }
        ) { first, _ in first }
    }

    /// Rows with a catalog ID but no artwork, newest first, leaving out songs the catalog has
    /// recently had no cover for.
    ///
    /// Without the exclusion those rows stay at the top for good: every pass asks about the
    /// same fifty songs, gets nothing, and never reaches the older rows beneath them.
    static func missingArtwork(
        excludingSongIDs excluded: [String],
        limit: Int = 50
    ) -> FetchDescriptor<Capture> {
        var descriptor = FetchDescriptor<Capture>(
            predicate: #Predicate {
                !$0.songID.isEmpty && $0.artworkURL == nil && !excluded.contains($0.songID)
            },
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }
}
