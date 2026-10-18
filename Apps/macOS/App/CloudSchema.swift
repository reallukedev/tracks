#if DEBUG
import CoreData
import Foundation
import SwiftData
import TracksCore

/// Creates every record type and field in the iCloud container's Development schema.
///
/// CloudKit's Development environment only adds a field when a record arrives with a value
/// in it, so an optional that happened to be nil on every synced row never makes it into the
/// schema, and a deploy to Production leaves it out. The shipped app then has every save
/// refused: `CD_Capture.CD_scrobbledAt` and then `CD_Session.CD_deviceID` went that way.
/// `initializeCloudKitSchema` uploads a representative record for every entity with every
/// field set, so the schema matches the model before it's deployed.
///
/// A debug build is signed for the Development environment, which is the only one a client
/// can change. It works on a scratch store, so the real history is never opened.
enum CloudSchema {
    @MainActor
    static func initializeDevelopment() -> Int32 {
        guard let identifier = CloudSync.containerIdentifier else {
            print("No iCloud container in this build.")
            return 1
        }
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: TracksSchemaV1.models) else {
            print("Couldn't build a Core Data model from the SwiftData schema.")
            return 1
        }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TracksCloudSchema-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let description = NSPersistentStoreDescription(url: directory.appending(path: "Schema.store"))
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: identifier
            )
            description.shouldAddStoreAsynchronously = false

            let container = NSPersistentCloudKitContainer(name: "Tracks", managedObjectModel: model)
            container.persistentStoreDescriptions = [description]
            var loadError: (any Error)?
            container.loadPersistentStores { _, error in loadError = error }
            if let loadError { throw loadError }

            try container.initializeCloudKitSchema(options: [])

            for store in container.persistentStoreCoordinator.persistentStores {
                try container.persistentStoreCoordinator.remove(store)
            }
        } catch {
            print("Schema upload failed: \(error)")
            return 1
        }

        let entities = model.entities.compactMap(\.name).sorted()
        print("Uploaded the schema for \(entities.joined(separator: ", ")) to \(identifier) (Development).")
        print("Deploy it in the CloudKit Console: Schema → Deploy Schema Changes.")
        return 0
    }
}
#endif
