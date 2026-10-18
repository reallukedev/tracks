import Testing
import Foundation
import SwiftData
@testable import TracksCore

/// Records what was asked of it, and can be told to fail.
final class FakePlaylistWriter: PlaylistWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var _created: [String] = []
    private var _added: [(ids: [String], playlist: String)] = []
    var createResult: Result<String, any Error> = .success("p.fake")
    var addResult: Result<Void, any Error> = .success(())

    var created: [String] { lock.withLock { _created } }
    var added: [(ids: [String], playlist: String)] { lock.withLock { _added } }
    var addedIDs: [String] { added.flatMap(\.ids) }

    func createPlaylist(name: String, description: String?) async throws -> String {
        lock.withLock { _created.append(name) }
        return try createResult.get()
    }

    func addSongs(ids: [String], toPlaylist playlistID: String) async throws {
        lock.withLock { _added.append((ids, playlistID)) }
        try addResult.get()
    }
}

struct FakeCatalogResolver: CatalogResolving {
    let result: CatalogCandidate?
    var artwork: [String: String] = [:]
    var stationName: String?
    /// The search request fails, as it does offline or without a MusicKit developer token.
    var searchFails = false
    func resolve(_ query: CatalogQuery) async throws -> CatalogCandidate? {
        if searchFails { throw URLError(.notConnectedToInternet) }
        return result
    }
    func artworkURLs(forSongIDs ids: [String]) async throws -> [String: String] {
        artwork.filter { ids.contains($0.key) }
    }
    func mostRecentStationName() async throws -> String? { stationName }
}

@MainActor
@Suite("Capture pipeline")
struct CaptureCoordinatorTests {
    let store: TracksStore
    let writer = FakePlaylistWriter()
    /// Removes the defaults suite when the test finishes.
    private let scratch = ScratchDefaults()
    let settings: CaptureSettings

    /// A fresh store and defaults per test, since tests run in parallel.
    init() throws {
        store = try TracksStore(inMemory: true)
        settings = scratch.settings
        // The share that must play has its own suite below.
        settings.minimumListenShare = 0
    }

    func coordinator(resolver: (any CatalogResolving)? = nil) -> CaptureCoordinator {
        CaptureCoordinator(
            store: store,
            settings: settings,
            playlistWriter: writer,
            catalogResolver: resolver
        )
    }

    /// Oldest first, so the order is the same on every run. A fetch with no sort comes back in
    /// whatever order the store likes, which made "the first session" a guess.
    static var sessionsInOrder: FetchDescriptor<Session> {
        FetchDescriptor<Session>(sortBy: [SortDescriptor(\.startedAt)])
    }

    func radio(
        title: String = "Dai Dai",
        artist: String = "Shakira & Burna Boy",
        id: String? = "6768469976"
    ) -> NowPlayingObservation {
        NowPlayingObservation(
            title: title,
            artistName: artist,
            catalogSongID: id,
            duration: 223,
            rawFields: ["entry.id": "PxDIf4ejk::STREAM"]
        )
    }

    @Test("a radio track is stored and added to the playlist")
    func capturesAndWrites() async throws {
        let subject = coordinator()
        let decision = await subject.handle(radio())
        #expect(decision.isCapture)
        await subject.drainPendingWrites()

        let captures = try store.context.fetch(TracksStore.radioCaptures())
        #expect(captures.count == 1)
        #expect(captures.first?.songID == "6768469976")
        #expect(writer.created == ["Heard on Radio"])
        #expect(writer.addedIDs == ["6768469976"])
        #expect(captures.first?.needsPlaylistWrite == false)
    }

    /// `playerInfo` repeats the same track every ~16 seconds.
    @Test("repeated observations of one track produce a single capture")
    func dedupesHeartbeat() async throws {
        let subject = coordinator()
        let start = Date()
        for offset in stride(from: 0, through: 64, by: 16) {
            await subject.handle(radio(), now: start.addingTimeInterval(Double(offset)))
        }
        await subject.drainPendingWrites()

        let captures = try store.context.fetch(TracksStore.radioCaptures())
        #expect(captures.count == 1)
        #expect(writer.addedIDs == ["6768469976"])
    }

