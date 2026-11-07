import Testing
import Foundation
import SwiftData
@testable import TracksCore

/// The playlist queue under failure and overlap: what a failed write costs a song, and that
/// two drains never write one song twice.
@MainActor
@Suite("Playlist queue", .timeLimit(.minutes(1)))
struct PlaylistQueueTests {
    let store: TracksStore
    let writer = ScriptedPlaylistWriter()
    private let scratch = ScratchDefaults()
    let settings: CaptureSettings
    let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))

    init() throws {
        store = try TracksStore(inMemory: true)
        settings = scratch.settings
        settings.minimumListenShare = 0
    }

    func coordinator(resolver: (any CatalogResolving)? = nil) -> CaptureCoordinator {
        let coordinator = CaptureCoordinator(
            store: store,
            settings: settings,
            playlistWriter: writer,
            catalogResolver: resolver
        )
        let clock = clock
        coordinator.now = { clock.now }
        return coordinator
    }

    /// Radio rows owed a write, oldest first.
    @discardableResult
    func owed(_ songIDs: String...) throws -> [Capture] {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = songIDs.enumerated().map { index, id in
            Capture(
                songID: id,
                title: "Song \(id)",
                artistName: "Artist",
                artworkURL: "https://example.test/\(id).jpg",
                capturedAt: base.addingTimeInterval(Double(index) * 60),
                deviceID: DeviceIdentity.current
            )
        }
        for row in rows { store.context.insert(row) }
        try store.context.save()
        return rows
    }

    /// An outage used to cost every row an attempt on every drain, and five drains lost them.
    @Test("an outage costs no attempts and stops after the second failure")
    func outageCostsNothing() async throws {
        let rows = try owed("1", "2", "3")
        writer.failAll(with: PlaylistWriteError.transient(statusCode: 503, message: "down"))

        await coordinator().drainPendingWrites()

        #expect(writer.attempted == ["1", "2"])
        #expect(rows.allSatisfy { $0.needsPlaylistWrite && $0.playlistWriteAttempts == 0 })
    }

    @Test("a network error is treated as an outage")
    func networkErrorIsAnOutage() async throws {
        let rows = try owed("1", "2")
        writer.failAll(with: URLError(.notConnectedToInternet))

        await coordinator().drainPendingWrites()

        #expect(rows.allSatisfy { $0.needsPlaylistWrite && $0.playlistWriteAttempts == 0 })
    }

    @Test("after an outage the queue waits before writing again")
    func backsOff() async throws {
        let rows = try owed("1", "2")
        writer.failAll(with: PlaylistWriteError.transient(statusCode: 503, message: "down"))
        let subject = coordinator()

        await subject.drainPendingWrites()
        await subject.drainPendingWrites()
        #expect(writer.attempted.count == 2)

        writer.succeed()
        clock.advance(by: 31)
        await subject.drainPendingWrites()
        #expect(writer.written == ["1", "2"])
        #expect(rows.allSatisfy { !$0.needsPlaylistWrite && $0.addedToPlaylistAt != nil })
    }

    /// Stopping at the first transient failure mustn't let one song Apple always chokes on
    /// hold up the whole queue for good.
    @Test("a transient failure is charged to its song when the next write goes through")
    func poisonSongIsCharged() async throws {
        let rows = try owed("bad", "good")
        writer.fail("bad", with: PlaylistWriteError.transient(statusCode: 500, message: "oops"))

        await coordinator().drainPendingWrites()

        #expect(rows[0].playlistWriteAttempts == 1)
        #expect(rows[0].needsPlaylistWrite)
        #expect(rows[1].addedToPlaylistAt != nil)
    }

    /// A token MusicKit can't issue fails every write, and used to clear each song's write on
    /// its first try, so they never reached the playlist once it was fixed.
    @Test("a setup failure keeps the song owed and stops the queue")
    func setupFailureKeepsTheSong() async throws {
        let rows = try owed("1", "2")
        writer.failAll(with: PlaylistWriteError.notConfigured(reason: "no token", guidance: "Enable MusicKit."))

        await coordinator().drainPendingWrites()

        #expect(writer.attempted == ["1"])
        #expect(rows.allSatisfy { $0.needsPlaylistWrite && $0.playlistWriteAttempts == 0 })
        #expect(rows[0].lastPlaylistWriteError != nil)
    }

    /// A deleted playlist answers 404, which reads as the song's fault, so every pending song
    /// was charged and dropped one after another.
    @Test("a deleted playlist is made again, and no song is dropped for it")
    func deletedPlaylistIsRecreated() async throws {
        let rows = try owed("1", "2", "3")
        settings.playlistID = "p.gone"
        writer.delete("p.gone")
        let subject = coordinator()

        await subject.drainPendingWrites()

        #expect(writer.attempted == ["1"])
        #expect(settings.playlistID == nil)
        #expect(rows.allSatisfy { $0.needsPlaylistWrite && $0.playlistWriteAttempts == 0 })

        await subject.drainPendingWrites()

        #expect(settings.playlistID == "p.fake")
        #expect(writer.written == ["1", "2", "3"])
        #expect(rows.allSatisfy { !$0.needsPlaylistWrite })
    }

    @Test("a 404 for a song in a playlist that still exists is the song's fault")
    func notFoundSongIsCharged() async throws {
        let rows = try owed("bad", "good")
        writer.fail("bad", with: PlaylistWriteError.permanent(statusCode: 404, message: "no such song"))

        await coordinator().drainPendingWrites()

        #expect(rows[0].playlistWriteAttempts == 1)
        #expect(!rows[0].needsPlaylistWrite)
        #expect(rows[1].addedToPlaylistAt != nil)
        #expect(writer.created == 1)
    }

    @Test("failures are blamed on the song only when the request itself was wrong")
    func blame() {
        #expect(CaptureCoordinator.blame(for: PlaylistWriteError.permanent(statusCode: 400, message: "")) == .song)
        #expect(CaptureCoordinator.blame(for: PlaylistWriteError.transient(statusCode: 503, message: "")) == .service)
        #expect(CaptureCoordinator.blame(for: URLError(.timedOut)) == .service)
        #expect(CaptureCoordinator.blame(for: PlaylistWriteError.notSubscribed) == .setup)
    }

    /// Launch, the notification pump, the poll and the timer all drain, and used to overlap
    /// while one waited on Apple, adding songs twice.
    @Test("overlapping drains write each song once")
    func drainsDontOverlap() async throws {
        try owed("1", "2")
        writer.delay = .milliseconds(30)
        let subject = coordinator()

        async let first: Void = subject.drainPendingWrites()
        async let second: Void = subject.drainPendingWrites()
        async let third: Void = subject.drainPendingWrites()
        _ = await (first, second, third)

        #expect(writer.written == ["1", "2"])
    }

    @Test("a capture made while a drain is out is written by the drain that was joined")
    func joinedDrainPicksUpNewRows() async throws {
        try owed("1")
        let gate = Gate()
        writer.gate = gate
        let subject = coordinator()

        let first = Task { await subject.drainPendingWrites() }
        try await waitUntil { writer.attempted.count == 1 }
        let late = try owed("2")[0]

        async let joined: Void = subject.drainPendingWrites()
        gate.open()
        _ = await (first.value, joined)

        #expect(writer.written == ["1", "2"])
        #expect(late.addedToPlaylistAt != nil)
    }

    /// A new device drained before iCloud brought the playlist's ID down, and made a second
    /// "Heard on Radio" that then won on every device.
    @Test("a playlist already in the library by that name is adopted, not made again")
    func adoptsExistingPlaylist() async throws {
        try owed("1")
        writer.existing = [settings.playlistName: "p.original"]

        await coordinator().drainPendingWrites()

        #expect(writer.created == 0)
        #expect(settings.playlistID == "p.original")
        #expect(writer.written == ["1"])
    }

    @Test("a failed create waits before trying again")
    func failedCreateBacksOff() async throws {
        try owed("1")
        writer.createFails = true
        let subject = coordinator()

        await subject.drainPendingWrites()
        await subject.drainPendingWrites()
        #expect(writer.created == 1)

        writer.createFails = false
        clock.advance(by: 31)
        await subject.drainPendingWrites()
        #expect(writer.written == ["1"])
    }

    /// Offline, or without a developer token, the Mac searched the catalog on every
    /// ten-second poll for as long as it stayed that way.
    @Test("a failed catalog search waits before searching again")
    func failedSearchBacksOff() async throws {
        let row = Capture(songID: "", songKey: "k", title: "Nostalgia", artistName: "Lossapardo", deviceID: DeviceIdentity.current)
        store.context.insert(row)
        try store.context.save()
        let resolver = FailingResolver()
        let subject = coordinator(resolver: resolver)

        await subject.drainPendingWrites()
        await subject.drainPendingWrites()
        #expect(resolver.searches == 1)

        clock.advance(by: 31)
        await subject.drainPendingWrites()
        #expect(resolver.searches == 2)
    }

    /// Sync can merge a row away while its write is out. Writing to the deleted row trapped.
    @Test("a row deleted while its write is out is left alone, and the next row still goes in")
    func deletedWhileOut() async throws {
        let rows = try owed("1", "2", "3")
        let gate = Gate()
        writer.gate = gate
        let subject = coordinator()

        let drain = Task { await subject.drainPendingWrites() }
        try await waitUntil { writer.attempted.count == 1 }
        // The one being written, and one still waiting its turn.
        store.context.delete(rows[0])
        store.context.delete(rows[1])
        try store.context.save()
        gate.open()
        await drain.value

        #expect(writer.written == ["1", "3"])
        #expect(rows[2].addedToPlaylistAt != nil)
    }
}

