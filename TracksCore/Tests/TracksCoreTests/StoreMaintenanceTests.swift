import Testing
import Foundation
import SwiftData
@testable import TracksCore

/// Housekeeping the store does on open and after imports, and the narrowed scans behind it.
@MainActor
@Suite("Store maintenance")
struct StoreMaintenanceTests {
    let store: TracksStore
    let suiteName = "com.luke.tracks.tests.\(UUID().uuidString)"

    init() throws {
        store = try TracksStore(inMemory: true)
    }

    // MARK: - Legacy stamp

    @Test("rows from before sync are stamped with this device, and only then marked done")
    func stampsLegacyRows() throws {
        store.context.insert(Capture(songID: "1", title: "Old", artistName: "A", deviceID: ""))
        store.context.insert(Capture(songID: "2", title: "New", artistName: "A", deviceID: "phone"))
        try store.context.save()

        var done = false
        #expect(store.stampLegacyCaptures(deviceID: "mac", isDone: { done }, markDone: { done = true }))
        #expect(done)

        let rows = try store.context.fetch(TracksStore.allCaptures())
        #expect(Set(rows.map(\.capturedByDeviceID)) == ["mac", "phone"])
    }

    @Test("once done, the stamp leaves later unstamped rows alone")
    func stampRunsOnce() throws {
        store.context.insert(Capture(songID: "1", title: "Old", artistName: "A", deviceID: ""))
        try store.context.save()

        #expect(store.stampLegacyCaptures(deviceID: "mac", isDone: { true }, markDone: {
            Issue.record("marked done twice")
        }))
        #expect(try store.context.fetch(TracksStore.allCaptures()).first?.capturedByDeviceID == "")
    }

    // MARK: - Recently Played anchor

    @Test("the anchor moves after a successful import, and when nothing was new")
    func anchorMovesAfterSuccess() throws {
        let settings = CaptureSettings(suiteName: suiteName)
        defer { ScratchDefaults.remove(suiteName: suiteName) }
        let songs = [PlayedSong(songID: "1", title: "One", artistName: "A")]

        #expect(try store.importPlayedSongs(songs, settings: settings) == 1)
        let anchor = settings.recentlyPlayedAnchor
        #expect(anchor == [HistoryImport.key(title: "One", artistName: "A")])

        // Already imported, so nothing new; the anchor still reflects this list.
        settings.recentlyPlayedAnchor = []
        #expect(try store.importPlayedSongs(songs, settings: settings) == 0)
        #expect(settings.recentlyPlayedAnchor == anchor)
    }

    // MARK: - Narrowed scans

    @Test("forgetting matches case, accents and spacing, for plain and accented names")
    func forgetMatchesFoldedNames() throws {
        let settings = CaptureSettings(suiteName: suiteName)
        defer { ScratchDefaults.remove(suiteName: suiteName) }
        store.context.insert(Capture(songID: "1", title: "Café", artistName: "Band"))
        store.context.insert(Capture(songID: "2", title: " CAFE ", artistName: "band"))
        store.context.insert(Capture(songID: "3", title: "Cafe Society", artistName: "Band"))
        store.context.insert(Capture(songID: "4", title: "Cafe", artistName: "Other"))
        try store.context.save()

        #expect(try store.forgetSong(title: "cafe", artistName: "BAND", settings: settings) == 2)
        #expect(try store.forgetSong(title: "Cafe Society", artistName: "Bänd", settings: settings) == 1)
        #expect(try store.context.fetch(TracksStore.allCaptures()).map(\.artistName) == ["Other"])
    }

    /// The same cases through the history reader, which the app uses so an accented name
    /// doesn't read every play on the main actor.
    @Test("forgetting through the history reader matches the same plays")
    func forgetThroughReaderMatchesFoldedNames() async throws {
        let settings = CaptureSettings(suiteName: suiteName)
        defer { ScratchDefaults.remove(suiteName: suiteName) }
        store.context.insert(Capture(songID: "1", title: "Café", artistName: "Band"))
        store.context.insert(Capture(songID: "2", title: " CAFE ", artistName: "band"))
        store.context.insert(Capture(songID: "3", title: "Cafe Society", artistName: "Band"))
        store.context.insert(Capture(songID: "4", title: "Cafe", artistName: "Other"))
        try store.context.save()

        #expect(try await store.forgetSong(title: "cafe", artistName: "BAND", settings: settings) == 2)
        #expect(try await store.forgetSong(title: "Cafe Society", artistName: "Bänd", settings: settings) == 1)
        #expect(try store.context.fetch(TracksStore.allCaptures()).map(\.artistName) == ["Other"])
        #expect(settings.forgottenSongs.contains(HistoryImport.key(title: "Café", artistName: "Band")))
    }

    @Test("forgetting through the history reader sees a play saved just before")
    func forgetThroughReaderSeesNewPlays() async throws {
        let settings = CaptureSettings(suiteName: suiteName)
        defer { ScratchDefaults.remove(suiteName: suiteName) }
        store.context.insert(Capture(songID: "1", title: "Één", artistName: "Band"))
        try store.context.save()
        // The reader has read the store once already.
        _ = try await store.historyReader.read()

        store.context.insert(Capture(songID: "2", title: "een", artistName: "BAND"))
        try store.context.save()

        #expect(try await store.forgetSong(title: "Één", artistName: "Band", settings: settings) == 2)
    }

    @Test("artwork clean-up only reads rows that have a cover")
    func artworkScansAreNarrowed() async throws {
        store.context.insert(Capture(songID: "1", title: "None", artistName: "A"))
        store.context.insert(Capture(
            songID: "2", title: "Bad", artistName: "A", artworkURL: "musicKit://artwork/transient/x"
        ))
        store.context.insert(Capture(
            songID: "3", title: "Good", artistName: "A", artworkURL: "https://example.test/a.jpg"
        ))
        try store.context.save()

        #expect(try store.context.fetchCount(TracksStore.capturesWithArtwork()) == 2)
        #expect(try store.clearUnloadableArtwork() == 1)
        #expect(try await store.artworkURLs() == ["https://example.test/a.jpg"])
        #expect(try store.clearArtwork(urls: ["https://example.test/a.jpg"]) == 1)
        #expect(try store.context.fetchCount(TracksStore.capturesWithArtwork()) == 0)
    }

    // MARK: - Schema

    @Test("every container is opened on the versioned schema")
    func schemaIsVersioned() throws {
        #expect(TracksStore.schema.version == TracksSchemaV2.versionIdentifier)
        #expect(TracksMigrationPlan.schemas.map(ObjectIdentifier.init)
            == [ObjectIdentifier(TracksSchemaV1.self), ObjectIdentifier(TracksSchemaV2.self)])
        #expect(store.container.schema.entities.map(\.name).sorted()
            == ["Capture", "Session", "Station", "StatsSnapshot"])
    }
}