    /// Two observations arriving together mustn't both pass the dedupe check.
    @Test("concurrent observations of one track still produce a single capture")
    func concurrentObservationsDeduped() async throws {
        let subject = coordinator()
        async let first = subject.handle(radio())
        async let second = subject.handle(radio())
        _ = await (first, second)

        #expect(try store.context.fetch(TracksStore.radioCaptures()).count == 1)
    }

    @Test("the playlist is created once and reused")
    func createsPlaylistOnce() async throws {
        let subject = coordinator()
        await subject.handle(radio(title: "One", id: "1"))
        await subject.handle(radio(title: "Two", id: "2"))
        await subject.drainPendingWrites()

        #expect(writer.created.count == 1)
        #expect(writer.addedIDs == ["1", "2"])
        #expect(settings.playlistID == "p.fake")
    }

    @Test("an on-demand track is neither stored nor written")
    func ignoresOnDemand() async throws {
        var observation = radio()
        observation.rawFields["entry.id"] = "PRhKeIIy0::6ostOUDHU"
        let subject = coordinator()
        await subject.handle(observation)
        await subject.drainPendingWrites()

        #expect(try store.context.fetch(TracksStore.radioCaptures()).isEmpty)
        #expect(writer.added.isEmpty)
    }

    /// macOS: no catalog id at capture time, so the row is stored first and resolved after.
    @Test("a macOS capture is resolved by catalog search before being written")
    func resolvesCatalogID() async throws {
        let subject = coordinator(
            resolver: FakeCatalogResolver(
                result: CatalogCandidate(
                    id: "9999",
                    title: "Nostalgia",
                    artistName: "Lossapardo",
                    albumTitle: "Nostalgia",
                    artworkURL: "https://example.test/art.jpg"
                )
            )
        )
        let observation = NowPlayingObservation(
            title: "Nostalgia",
            artistName: "Lossapardo",
            albumTitle: "Nostalgia - Single",
            catalogSongID: nil,
            duration: nil,
            playerPosition: 0
        )
        await subject.handle(observation)
        await subject.drainPendingWrites()

        let captures = try store.context.fetch(TracksStore.radioCaptures())
        #expect(captures.first?.songID == "9999")
        #expect(writer.addedIDs == ["9999"])
        // macOS gets no artwork from playerInfo, so the match has to supply it.
        #expect(captures.first?.artworkURL == "https://example.test/art.jpg")
    }

    /// A wrong match would write the wrong song into someone's library.
    @Test("a track the catalog cannot identify is stored but never written")
    func unresolvableIsNotWritten() async throws {
        let subject = coordinator(resolver: FakeCatalogResolver(result: nil))
        let observation = NowPlayingObservation(
            title: "Nostalgia", artistName: "Lossapardo", catalogSongID: nil, playerPosition: 0
        )
        for _ in 0..<maxCatalogLookupAttempts {
            await subject.handle(observation)
            await subject.drainPendingWrites()
        }

        let captures = try store.context.fetch(TracksStore.radioCaptures())
        #expect(captures.count == 1)
        #expect(captures.first?.songID.isEmpty == true)
        #expect(writer.added.isEmpty)
        #expect(captures.first?.needsPlaylistWrite == false)
    }

    /// Seen on a new App ID: every search failed with `developerTokenRequestFailed` until
    /// MusicKit caught up, and the songs from that window never got an id or a cover.
    @Test("a failed search doesn't use up the song's lookup attempts")
    func failedSearchIsRetried() async throws {
        let observation = NowPlayingObservation(
            title: "Nostalgia", artistName: "Lossapardo", catalogSongID: nil, playerPosition: 0
        )
        var failing = FakeCatalogResolver(result: nil)
        failing.searchFails = true
        let offline = coordinator(resolver: failing)
        for _ in 0...maxCatalogLookupAttempts {
            await offline.handle(observation)
            await offline.drainPendingWrites()
        }

        let capture = try #require(try store.context.fetch(TracksStore.radioCaptures()).first)
        #expect(capture.catalogLookupAttempts == 0)
        #expect(capture.needsPlaylistWrite)
        #expect(capture.lastPlaylistWriteError?.hasPrefix("Catalog search failed") == true)

        let working = coordinator(
            resolver: FakeCatalogResolver(
                result: CatalogCandidate(
                    id: "9999",
                    title: "Nostalgia",
                    artistName: "Lossapardo",
                    albumTitle: "Nostalgia",
                    artworkURL: "https://example.test/art.jpg"
                )
            )
        )
        await working.handle(observation)
        await working.drainPendingWrites()
        #expect(capture.songID == "9999")
        #expect(capture.artworkURL == "https://example.test/art.jpg")
        #expect(capture.lastPlaylistWriteError == nil)
    }