/// The artwork backfill getting past songs the catalog has no cover for.
@MainActor
@Suite("Artwork backfill")
struct ArtworkBackfillTests {
    let store: TracksStore
    private let scratch = ScratchDefaults()
    let settings: CaptureSettings

    init() throws {
        store = try TracksStore(inMemory: true)
        settings = scratch.settings
        settings.autoAddToPlaylist = false
    }

    func coordinator(_ resolver: CountingArtworkResolver) -> CaptureCoordinator {
        CaptureCoordinator(
            store: store,
            settings: settings,
            playlistWriter: ScriptedPlaylistWriter(),
            catalogResolver: resolver
        )
    }

    /// Rows with ids and no cover, `newest` of them newer than `oldest`.
    func rows(newest: Int, oldest: Int) throws -> (newer: [Capture], older: [Capture]) {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let older = (0..<oldest).map { index in
            Capture(songID: "old\(index)", title: "Old \(index)", artistName: "A", kind: .onDemand,
                    capturedAt: base.addingTimeInterval(Double(index)))
        }
        let newer = (0..<newest).map { index in
            Capture(songID: "new\(index)", title: "New \(index)", artistName: "A", kind: .onDemand,
                    capturedAt: base.addingTimeInterval(10_000 + Double(index)))
        }
        for row in older + newer { store.context.insert(row) }
        try store.context.save()
        return (newer, older)
    }

