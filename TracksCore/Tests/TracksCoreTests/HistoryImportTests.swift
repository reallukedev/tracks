import Testing
import Foundation
import SwiftData
@testable import TracksCore

/// Distinct titles by default, since identity is title and artist. Apple's history can give
/// one song more than one id.
private func played(_ id: String, _ title: String? = nil) -> PlayedSong {
    PlayedSong(songID: id, title: title ?? "Song \(id)", artistName: "An Artist")
}

/// Filling in listening from while the app wasn't running.
@Suite("History import")
struct HistoryImportSelectionTests {

    /// Apple returns newest first.
    @Test("new songs come back in listening order")
    func reversesIntoListeningOrder() {
        let songs = HistoryImport.newSongs(in: [played("3"), played("2"), played("1")], known: [])
        #expect(songs.map(\.songID) == ["1", "2", "3"])
    }

    @Test("songs already captured are skipped")
    func skipsKnown() {
        let known = [HistoryImport.key(title: "Song 2", artistName: "An Artist")]
        let songs = HistoryImport.newSongs(
            in: [played("3"), played("2"), played("1")], known: Set(known)
        )
        #expect(songs.map(\.songID) == ["1", "3"])
    }

    /// Apple's list can have the same song under a catalog id and a library id.
    @Test("one song under two ids is imported once")
    func collapsesRepeatsWithinTheSource() {
        let songs = HistoryImport.newSongs(
            in: [played("1792217895", "lvl 6"), played("i.7PJNvmoTVgvlqKb", "lvl 6")],
            known: []
        )
        #expect(songs.count == 1)
    }

    /// A macOS capture gets its catalog id from search, which may not match Apple's history.
    @Test("a song already captured under a different id is skipped")
    func skipsKnownUnderAnotherID() {
        let known = [HistoryImport.key(title: "lvl 6", artistName: "An Artist")]
        #expect(HistoryImport.newSongs(in: [played("999", "lvl 6")], known: Set(known)).isEmpty)
    }

    @Test("case and accents do not defeat the match")
    func keyIgnoresCaseAndAccents() {
        #expect(
            HistoryImport.key(title: "Café", artistName: "Sevens")
                == HistoryImport.key(title: "  cafe ", artistName: "SEVENS")
        )
    }

    @Test(arguments: [
        (["c", "b", "a"], ["b", "a"], 1),       // one new song on top
        (["b", "a"], ["b", "a"], 0),            // nothing played since
        (["b", "c", "a"], ["b", "a"], 2),       // c played, then b again
        (["a", "b"], ["b", "a"], 1),            // a played again
        (["x", "y"], [], 2),                    // first import
        (["d", "c", "b"], ["c", "b", "a"], 1),  // the oldest fell off the end
    ])
    func `only the top of the list is new`(current: [String], previous: [String], expected: Int) {
        #expect(HistoryImport.unseenCount(in: current, previous: previous) == expected)
    }

    @Test("songs with no catalog id are not importable")
    func requiresACatalogID() {
        #expect(HistoryImport.newSongs(in: [played("")], known: []).isEmpty)
    }
}

@MainActor
@Suite("Importing into the store")
struct HistoryImportStoreTests {
    /// Each test gets its own defaults, so the stored anchor can't leak between tests, and
    /// they are removed when it finishes.
    private let scratch = ScratchDefaults()
    var settings: CaptureSettings { scratch.settings }