    @Test("a transient write failure leaves the capture pending")
    func transientFailureRetries() async throws {
        writer.addResult = .failure(PlaylistWriteError.transient(statusCode: 503, message: ""))
        let subject = coordinator()
        await subject.handle(radio())
        await subject.drainPendingWrites()

        let capture = try #require(try store.context.fetch(TracksStore.radioCaptures()).first)
        #expect(capture.needsPlaylistWrite)
        // An outage isn't the song's fault, so it costs no attempt. See `PlaylistQueueTests`.
        #expect(capture.playlistWriteAttempts == 0)
    }

    /// A request Apple rejects won't succeed on retry, and retrying would stall the queue.
    /// A setup problem, by contrast, keeps the song: see `PlaylistQueueTests`.
    @Test("a permanent write failure stops the capture being retried")
    func permanentFailureStops() async throws {
        writer.addResult = .failure(
            PlaylistWriteError.permanent(statusCode: 400, message: "bad request")
        )
        let subject = coordinator()
        await subject.handle(radio())
        await subject.drainPendingWrites()

        let capture = try #require(try store.context.fetch(TracksStore.radioCaptures()).first)
        #expect(!capture.needsPlaylistWrite)
    }

    /// Artwork used to come only from catalog search, which iOS rows never go through.
    @Test("artwork is backfilled for a row that already has a catalog id")
    func backfillsArtwork() async throws {
        let subject = coordinator(
            resolver: FakeCatalogResolver(
                result: nil,
                artwork: ["6768469976": "https://example.test/cover.jpg"]
            )
        )
        await subject.handle(radio())
        await subject.drainPendingWrites()

        let capture = try #require(try store.context.fetch(TracksStore.radioCaptures()).first)
        #expect(capture.artworkURL == "https://example.test/cover.jpg")
    }

    /// Starting the app mid-station misses the tune-in, which used to leave the session
    /// called "Radio".
    @Test("the station is looked up when no tune-in was witnessed")
    func stationLookedUpWhenNotAnnounced() async throws {
        let subject = coordinator(
            resolver: FakeCatalogResolver(result: nil, stationName: "Apple Música Uno")
        )
        await subject.handle(radio())

        let sessions = try store.context.fetch(Self.sessionsInOrder)
        try #require(sessions.count == 1)
        let session = sessions[0]
        #expect(session.station?.name == "Apple Música Uno")
    }

    @Test("an announced station beats the lookup")
    func announcedStationWins() async throws {
        let subject = coordinator(
            resolver: FakeCatalogResolver(result: nil, stationName: "Something Else")
        )
        await subject.handle(NowPlayingObservation(title: "Apple Music 1", artistName: ""))
        await subject.handle(radio())

        let sessions = try store.context.fetch(Self.sessionsInOrder)
        try #require(sessions.count == 1)
        let session = sessions[0]
        #expect(session.station?.name == "Apple Music 1")
    }

    @Test("turning off auto-add stores the capture without writing it")
    func autoAddOff() async throws {
        settings.autoAddToPlaylist = false
        let subject = coordinator()
        await subject.handle(radio())
        await subject.drainPendingWrites()

        #expect(try store.context.fetch(TracksStore.radioCaptures()).count == 1)
        #expect(writer.added.isEmpty)
    }

    /// Apple Music can't take a song back out of a playlist, so a cap could only fill up and
    /// then stop. Every radio song goes in, however long the playlist has grown.
    @Test("every radio song is added, however long the playlist is")
    func addsWithoutALimit() async throws {
        let subject = coordinator()
        await subject.handle(radio(title: "One", id: "1"))
        await subject.handle(radio(title: "Two", id: "2"))
        await subject.drainPendingWrites()

        #expect(writer.addedIDs == ["1", "2"])
    }

    @Test("a station announcement names the session without being captured")
    func stationAnnouncementNamesSession() async throws {
        let subject = coordinator()
        await subject.handle(NowPlayingObservation(title: "Apple Music 1", artistName: ""))
        await subject.handle(radio())

        #expect(try store.context.fetch(TracksStore.radioCaptures()).count == 1)
        let sessions = try store.context.fetch(Self.sessionsInOrder)
        try #require(sessions.count == 1)
        let session = sessions[0]
        #expect(session.station?.name == "Apple Music 1")
    }
}

