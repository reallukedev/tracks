import Foundation
import SwiftData
@testable import TracksCore

extension TracksStore {
    /// `rows` as the store has them now, in the same order. A row that's gone comes back as
    /// it was.
    ///
    /// Capture, the queues and reconciling save in ``HistoryWriter``'s own contexts, and the
    /// main context's objects keep the values they had until they're fetched again.
    func stored<Model: PersistentModel>(_ rows: [Model]) throws -> [Model] {
        let current = Dictionary(
            try context.fetch(FetchDescriptor<Model>()).map { ($0.persistentModelID, $0) }
        ) { first, _ in first }
        return rows.map { current[$0.persistentModelID] ?? $0 }
    }

    func stored<Model: PersistentModel>(_ row: Model) throws -> Model {
        try stored([row])[0]
    }
}