    @Test("imported rows are marked imported, not radio or on demand")
    func marksSourceAsUnknown() throws {
        let store = try TracksStore(inMemory: true)
        #expect(try store.importPlayedSongs([played("1"), played("2")], settings: settings) == 2)

        let rows = try store.context.fetch(TracksStore.allCaptures())
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.kind == .imported })
        #expect(rows.allSatisfy { !$0.kind.sourceIsKnown })
    }

    /// Apple has already counted an imported play.
    @Test("imported rows are never owed a playlist write")
    func neverWritesToThePlaylist() throws {
        let store = try TracksStore(inMemory: true)
        try store.importPlayedSongs([played("1")], settings: settings)
        let row = try #require(try store.context.fetch(TracksStore.allCaptures()).first)
        #expect(!row.needsPlaylistWrite)
    }

    /// Import runs on every launch.
    @Test("importing the same list twice adds nothing the second time")
    func isIdempotent() throws {
        let store = try TracksStore(inMemory: true)
        let songs = [played("1"), played("2")]
        #expect(try store.importPlayedSongs(songs, settings: settings) == 2)
        #expect(try store.importPlayedSongs(songs, settings: settings) == 0)
        #expect(try store.context.fetch(TracksStore.allCaptures()).count == 2)
    }

    @Test("a song already witnessed is not imported over the top")
    func doesNotDuplicateAWitnessedCapture() throws {
        let store = try TracksStore(inMemory: true)
        store.context.insert(Capture(songID: "1", title: "Song 1", artistName: "An Artist", deviceID: "this-device"))
        try store.context.save()

        #expect(try store.importPlayedSongs([played("1")], settings: settings) == 0)
        let rows = try store.context.fetch(TracksStore.allCaptures())
        #expect(rows.count == 1)
        #expect(rows.first?.kind == .radio)
    }

    /// Apple lists a song the moment it starts, so skipping through Tracks Radio on the Mac
    /// filled the iPhone's import with songs never really heard.
    @Test("a song Tracks’ player skipped is not imported as a play")
    func skipsWhatThePlayerPassedOver() throws {
        let store = try TracksStore(inMemory: true)
        settings.notePassedOver(title: "Song 2", artistName: "An Artist")

        #expect(try store.importPlayedSongs([played("3"), played("2"), played("1")], settings: settings) == 2)
        let titles = try store.context.fetch(TracksStore.allCaptures()).map(\.title)
        #expect(!titles.contains("Song 2"))
    }

    @Test("the same song outside the window is a new play")
    func importsAgainOutsideTheWindow() throws {
        let store = try TracksStore(inMemory: true)
        let old = Capture(
            songID: "1", title: "Song 1", artistName: "An Artist",
            capturedAt: .now.addingTimeInterval(-72 * 3600), deviceID: "this-device"
        )
        store.context.insert(old)
        try store.context.save()

        #expect(try store.importPlayedSongs([played("1")], settings: settings) == 1)
    }

    /// An import is dated when it was found, so the witnessed row wins.
    @Test("a witnessed row survives a merge against an imported one")
    func witnessedRowWinsTheMerge() throws {
        let store = try TracksStore(inMemory: true)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let witnessed = Capture(
            songID: "1", title: "Song 1", artistName: "An Artist", capturedAt: when, deviceID: "mac"
        )
        let imported = Capture(
            songID: "1", songKey: "1", title: "Song 1", artistName: "An Artist",
            kind: .imported, capturedAt: when, deviceID: "phone"
        )
        store.context.insert(imported)
        store.context.insert(witnessed)
        try store.context.save()

        #expect(try store.mergeDuplicateCaptures(policy: DedupePolicy()) == 1)
        let remaining = try store.context.fetch(TracksStore.allCaptures())
        try #require(remaining.count == 1)
        #expect(remaining[0].kind == .radio)
        #expect(remaining[0].capturedByDeviceID == "mac")
    }

    @Test func `yesterday's imports aren't imported again`() throws {
        let store = try TracksStore(inMemory: true)
        let yesterday = [played("2"), played("1")]
        #expect(try store.importPlayedSongs(yesterday, settings: settings, now: .now.addingTimeInterval(-30 * 3600)) == 2)

        // A day later Apple's list still has both, under one new song.
        let today = [played("3"), played("2"), played("1")]
        #expect(try store.importPlayedSongs(today, settings: settings) == 1)
        #expect(try store.context.fetch(TracksStore.allCaptures()).count == 3)
    }

    @Test func `a song played again moves above the anchor and counts`() throws {
        let store = try TracksStore(inMemory: true)
        _ = try store.importPlayedSongs([played("2"), played("1")], settings: settings, now: .now.addingTimeInterval(-30 * 3600))
        #expect(try store.importPlayedSongs([played("1"), played("2")], settings: settings) == 1)
    }
}

/// An imported row is dated when it was found, not when it played, so an import that follows
/// a witnessed play of the same song gets ``DedupePolicy/importWindow`` (a day by default)
/// instead of the ordinary repeat window. The window is still bounded: past it, the import is
/// a second play. The exact 24-hour edge is covered with the import window's other boundary
/// tests; these are about which window applies.
@MainActor
@Suite("Imports and the repeat window")
struct ImportWindowTests {