/// The share of a song that must play: skipping through songs records nothing, and a song
/// left to play is recorded once.
@MainActor
@Suite("Minimum listening time")
struct MinimumListenTests {
    let store: TracksStore
    /// Removes the defaults suite when the test finishes.
    private let scratch = ScratchDefaults()
    let settings: CaptureSettings
    let writer: FakePlaylistWriter
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws {
        store = try TracksStore(inMemory: true)
        settings = scratch.settings
        // A quarter of these two-minute songs is 30 seconds.
        settings.minimumListenShare = 0.25
        writer = FakePlaylistWriter()
    }

    func coordinator() -> CaptureCoordinator {
        CaptureCoordinator(store: store, settings: settings, playlistWriter: writer)
    }

    func song(_ title: String, duration: TimeInterval? = 120) -> NowPlayingObservation {
        NowPlayingObservation(
            title: title,
            artistName: "An Artist",
            catalogSongID: title,
            duration: duration,
            rawFields: ["entry.id": "x::STREAM"]
        )
    }

    @Test("a song is not captured the moment it starts")
    func waitsBeforeCapturing() async throws {
        let decision = await coordinator().handle(song("Walkin"), now: start)
        guard case .ignore(.tooShort(let played, let needs)) = decision else {
            Issue.record("Expected tooShort, got \(decision)")
            return
        }
        #expect(played == 0)
        #expect(needs == 30)
        #expect(try store.context.fetch(TracksStore.allCaptures()).isEmpty)
    }

    @Test("it is captured once it has played long enough")
    func capturesAfterTheThreshold() async {
        let coordinator = coordinator()
        _ = await coordinator.handle(song("Walkin"), now: start)
        let decision = await coordinator.handle(song("Walkin"), now: start.addingTimeInterval(31))
        #expect(decision.isCapture)
    }

    @Test("skipping through songs records none of them")
    func skippingRecordsNothing() async throws {
        let coordinator = coordinator()
        for (index, title) in ["One", "Two", "Three", "Four"].enumerated() {
            let decision = await coordinator.handle(
                song(title), now: start.addingTimeInterval(Double(index) * 5)
            )
            #expect(!decision.isCapture, "\(title) should not have been captured")
        }
        #expect(try store.context.fetch(TracksStore.allCaptures()).isEmpty)
    }

    @Test("the clock restarts when the song changes")
    func clockRestartsPerSong() async {
        let coordinator = coordinator()
        _ = await coordinator.handle(song("One"), now: start)
        // Long enough for "One", but "Two" has only just arrived.
        let decision = await coordinator.handle(song("Two"), now: start.addingTimeInterval(40))
        guard case .ignore(.tooShort(let played, _)) = decision else {
            Issue.record("Expected tooShort, got \(decision)")
            return
        }
        #expect(played == 0)
    }

    /// The user asked for it explicitly.
    @Test("forcing skips the wait")
    func forceBypassesTheThreshold() async {
        let decision = await coordinator().handle(song("Walkin"), now: start, force: true)
        #expect(decision.isCapture)
    }

    @Test("zero means capture straight away")
    func zeroDisablesTheWait() async {
        settings.minimumListenShare = 0
        let decision = await coordinator().handle(song("Walkin"), now: start)
        #expect(decision.isCapture)
    }

    @Test("a longer song has to play for longer", arguments: [(120.0, 30.0), (240.0, 60.0), (600.0, 150.0)])
    func waitFollowsTheSongsLength(duration: TimeInterval, needed: TimeInterval) async {
        let decision = await coordinator().handle(song("Walkin", duration: duration), now: start)
        guard case .ignore(.tooShort(_, let needs)) = decision else {
            Issue.record("Expected tooShort, got \(decision)")
            return
        }
        #expect(needs == needed)
    }

    /// A live stream can report no length, or zero.
    @Test("a song of unknown length is taken as four minutes long", arguments: [nil, 0.0])
    func unknownLength(duration: TimeInterval?) async {
        let decision = await coordinator().handle(song("Walkin", duration: duration), now: start)
        guard case .ignore(.tooShort(_, let needs)) = decision else {
            Issue.record("Expected tooShort, got \(decision)")
            return
        }
        #expect(needs == 60)
    }

