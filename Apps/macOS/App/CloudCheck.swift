#if DEBUG
import CloudKit
import SwiftData
import TracksCore

/// Looks through the Core Data mirror in the private iCloud database for sample-data rows.
///
/// Read-only unless `--purge` is passed. Then it deletes only captures by an invented artist
/// on an invented album, the invented stations, and those stations' sessions.
enum CloudCheck {
    static let zone = CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone", ownerName: CKCurrentUserDefaultName)

    /// Deletes the same sample rows from this Mac's own store, opened without sync. For when
    /// the rows came down from iCloud before the iCloud copy was purged.
    @MainActor
    static func purgeLocal() -> Int32 {
        do {
            let store = try TracksStore(sync: false)
            guard case .appGroup = store.backing else {
                print("The real store isn't available (\(store.backing)); nothing done.")
                return 1
            }
            let artists = Set(DemoLibrary.artistCredits)
            let albums = Set(DemoLibrary.albumNames)
            let stationNames = Set(DemoLibrary.stations)
            let context = store.context

            let captures = try context.fetch(FetchDescriptor<Capture>()).filter {
                artists.contains($0.artistName) && albums.contains($0.albumTitle ?? "")
            }
            let stations = try context.fetch(FetchDescriptor<Station>()).filter { stationNames.contains($0.name) }
            let sessions = stations.flatMap { $0.sessions ?? [] }
            captures.forEach(context.delete)
            sessions.forEach(context.delete)
            stations.forEach(context.delete)
            try context.save()
            let left = try context.fetchCount(FetchDescriptor<Capture>())
            print("Deleted \(captures.count) sample captures, \(sessions.count) sessions and \(stations.count) stations. \(left) captures left.")
            return 0
        } catch {
            print("Local purge failed: \(error)")
            return 1
        }
    }

    @MainActor
    static func run(purge: Bool) async -> Int32 {
        guard let identifier = CloudSync.containerIdentifier else {
            print("No iCloud container in this build.")
            return 1
        }
        let database = CKContainer(identifier: identifier).privateCloudDatabase
        let demoArtists = Set(DemoLibrary.artistCredits)
        let demoAlbums = Set(DemoLibrary.albumNames)
        let demoStations = Set(DemoLibrary.stations)

        var token: CKServerChangeToken?
        var counts: [String: Int] = [:]
        var fake: [CKRecord.ID] = []
        var fakeStations: [String] = []
        var sample: [String] = []
        var sessions: [(id: CKRecord.ID, station: String)] = []
        do {
            while true {
                let changes = try await database.recordZoneChanges(inZoneWith: zone, since: token)
                for (_, result) in changes.modificationResultsByID {
                    guard let record = try? result.get().record else { continue }
                    counts[record.recordType, default: 0] += 1
                    switch record.recordType {
                    case "CD_Capture":
                        // Both an invented artist and an invented album, so a real band that
                        // happens to share a name can't match.
                        if let artist = record["CD_artistName"] as? String, demoArtists.contains(artist),
                           let album = record["CD_albumTitle"] as? String, demoAlbums.contains(album) {
                            fake.append(record.recordID)
                            if sample.count < 5 { sample.append("\(record["CD_title"] ?? "?") by \(artist)") }
                        }
                    case "CD_Station":
                        if let name = record["CD_name"] as? String, demoStations.contains(name) {
                            fake.append(record.recordID)
                            fakeStations.append(record.recordID.recordName)
                        }
                    case "CD_Session":
                        if let station = record["CD_station"] as? String {
                            sessions.append((record.recordID, station))
                        }
                    default:
                        break
                    }
                }
                token = changes.changeToken
                if !changes.moreComing { break }
            }
        } catch {
            print("Couldn't read the zone: \(error)")
            return 1
        }

        // Sessions belong to a station; the invented stations' sessions are sample data too.
        let fakeSessions = sessions.filter { fakeStations.contains($0.station) }.map(\.id)
        print("Sample captures: \(fake.count - fakeStations.count), stations: \(fakeStations.count), sessions: \(fakeSessions.count)")
        fake += fakeSessions

        // The local copy too, read-only and without sync, in case sample rows already came down.
        if let local = try? TracksStore(readOnly: true, sync: false),
           let rows = try? local.context.fetch(FetchDescriptor<Capture>()) {
            let sampleRows = rows.filter { demoArtists.contains($0.artistName) && demoAlbums.contains($0.albumTitle ?? "") }
            print("Local store: \(rows.count) captures, \(sampleRows.count) of them sample data (\(local.backing))")
        }

        print("Records by type: \(counts.sorted { $0.key < $1.key })")
        print("Sample-data records found: \(fake.count)")
        sample.forEach { print("  e.g. \($0)") }
        guard purge, !fake.isEmpty else { return 0 }

        for chunk in stride(from: 0, to: fake.count, by: 300).map({ Array(fake[$0..<min($0 + 300, fake.count)]) }) {
            do {
                _ = try await database.modifyRecords(saving: [], deleting: chunk)
            } catch {
                print("Delete failed: \(error)")
                return 1
            }
        }
        print("Deleted \(fake.count) sample-data records.")
        return 0
    }
}
#endif