    /// Found 45 minutes later, as in the first real import: far outside the ordinary
    /// 10-minute window, well inside the day an import gets.
    @Test("an import found within the import window is folded into the witnessed row")
    func foldsWithinTheImportWindow() throws {
        let store = try TracksStore(inMemory: true)
        let heard = Date(timeIntervalSince1970: 1_700_000_000)
        try insertWitnessedAndImported(into: store, heard: heard, foundAfter: 45 * 60)

        let policy = DedupePolicy()
        #expect(45 * 60 > policy.window)
        #expect(45 * 60 < policy.importWindow)
        #expect(try store.mergeDuplicateCaptures(policy: policy) == 1)

        let remaining = try store.context.fetch(TracksStore.allCaptures())
        try #require(remaining.count == 1)
        #expect(remaining[0].kind == .radio)
        #expect(remaining[0].capturedAt == heard)
    }

    /// The same 45-minute pair against a shorter import window, so the merge is shown to
    /// follow the policy's `importWindow` rather than treating every import as the same play.
    @Test("whether an import folds in is decided by the import window", arguments: [
        (importWindow: 60.0 * 60, merges: true),
        (importWindow: 30.0 * 60, merges: false),
    ])
    func importWindowDecides(importWindow: TimeInterval, merges: Bool) throws {
        let store = try TracksStore(inMemory: true)
        let heard = Date(timeIntervalSince1970: 1_700_000_000)
        try insertWitnessedAndImported(into: store, heard: heard, foundAfter: 45 * 60)

        let policy = DedupePolicy(window: 10 * 60, importWindow: importWindow)
        #expect(try store.mergeDuplicateCaptures(policy: policy) == (merges ? 1 : 0))
        #expect(try store.context.fetch(TracksStore.allCaptures()).count == (merges ? 1 : 2))
    }

    @Test("two witnessed plays hours apart are still two plays")
    func keepsWitnessedRepeats() throws {
        let store = try TracksStore(inMemory: true)
        let heard = Date(timeIntervalSince1970: 1_700_000_000)
        store.context.insert(Capture(
            songID: "1", title: "lvl 6", artistName: "Léa Sen", capturedAt: heard, deviceID: "mac"
        ))
        store.context.insert(Capture(
            songID: "1", title: "lvl 6", artistName: "Léa Sen",
            capturedAt: heard.addingTimeInterval(7200), deviceID: "mac"
        ))
        try store.context.save()

        #expect(try store.mergeDuplicateCaptures(policy: DedupePolicy()) == 0)
    }

    /// A play the Mac witnessed, and the same song found in Recently Played `foundAfter`
    /// seconds later under a library id.
    private func insertWitnessedAndImported(
        into store: TracksStore,
        heard: Date,
        foundAfter: TimeInterval
    ) throws {
        store.context.insert(Capture(
            songID: "1", title: "lvl 6", artistName: "Léa Sen", capturedAt: heard, deviceID: "mac"
        ))
        store.context.insert(Capture(
            songID: "i.abc", songKey: "i.abc", title: "lvl 6", artistName: "Léa Sen",
            kind: .imported, capturedAt: heard.addingTimeInterval(foundAfter), deviceID: "phone"
        ))
        try store.context.save()
    }
}

/// Removing a song the user doesn't want kept.
@MainActor
@Suite("Forgetting a song")
struct ForgetSongTests {

    /// Removed when the test finishes.
    private let scratch = ScratchDefaults()

    @Test("every row for that song goes, whatever its source")
    func removesEveryRow() throws {
        let store = try TracksStore(inMemory: true)
        let config = scratch.settings
        store.context.insert(Capture(songID: "1", title: "LION", artistName: "Elevation", deviceID: "this-device"))
        store.context.insert(Capture(
            songID: "i.abc", songKey: "i.abc", title: "LION", artistName: "Elevation",
            kind: .imported, deviceID: "this-device"
        ))
        store.context.insert(Capture(songID: "2", title: "Keep Me", artistName: "Elevation", deviceID: "this-device"))
        try store.context.save()

        #expect(try store.forgetSong(title: "LION", artistName: "Elevation", settings: config) == 2)
        let left = try store.context.fetch(TracksStore.allCaptures())
        #expect(left.map(\.title) == ["Keep Me"])
    }