    /// The caller schedules its re-check from the remaining time.
    @Test("the reported wait counts down")
    func reportsTimeRemaining() async {
        let coordinator = coordinator()
        _ = await coordinator.handle(song("Walkin"), now: start)
        let decision = await coordinator.handle(song("Walkin"), now: start.addingTimeInterval(20))
        guard case .ignore(.tooShort(let played, let needs)) = decision else {
            Issue.record("Expected tooShort, got \(decision)")
            return
        }
        #expect(played == 20)
        #expect(needs - played == 10)
    }
}

/// A catalog that counts its searches and can be slow to answer them, as it is on a poor
/// connection.
final class SlowCatalogResolver: CatalogResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var _searches = 0
    private var _answered = 0
    let delay: Duration

    init(delay: Duration = .zero) {
        self.delay = delay
    }

    var searches: Int { lock.withLock { _searches } }
    var answered: Int { lock.withLock { _answered } }

    func resolve(_ query: CatalogQuery) async throws -> CatalogCandidate? {
        lock.withLock { _searches += 1 }
        if delay > .zero { try? await Task.sleep(for: delay) }
        lock.withLock { _answered += 1 }
        return nil
    }
    func artworkURLs(forSongIDs ids: [String]) async throws -> [String: String] { [:] }
    func mostRecentStationName() async throws -> String? { nil }
}

/// Capture can't wait on the catalog: an observation that sits behind a slow search starts
/// its listening clock late, and the song after it can be missed.
@MainActor
@Suite("Capture and the write queue")
struct CaptureDrainTests {
    let store: TracksStore
    let writer = FakePlaylistWriter()
    private let scratch = ScratchDefaults()
    let settings: CaptureSettings

    init() throws {
        store = try TracksStore(inMemory: true)
        settings = scratch.settings
        settings.minimumListenShare = 0
    }

    func unresolved(_ title: String) -> NowPlayingObservation {
        NowPlayingObservation(title: title, artistName: "Lossapardo", catalogSongID: nil, playerPosition: 0)
    }

    @Test("an observation is handled without waiting for the catalog")
    func handleDoesNotWaitForTheDrain() async throws {
        let resolver = SlowCatalogResolver(delay: .milliseconds(300))
        let subject = CaptureCoordinator(store: store, settings: settings, playlistWriter: writer, catalogResolver: resolver)

        let first = await subject.handle(unresolved("Nostalgia"))
        let second = await subject.handle(unresolved("Afterglow"))

        #expect(first.isCapture)
        #expect(second.isCapture)
        #expect(resolver.answered == 0)
        // The drain still runs, and picks up both rows.
        await subject.drainPendingWrites()
        let captures = try store.context.fetch(TracksStore.allCaptures())
        #expect(captures.count == 2)
        #expect(captures.allSatisfy { $0.catalogLookupAttempts > 0 })
    }

    /// A Mac that was offline for a day has a backlog, and one drain searching for all of it
    /// held the playlist writes behind it for minutes.
    @Test("a drain searches the catalog for one batch of a backlog")
    func backlogIsSearchedInBatches() async throws {
        let resolver = SlowCatalogResolver()
        let subject = CaptureCoordinator(store: store, settings: settings, playlistWriter: writer, catalogResolver: resolver)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<(TracksStore.catalogSearchBatch * 2 + 5) {
            _ = try store.insertCapture(
                songKey: "song \(index)",
                catalogSongID: nil,
                observation: unresolved("Song \(index)"),
                session: nil,
                now: start.addingTimeInterval(Double(index))
            )
        }

        await subject.drainPendingWrites()
        #expect(resolver.searches == TracksStore.catalogSearchBatch)
    }
}

/// Last.fm counts a play once a track longer than 30 seconds has played for half its length
/// or four minutes. With "Straight Away", a song is kept the moment it starts, so whether it
/// is owed to Last.fm has to wait for that.
@MainActor
@Suite("Scrobbling follows Last.fm's rule")
struct ScrobbleRuleTests {
    let store: TracksStore
    private let scratch = ScratchDefaults()
    let settings: CaptureSettings
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws {
        store = try TracksStore(inMemory: true)
        settings = scratch.settings
        settings.minimumListenShare = 0
        settings.autoAddToPlaylist = false
    }