    /// Fifty covers the catalog doesn't have used to sit at the top of the query for good.
    @Test("songs with no cover are set aside, so older rows are reached")
    func movesPastMisses() async throws {
        let (_, older) = try rows(newest: 50, oldest: 5)
        let resolver = CountingArtworkResolver(covers: Dictionary(
            uniqueKeysWithValues: older.map { ($0.songID, "https://example.test/\($0.songID).jpg") }
        ))
        let subject = coordinator(resolver)

        await subject.drainPendingWrites()
        await subject.drainPendingWrites()

        #expect(older.allSatisfy { $0.artworkURL != nil })
        #expect(settings.artworkMisses.count == 50)

        // And the misses aren't asked about again.
        let asked = resolver.askedAbout.count
        await subject.drainPendingWrites()
        #expect(resolver.askedAbout.count == asked)
    }

    @Test("a song set aside is asked about again once its wait is over")
    func missesExpire() async throws {
        let (newer, _) = try rows(newest: 1, oldest: 0)
        let resolver = CountingArtworkResolver(covers: [:])
        let subject = coordinator(resolver)
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        subject.now = { clock.now }

        await subject.drainPendingWrites()
        #expect(resolver.askedAbout == [["new0"]])

        resolver.covers = ["new0": "https://example.test/new0.jpg"]
        clock.advance(by: CaptureCoordinator.artworkMissRetryAfter + 1)
        await subject.drainPendingWrites()
        #expect(newer[0].artworkURL != nil)
    }

    /// It used to stop at the first pass that found nothing.
    @Test("the full backfill pages past songs with no cover to the end")
    func fullBackfillReachesTheEnd() async throws {
        let (_, older) = try rows(newest: 120, oldest: 30)
        let resolver = CountingArtworkResolver(covers: Dictionary(
            uniqueKeysWithValues: older.map { ($0.songID, "https://example.test/\($0.songID).jpg") }
        ))

        let found = await coordinator(resolver).backfillAllArtwork()

        #expect(found == 30)
        #expect(older.allSatisfy { $0.artworkURL != nil })
    }