    /// The song is still in Apple's Recently Played, so the next launch would import it back.
    @Test("a forgotten song is not imported again")
    func staysForgotten() throws {
        let store = try TracksStore(inMemory: true)
        let config = scratch.settings
        store.context.insert(Capture(songID: "1", title: "LION", artistName: "Elevation", deviceID: "this-device"))
        try store.context.save()
        try store.forgetSong(title: "LION", artistName: "Elevation", settings: config)

        #expect(config.hasForgotten(title: "LION", artistName: "Elevation"))
        // The same identity the import filters on.
        let known = config.forgottenSongs
        let offered = [PlayedSong(songID: "i.abc", title: "LION", artistName: "Elevation")]
        #expect(HistoryImport.newSongs(in: offered, known: known).isEmpty)
    }

    /// Forgetting used to block every later play of the song, on every device, for good.
    @Test("a song played again days after it was forgotten is imported")
    func laterPlaysCount() throws {
        let store = try TracksStore(inMemory: true)
        let config = scratch.settings
        let forgotten = Date(timeIntervalSince1970: 1_700_000_000)
        config.noteForgotten(HistoryImport.key(title: "LION", artistName: "Elevation"), at: forgotten)
        let offered = [PlayedSong(songID: "i.abc", title: "LION", artistName: "Elevation")]

        #expect(try store.importPlayedSongs(offered, settings: config, now: forgotten.addingTimeInterval(60 * 60)) == 0)
        config.recentlyPlayedAnchor = []
        #expect(try store.importPlayedSongs(offered, settings: config, now: forgotten.addingTimeInterval(3 * 24 * 60 * 60)) == 1)
    }

    @Test("Last.fm plays from before the song was forgotten stay out, later ones come in")
    func scrobblesAfterForgetting() throws {
        let store = try TracksStore(inMemory: true)
        let config = scratch.settings
        let forgotten = Date(timeIntervalSince1970: 1_700_000_000)
        config.noteForgotten(HistoryImport.key(title: "LION", artistName: "Elevation"), at: forgotten)

        let written = try store.importScrobbles([
            ScrobbledTrack(title: "LION", artistName: "Elevation", playedAt: forgotten.addingTimeInterval(-60)),
            ScrobbledTrack(title: "LION", artistName: "Elevation", playedAt: forgotten.addingTimeInterval(2 * 24 * 60 * 60)),
        ], settings: config)

        #expect(written == 1)
        #expect(try store.context.fetch(TracksStore.allCaptures()).map(\.capturedAt)
            == [forgotten.addingTimeInterval(2 * 24 * 60 * 60)])
    }

    /// Songs forgotten before the date was kept have nothing to measure from.
    @Test("a song forgotten without a date stays forgotten")
    func undatedStaysForgotten() {
        #expect(CaptureSettings.isForgotten("k", playedAt: .distantFuture, forgotten: ["k"], dates: [:]))
        #expect(!CaptureSettings.isForgotten("other", playedAt: .distantPast, forgotten: ["k"], dates: [:]))
    }

    @Test("forgetting a song that was never captured still stops it arriving")
    func forgetsUnseenSongs() throws {
        let store = try TracksStore(inMemory: true)
        let config = scratch.settings
        #expect(try store.forgetSong(title: "LION", artistName: "Elevation", settings: config) == 0)
        #expect(config.hasForgotten(title: "LION", artistName: "Elevation"))
    }
}

/// Apple Music's two kinds of identifier.
@Suite("Catalog and library identifiers")
struct MusicItemIdentityTests {

    /// A catalog request with only library ids got a 400: "No id(s) supplied on the request".
    @Test("a library id is not a catalog id")
    func tellsThemApart() {
        #expect(MusicItemIdentity.isCatalogID("1814555105"))
        #expect(!MusicItemIdentity.isCatalogID("i.aJGY3G9fEGApOQP"))
        #expect(MusicItemIdentity.isLibraryID("i.aJGY3G9fEGApOQP"))
        #expect(!MusicItemIdentity.isLibraryID("1814555105"))
    }

    @Test("an empty id is neither")
    func rejectsEmpty() {
        #expect(!MusicItemIdentity.isCatalogID(""))
        #expect(!MusicItemIdentity.isLibraryID(""))
    }
}
