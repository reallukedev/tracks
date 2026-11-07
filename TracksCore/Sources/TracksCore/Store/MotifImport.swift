import Foundation
import SwiftData
#if os(iOS)
import UIKit
#endif

/// Brings listening history over from Motif, the app Tracks replaces.
///
/// Tracks joins Motif's App Group as well as its own, so on a device that has Motif it can
/// see Motif's store. The store is copied first and the copy opened, so Motif's own file is
/// never written, migrated or locked, whether or not Motif is running.
///
/// Every play, session and station comes across as it was, with its original device, so
/// Tracks never adds an old play to the radio playlist or scrobbles it again. A play Tracks
/// already has, by song, kind and time, is skipped, so running it twice adds nothing.
public enum MotifImport {
    /// Motif's App Group, from Info.plist. Nil when this build wasn't given one.
    public static let infoPlistKey = "TracksMotifAppGroupIdentifier"

    public static var groupIdentifier: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String,
              !value.isEmpty, !value.contains("$(")
        else { return nil }
        return value
    }

    /// Where SwiftData keeps a group's default store.
    static func storeURL(inGroup identifier: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)?
            .appending(path: "Library/Application Support/default.store")
    }

    /// Motif's store on this device, if there is one.
    public static var motifStoreURL: URL? {
        guard let identifier = groupIdentifier, let url = storeURL(inGroup: identifier),
              FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        else { return nil }
        return url
    }

    /// Whether this device has Motif history to bring over.
    public static var isAvailable: Bool { motifStoreURL != nil }

    // MARK: - Progress, kept in Tracks' App Group

    static let finishedAtKey = "TracksMotifImportFinishedAt"
    static let importedCountKey = "TracksMotifImportedPlays"

    /// When the last import finished, or nil if it never has on this device.
    public static var finishedAt: Date? {
        CloudSync.defaults.object(forKey: finishedAtKey) as? Date
    }

    /// How many plays the last import brought over.
    public static var importedPlays: Int {
        CloudSync.defaults.integer(forKey: importedCountKey)
    }

    /// Whether to offer, or run, the import: Motif is here and it hasn't run yet.
    public static var isPending: Bool { isAvailable && finishedAt == nil }

    /// Set in iCloud's key-value store by the first device to bring the history over. Every
    /// device with Motif has its own copy of the same synced history, so a second device
    /// importing too would bring each play in twice; it gets them through Tracks' sync instead.
    static let cloudKey = "TracksMotifImportDevice"

    /// The device that already brought Motif's history over, if it wasn't this one.
    public static var importedOnOtherDevice: String? {
        guard finishedAt == nil else { return nil }
        let name = NSUbiquitousKeyValueStore.default.string(forKey: cloudKey)
        return (name?.isEmpty == false) ? name : nil
    }

    /// Whether to bring it over without asking: Motif is here, it hasn't run here, and no
    /// other device has done it.
    public static var shouldRunAutomatically: Bool {
        NSUbiquitousKeyValueStore.default.synchronize()
        return isPending && importedOnOtherDevice == nil
    }

    public struct Outcome: Sendable, Equatable {
        /// Plays added to Tracks.
        public var plays: Int
        /// Plays Motif had that Tracks already had.
        public var skipped: Int
        public var sessions: Int
        public var stations: Int
    }

    public enum Failure: LocalizedError {
        case noMotifHistory
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .noMotifHistory: String(localized: "There's no Motif history on this device.")
            case .unreadable(let reason): String(localized: "Motif's history couldn't be read. \(reason)")
            }
        }
    }

    // MARK: - Running

    /// What to call this device when telling another one it brought the history over.
    @MainActor static var deviceName: String {
        #if os(iOS)
        UIDevice.current.model
        #else
        Host.current().localizedName ?? String(localized: "your Mac")
        #endif
    }

    /// Copies Motif's history into `store`. Reads and writes off the main actor.
    @MainActor
    public static func run(into store: TracksStore) async throws -> Outcome {
        guard let source = motifStoreURL else { throw Failure.noMotifHistory }
        // Claimed before the import rather than after, so another device with Motif that
        // launches meanwhile is less likely to bring the same history over too.
        let name = deviceName
        let cloud = NSUbiquitousKeyValueStore.default
        let earlierClaim = cloud.string(forKey: cloudKey)
        cloud.set(name, forKey: cloudKey)
        cloud.synchronize()
        do {
            return try await importHistory(from: source, into: store, claimedAs: name)
        } catch {
            // Hand the claim back, so another device can still do it.
            if cloud.string(forKey: cloudKey) == name {
                if let earlierClaim { cloud.set(earlierClaim, forKey: cloudKey) } else { cloud.removeObject(forKey: cloudKey) }
                cloud.synchronize()
            }
            throw error
        }
    }

    @MainActor
    private static func importHistory(from source: URL, into store: TracksStore, claimedAs name: String) async throws -> Outcome {
        let copy = try await copyStore(at: source)
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }

        let motif: ModelContainer
        do {
            // A copy, so it can migrate an older Motif store forward and never sync.
            motif = try TracksStore.makeContainer(ModelConfiguration(
                schema: TracksStore.schema,
                url: copy,
                allowsSave: true,
                cloudKitDatabase: .none
            ))
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }

        let destination = store.container
        let policy = CaptureSettings().dedupePolicy
        let outcome = try await Task.detached(priority: .utility) {
            try copyHistory(from: motif, into: destination, policy: policy)
        }.value

        copySettings()
        CloudSync.defaults.set(Date.now, forKey: finishedAtKey)
        CloudSync.defaults.set(outcome.plays, forKey: importedCountKey)
        NSUbiquitousKeyValueStore.default.set(name, forKey: cloudKey)
        return outcome
    }

    /// Copies the store and its write-ahead log into a fresh temporary folder.
    ///
    /// The three files are copied one after another, so Motif writing in between would give
    /// a copy that doesn't open, or one missing its latest plays, and the import would then
    /// be marked done. The copy is only kept if no file changed while it was made.
    @concurrent nonisolated static func copyStore(at source: URL) async throws -> URL {
        for _ in 0..<3 {
            let before = fileStates(of: source)
            let folder = FileManager.default.temporaryDirectory
                .appending(path: "MotifImport-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appending(path: "default.store")
            do {
                for suffix in storeSuffixes {
                    let from = URL(filePath: source.path(percentEncoded: false) + suffix)
                    guard FileManager.default.fileExists(atPath: from.path(percentEncoded: false)) else { continue }
                    try FileManager.default.copyItem(at: from, to: URL(filePath: destination.path(percentEncoded: false) + suffix))
                }
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
            if fileStates(of: source) == before { return destination }
            try? FileManager.default.removeItem(at: folder)
            try await Task.sleep(for: .seconds(1))
        }
        throw Failure.unreadable(String(localized: "Motif was busy. Quit Motif and try again."))
    }

    nonisolated static let storeSuffixes = ["", "-wal", "-shm"]

    /// Size and modification date of the store and its log, to tell whether either changed.
    /// The shared-memory index is left out: SQLite rebuilds it from the log, and readers
    /// touch it.
    nonisolated static func fileStates(of store: URL) -> [String] {
        ["", "-wal"].map { suffix in
            let path = store.path(percentEncoded: false) + suffix
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return "-" }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? -1
            return "\(size)@\(modified)"
        }
    }

    /// The part that does the work, separate from where the files are so tests can give it
    /// two containers.
    nonisolated static func copyHistory(
        from motif: ModelContainer,
        into tracks: ModelContainer,
        policy: DedupePolicy = .default
    ) throws -> Outcome {
        let from = ModelContext(motif)
        let to = ModelContext(tracks)
        to.autosaveEnabled = false

        // Stations, matched on the key the store merges them on.
        var stations: [String: Station] = [:]
        for station in try to.fetch(FetchDescriptor<Station>()) {
            stations[TracksStore.stationKey(station.name)] = stations[TracksStore.stationKey(station.name)] ?? station
        }
        var newStations = 0
        var stationFor: [PersistentIdentifier: Station] = [:]
        for old in try from.fetch(FetchDescriptor<Station>()) {
            let key = TracksStore.stationKey(old.name)
            if let existing = stations[key] {
                existing.firstSeenAt = min(existing.firstSeenAt, old.firstSeenAt)
                existing.lastSeenAt = max(existing.lastSeenAt, old.lastSeenAt)
                existing.catalogID = existing.catalogID ?? old.catalogID
                existing.artworkURL = existing.artworkURL ?? old.artworkURL
                stationFor[old.persistentModelID] = existing
            } else {
                let station = Station(name: old.name, catalogID: old.catalogID,
                                      artworkURL: old.artworkURL, firstSeenAt: old.firstSeenAt)
                station.lastSeenAt = old.lastSeenAt
                to.insert(station)
                stations[key] = station
                stationFor[old.persistentModelID] = station
                newStations += 1
            }
        }

        // Sessions, matched on when they started and on which device.
        var sessions: [String: Session] = [:]
        for session in try to.fetch(FetchDescriptor<Session>()) {
            sessions[sessionKey(session.startedAt, session.deviceID)] = session
        }
        var newSessions = 0
        var sessionFor: [PersistentIdentifier: Session] = [:]
        for old in try from.fetch(FetchDescriptor<Session>()) {
            let key = sessionKey(old.startedAt, old.deviceID)
            if let existing = sessions[key] {
                sessionFor[old.persistentModelID] = existing
                continue
            }
            let session = Session(startedAt: old.startedAt,
                                  station: old.station.flatMap { stationFor[$0.persistentModelID] },
                                  deviceID: old.deviceID)
            session.lastActivityAt = old.lastActivityAt
            // Motif's device is gone, so nothing would ever close a session it left open.
            session.endedAt = old.endedAt ?? old.lastActivityAt
            to.insert(session)
            sessions[key] = session
            sessionFor[old.persistentModelID] = session
            newSessions += 1
        }

        // Plays. One Tracks already had counts as the same play when it's the same song
        // inside the window the store merges duplicates over, so a play Tracks folded into
        // its twin after the last import isn't brought back. Within Motif's own plays only
        // exact copies are skipped, and the store's merge decides the rest as it always does.
        var existing: [String: [(at: Date, kind: CaptureKind)]] = [:]
        for play in try to.fetch(FetchDescriptor<Capture>()) {
            existing[HistoryImport.key(title: play.title, artistName: play.artistName), default: []]
                .append((play.capturedAt, play.kind))
        }
        var seen: Set<String> = []
        var plays = 0, skipped = 0
        var batch = 0
        for old in try from.fetch(FetchDescriptor<Capture>(sortBy: [SortDescriptor(\.capturedAt)])) {
            let identity = HistoryImport.key(title: old.title, artistName: old.artistName)
            let isKnown = existing[identity]?.contains { other in
                let (earlier, later) = other.at <= old.capturedAt ? (other.kind, old.kind) : (old.kind, other.kind)
                return abs(other.at.timeIntervalSince(old.capturedAt)) < policy.mergeWindow(earlier: earlier, later: later)
            } ?? false
            guard !isKnown, seen.insert(playKey(old)).inserted else {
                skipped += 1
                continue
            }
            let play = Capture(
                songID: old.songID,
                songKey: old.songKey,
                title: old.title,
                artistName: old.artistName,
                albumTitle: old.albumTitle,
                artworkURL: old.artworkURL,
                kind: old.kind,
                capturedAt: old.capturedAt,
                platform: old.platform,
                deviceID: old.capturedByDeviceID,
                source: old.sourceRawValue.map { PlaySource(stored: $0) },
                session: old.session.flatMap { sessionFor[$0.persistentModelID] }
            )
            play.catalogLookupAttempts = old.catalogLookupAttempts
            play.needsPlaylistWrite = old.needsPlaylistWrite
            play.addedToPlaylistAt = old.addedToPlaylistAt
            play.playlistWriteAttempts = old.playlistWriteAttempts
            play.lastPlaylistWriteError = old.lastPlaylistWriteError
            play.playedBackAt = old.playedBackAt
            play.scrobbledAt = old.scrobbledAt
            play.scrobbleAttempts = old.scrobbleAttempts
            play.lastScrobbleError = old.lastScrobbleError
            to.insert(play)
            plays += 1
            batch += 1
            if batch == 2_000 {
                try to.save()
                batch = 0
            }
        }
        try to.save()
        return Outcome(plays: plays, skipped: skipped, sessions: newSessions, stations: newStations)
    }

    nonisolated static func playKey(_ capture: Capture) -> String {
        "\(HistoryImport.key(title: capture.title, artistName: capture.artistName))\u{1F}\(capture.kindRawValue)\u{1F}\(Int(capture.capturedAt.timeIntervalSinceReferenceDate.rounded()))"
    }

    nonisolated static func sessionKey(_ startedAt: Date, _ deviceID: String?) -> String {
        "\(Int(startedAt.timeIntervalSinceReferenceDate.rounded()))\u{1F}\(deviceID ?? "")"
    }

    // MARK: - Settings

    /// Motif's settings that are worth keeping, from its App Group's defaults. Device IDs,
    /// sync state, caches and the Last.fm account (whose key Tracks can't read) stay behind.
    static let carriedSettings = [
        "blockedArtists", "dedupeWindowSeconds", "forgottenSongs", "limitsPlaylistSize",
        "menuBarLabelStyle", "minimumListenSeconds", "passedOverSongs", "playlistID",
        "playlistName", "playlistSizeLimit", "playlistTrackCount", "recentlyPlayedAnchor",
        "scrobblesImported",
    ]

    /// Copies ``carriedSettings`` that Tracks hasn't set itself.
    static func copySettings() {
        guard let identifier = groupIdentifier, let motif = UserDefaults(suiteName: identifier) else { return }
        let tracks = CloudSync.defaults
        for key in carriedSettings where tracks.object(forKey: key) == nil {
            if let value = motif.object(forKey: key) { tracks.set(value, forKey: key) }
        }
    }
}