    /// Repair is asked for, so it tries the songs given up on too.
    @Test("the full backfill asks again about songs set aside")
    func fullBackfillRetriesMisses() async throws {
        let (newer, _) = try rows(newest: 1, oldest: 0)
        let resolver = CountingArtworkResolver(covers: [:])
        let subject = coordinator(resolver)
        await subject.drainPendingWrites()

        resolver.covers = ["new0": "https://example.test/new0.jpg"]
        #expect(await subject.backfillAllArtwork() == 1)
        #expect(newer[0].artworkURL != nil)
    }
}

// MARK: - Fakes

/// A playlist writer that can fail particular songs, hold writes, or slow them down.
final class ScriptedPlaylistWriter: PlaylistWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var _attempted: [String] = []
    private var _written: [String] = []
    private var failures: [String: any Error] = [:]
    private var failure: (any Error)?
    private var _gate: Gate?
    private var _delay: Duration?

    /// Every song a write was tried for, in order.
    var attempted: [String] { lock.withLock { _attempted } }
    /// The songs that went in.
    var written: [String] { lock.withLock { _written } }
    var gate: Gate? {
        get { lock.withLock { _gate } }
        set { lock.withLock { _gate = newValue } }
    }
    var delay: Duration? {
        get { lock.withLock { _delay } }
        set { lock.withLock { _delay = newValue } }
    }

    func failAll(with error: any Error) { lock.withLock { failure = error } }
    func fail(_ songID: String, with error: any Error) { lock.withLock { failures[songID] = error } }
    func succeed() { lock.withLock { failure = nil; failures = [:] } }

    private var _created = 0
    private var _deleted: Set<String> = []
    private var _existing: [String: String] = [:]
    private var _createFails = false

    /// Playlists already in the library, by name.
    var existing: [String: String] {
        get { lock.withLock { _existing } }
        set { lock.withLock { _existing = newValue } }
    }
    var createFails: Bool {
        get { lock.withLock { _createFails } }
        set { lock.withLock { _createFails = newValue } }
    }

    func existingPlaylist(named name: String) async throws -> String? {
        lock.withLock { _existing[name] }
    }

    /// How many playlists were created.
    var created: Int { lock.withLock { _created } }
    /// Removes a playlist, as the user deleting it in Music would.
    func delete(_ playlistID: String) { lock.withLock { _ = _deleted.insert(playlistID) } }

    func createPlaylist(name: String, description: String?) async throws -> String {
        try lock.withLock {
            _created += 1
            if _createFails { throw URLError(.timedOut) }
            return _created == 1 ? "p.fake" : "p.fake\(_created)"
        }
    }

    func playlistExists(_ playlistID: String) async throws -> Bool {
        lock.withLock { !_deleted.contains(playlistID) }
    }

    func addSongs(ids: [String], toPlaylist playlistID: String) async throws {
        let (gate, delay) = lock.withLock {
            _attempted.append(contentsOf: ids)
            return (_gate, _delay)
        }
        if let delay { try? await Task.sleep(for: delay) }
        await gate?.wait()
        if lock.withLock({ _deleted.contains(playlistID) }) {
            throw PlaylistWriteError.permanent(statusCode: 404, message: "no such playlist")
        }
        let error = lock.withLock { failure ?? ids.lazy.compactMap { self.failures[$0] }.first }
        if let error { throw error }
        lock.withLock { _written.append(contentsOf: ids) }
    }
}

/// Answers artwork from a table and remembers what it was asked.
final class CountingArtworkResolver: CatalogResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var _covers: [String: String]
    private var _askedAbout: [[String]] = []

    init(covers: [String: String]) { _covers = covers }

    var covers: [String: String] {
        get { lock.withLock { _covers } }
        set { lock.withLock { _covers = newValue } }
    }
    /// The song IDs of each request, sorted.
    var askedAbout: [[String]] { lock.withLock { _askedAbout } }

    func resolve(_ query: CatalogQuery) async throws -> CatalogCandidate? { nil }

    func artworkURLs(forSongIDs ids: [String]) async throws -> [String: String] {
        lock.withLock {
            _askedAbout.append(ids.sorted())
            return _covers.filter { ids.contains($0.key) }
        }
    }

    func mostRecentStationName() async throws -> String? { nil }
}

/// A catalog that can't be reached, counting how often it was asked.
final class FailingResolver: CatalogResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var _searches = 0
    var searches: Int { lock.withLock { _searches } }

    func resolve(_ query: CatalogQuery) async throws -> CatalogCandidate? {
        lock.withLock { _searches += 1 }
        throw URLError(.notConnectedToInternet)
    }
    func artworkURLs(forSongIDs ids: [String]) async throws -> [String: String] { [:] }
    func mostRecentStationName() async throws -> String? { nil }
}
