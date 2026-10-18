import Testing
import Foundation
import SwiftData
@testable import TracksCore

/// One read-write container per process.
///
/// A second read-write open of the same store falls back to in-memory without an error. App
/// Intents run in the app's process when it's open, so an intent with its own store would
/// capture into nothing.
@MainActor
@Suite("Shared store")
struct StoreSharingTests {

    @Test("shared() hands back the same container every time")
    func sharedIsStable() throws {
        let first = try TracksStore.shared()
        let second = try TracksStore.shared()
        #expect(first === second)
        #expect(first.container === second.container)
    }

    /// Tests and the widget open their own.
    @Test("an explicit in-memory store is independent of the shared one")
    func explicitStoreIsSeparate() throws {
        let shared = try TracksStore.shared()
        let isolated = try TracksStore(inMemory: true)
        #expect(shared !== isolated)
    }

    @Test("the shared store is usable for reads and writes")
    func sharedIsUsable() throws {
        let store = try TracksStore.shared()
        // `swift test` has no App Group, so this should be in-memory. Check, so a change
        // there can't write test rows into the real database.
        guard case .inMemory = store.backing else {
            Issue.record("Refusing to write: shared store is \(store.backing), not in-memory")
            return
        }
        let before = try store.context.fetch(TracksStore.radioCaptures()).count
        _ = try store.insertCapture(
            songKey: "test-\(UUID().uuidString)",
            catalogSongID: "1",
            observation: NowPlayingObservation(title: "T", artistName: "A"),
            session: nil
        )
        #expect(try store.context.fetch(TracksStore.radioCaptures()).count == before + 1)
    }
}

/// Music.app is asked for `playlist "<name>"`, and a name of only spaces made playback fail
/// with an error about a playlist the user never created. A blank name now reads as unset.
@Suite("Playlist name")
struct PlaylistNameTests {

    @Test("a whitespace-only stored name reads as the default")
    func blankNameFallsBack() {
        let suite = "com.luke.tracks.tests.\(UUID().uuidString)"
        let settings = CaptureSettings(suiteName: suite)
        defer { ScratchDefaults.remove(suiteName: suite) }

        UserDefaults(suiteName: suite)?.set("   ", forKey: CaptureSettings.playlistNameKey)
        #expect(settings.playlistName == CaptureSettings.defaultPlaylistName)
    }

    @Test("a blank name is never written in the first place")
    func blankNameIsNotStored() {
        let suite = "com.luke.tracks.tests.\(UUID().uuidString)"
        let settings = CaptureSettings(suiteName: suite)
        defer { ScratchDefaults.remove(suiteName: suite) }

        settings.playlistName = "  "
        #expect(settings.playlistName == CaptureSettings.defaultPlaylistName)
    }

    @Test("a real name survives, with its surrounding space trimmed")
    func realNameIsKept() {
        let suite = "com.luke.tracks.tests.\(UUID().uuidString)"
        let settings = CaptureSettings(suiteName: suite)
        defer { ScratchDefaults.remove(suiteName: suite) }

        settings.playlistName = "  Radio Finds "
        #expect(settings.playlistName == "Radio Finds")
    }
}

/// The lookup dedupe relies on.
@MainActor
@Suite("Dedupe lookup")
struct LastCaptureDateTests {

    /// It used to only look at radio, so an on-demand song was captured again on every
    /// ten-second poll.
    @Test("an on-demand row is found, so it can be deduped against")
    func findsOnDemandRows() throws {
        let store = try TracksStore(inMemory: true)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        store.context.insert(Capture(
            songID: "1", songKey: "walkin", title: "Walkin", artistName: "Denzel Curry",
            kind: .onDemand, capturedAt: when, deviceID: "this-device"
        ))
        try store.context.save()

        #expect(try store.lastCaptureDate(songKey: "walkin") == when)
    }

    /// Imports are dated when found, so one could hide a real play happening now.
    @Test("an imported row does not suppress a real capture")
    func ignoresImportedRows() throws {
        let store = try TracksStore(inMemory: true)
        store.context.insert(Capture(
            songID: "1", songKey: "walkin", title: "Walkin", artistName: "Denzel Curry",
            kind: .imported, capturedAt: .now, deviceID: "this-device"
        ))
        try store.context.save()

        #expect(try store.lastCaptureDate(songKey: "walkin") == nil)
    }

    @Test("a radio row is still found")
    func findsRadioRows() throws {
        let store = try TracksStore(inMemory: true)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        store.context.insert(Capture(
            songID: "1", songKey: "walkin", title: "Walkin", artistName: "Denzel Curry",
            capturedAt: when, deviceID: "this-device"
        ))
        try store.context.save()

        #expect(try store.lastCaptureDate(songKey: "walkin") == when)
    }
}