    func coordinator() -> CaptureCoordinator {
        CaptureCoordinator(store: store, settings: settings, playlistWriter: FakePlaylistWriter())
    }

    func song(_ title: String, duration: TimeInterval? = 180, state: PlaybackState = .playing) -> NowPlayingObservation {
        NowPlayingObservation(
            title: title,
            artistName: "An Artist",
            catalogSongID: title,
            duration: duration,
            playbackState: state,
            rawFields: ["entry.id": "x::STREAM"]
        )
    }

    func owed() throws -> [String] {
        try store.context.fetch(TracksStore.pendingScrobbles(includingImported: true)).map(\.title)
    }

    func handle(_ subject: CaptureCoordinator, _ observation: NowPlayingObservation, after seconds: TimeInterval) async {
        await subject.handle(observation, now: start.addingTimeInterval(seconds))
    }

    @Test("a song skipped after a few seconds is kept but not scrobbled")
    func skipIsNotScrobbled() async throws {
        let subject = coordinator()
        await handle(subject, song("Skipped"), after: 0)
        await handle(subject, song("Next"), after: 20)

        #expect(try store.context.fetch(TracksStore.allCaptures()).count == 2)
        #expect(try owed() == [])
    }

    @Test("a song still playing at half its length is scrobbled")
    func halfwayIsScrobbled() async throws {
        let subject = coordinator()
        await handle(subject, song("Kept"), after: 0)
        #expect(try owed().isEmpty)
        await handle(subject, song("Kept"), after: 95)
        #expect(try owed() == ["Kept"])
    }

    /// iPhone only hears about a song when the next one starts.
    @Test("a song that played until the next one started is scrobbled")
    func playedUntilTheNextSong() async throws {
        let subject = coordinator()
        await handle(subject, song("Kept"), after: 0)
        await handle(subject, song("Next"), after: 120)
        #expect(try owed() == ["Kept"])
    }

    @Test("four minutes is enough for a long song")
    func fourMinutesOfALongSong() async throws {
        let subject = coordinator()
        await handle(subject, song("Epic", duration: 1_200), after: 0)
        await handle(subject, song("Epic", duration: 1_200), after: 241)
        #expect(try owed() == ["Epic"])
    }

    @Test("a track of 30 seconds or less is never scrobbled")
    func shortTrackIsNeverScrobbled() async throws {
        let subject = coordinator()
        await handle(subject, song("Jingle", duration: 25), after: 0)
        await handle(subject, song("Next"), after: 26)
        #expect(try owed() == [])
    }

    @Test("time paused doesn't count as listening")
    func pausesDontCount() async throws {
        let subject = coordinator()
        await handle(subject, song("Paused"), after: 0)
        await handle(subject, song("Paused", state: .paused), after: 30)
        await handle(subject, song("Next"), after: 3_600)
        #expect(try owed() == [])
    }

    /// With the default share a song is only kept at half, which is already enough.
    @Test("a song kept at half its length is owed at once")
    func keptAtHalfIsOwed() async throws {
        settings.minimumListenShare = CaptureSettings.defaultMinimumListenShare
        let subject = coordinator()
        await handle(subject, song("Kept"), after: 0)
        await handle(subject, song("Kept"), after: 91)
        #expect(try owed() == ["Kept"])
    }

    /// The watch is only in memory. When iOS ended Tracks while Music kept playing, the song
    /// stayed held for good.
    @Test("a held song still playing after a relaunch is scrobbled")
    func heldSongSurvivesRelaunch() async throws {
        await handle(coordinator(), song("Kept"), after: 0)
        #expect(try owed().isEmpty)

        await handle(coordinator(), song("Kept"), after: 100)
        #expect(try owed() == ["Kept"])
    }

    @Test("a held song isn't released after a relaunch when something else is playing")
    func relaunchOnAnotherSong() async throws {
        await handle(coordinator(), song("Kept"), after: 0)
        await handle(coordinator(), song("Next"), after: 100)
        #expect(try owed().isEmpty)
    }

    /// More time than the song lasts means it didn't just keep playing.
    @Test("a held song heard again long after isn't released by the relaunch")
    func relaunchLongAfter() async throws {
        await handle(coordinator(), song("Kept"), after: 0)
        await handle(coordinator(), song("Kept"), after: 600)
        #expect(try owed().isEmpty)
    }
}
