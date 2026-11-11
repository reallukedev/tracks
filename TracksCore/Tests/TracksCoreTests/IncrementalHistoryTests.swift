import Foundation
import SwiftData
import Testing
@testable import TracksCore

/// The history is brought up to date one song at a time, from the reader's steps, rather than
/// sorted and worked out again from every play after each one. Whatever the steps, it must end
/// up exactly where a rebuild from every play would.
@MainActor
@Suite("Keeping the history up to date a step at a time")
struct IncrementalHistoryTests {
    private let store: TracksStore
    private let reader: ListeningHistoryReader
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    /// Apple Music's artists for a collaboration, so crediting is part of every step.
    private let metadata = [
        HistoryImport.key(title: "Duet", artistName: "Ana & Ben"): SongMetadata(genre: "Pop", releaseYear: 2020, artists: ["Ana", "Ben"]),
    ]

    init() throws {
        store = try TracksStore(inMemory: true)
        reader = ListeningHistoryReader(container: store.container)
    }

    @discardableResult
    private func play(
        _ title: String,
        by artist: String = "Ana",
        at minutes: Double,
        kind: CaptureKind = .onDemand,
        source: PlaySource = .appleMusic,
        session: Session? = nil
    ) throws -> Capture {
        let capture = Capture(
            songID: "",
            title: title,
            artistName: artist,
            kind: kind,
            capturedAt: start.addingTimeInterval(minutes * 60),
            source: source,
            session: session
        )
        store.context.insert(capture)
        try store.context.save()
        return capture
    }

    /// What's held, brought up to date as the app does it: by the steps where it can, else
    /// from everything. Returns whether the steps were enough.
    @discardableResult
    private func catchUp(_ held: inout ListeningHistory, version: inout Int?) async throws -> Bool {
        let (change, reached) = try #require(try await reader.changes(after: version))
        version = reached
        if case .steps(let steps, _) = change, let next = held.applying(steps) {
            held = next
            return true
        }
        let snapshot = try #require(try await reader.snapshot(after: nil)).snapshot
        held = ListeningHistory(snapshot.captures, songMetadata: metadata)
        return false
    }

    private func expectMatchesRebuild(_ held: ListeningHistory) async throws {
        let snapshot = try #require(try await ListeningHistoryReader(container: store.container).read())
        let rebuilt = ListeningHistory(snapshot.captures, songMetadata: metadata)
        #expect(held.captures == rebuilt.captures)
        #expect(held.seconds == rebuilt.seconds)
        #expect(held.isFirstHearing == rebuilt.isFirstHearing)
        #expect(held.newArtists == rebuilt.newArtists)
        #expect(held.hasYourMusic == rebuilt.hasYourMusic)
        #expect(held.heardSongs == rebuilt.heardSongs)
        #expect(held.heardArtists == rebuilt.heardArtists)
    }

    @Test("songs played one after another are added, and match a rebuild")
    func appends() async throws {
        let station = Station(name: "Chill", firstSeenAt: start)
        let session = Session(startedAt: start, station: station)
        store.context.insert(station)
        store.context.insert(session)
        try play("One", at: 0, kind: .radio, session: session)
        // An import, whose time means nothing, between two plays that measure each other.
        try play("Found", at: 1, kind: .imported)

        var version: Int?
        var held = ListeningHistory([], songMetadata: metadata)
        try await catchUp(&held, version: &version)

        // A song heard before, a new artist, a collaboration and one from Your Music.
        try play("Two", at: 4, kind: .radio, session: session)
        #expect(try await catchUp(&held, version: &version))
        try play("One", at: 8)
        try play("Duet", by: "Ana & Ben", at: 12)
        #expect(try await catchUp(&held, version: &version))
        try play("Mine", by: "Cleo", at: 20, source: .yourMusic)
        #expect(try await catchUp(&held, version: &version))

        try await expectMatchesRebuild(held)
        #expect(held.captures.last?.title == "Mine")
    }

    @Test("a cover found, an album filled in or a station renamed changes plays in place")
    func changesInPlace() async throws {
        let station = Station(name: "Chill", firstSeenAt: start)
        let session = Session(startedAt: start, station: station)
        store.context.insert(station)
        store.context.insert(session)
        let first = try play("One", at: 0, kind: .radio, session: session)
        try play("Duet", by: "Ana & Ben", at: 3)

        var version: Int?
        var held = ListeningHistory([], songMetadata: metadata)
        try await catchUp(&held, version: &version)

        first.artworkURL = "https://example.com/cover.jpg"
        first.albumTitle = "First Album"
        first.songID = "123"
        try store.context.save()
        #expect(try await catchUp(&held, version: &version))

        station.name = "Late Chill"
        try store.context.save()
        #expect(try await catchUp(&held, version: &version))

        try await expectMatchesRebuild(held)
        #expect(held.captures.first?.stationName == "Late Chill")
    }

    @Test("a play from before the last one, synced in late, means a rebuild")
    func latePlay() async throws {
        try play("One", at: 0)
        try play("Two", at: 10)
        var version: Int?
        var held = ListeningHistory([], songMetadata: metadata)
        try await catchUp(&held, version: &version)

        try play("From the iPhone", at: 5)
        #expect(try await catchUp(&held, version: &version) == false)
        try await expectMatchesRebuild(held)
    }

    @Test("a deleted play means a rebuild")
    func deletion() async throws {
        let doomed = try play("One", at: 0)
        try play("Two", at: 10)
        var version: Int?
        var held = ListeningHistory([], songMetadata: metadata)
        try await catchUp(&held, version: &version)

        try store.deletePlay(doomed)
        let (change, _) = try #require(try await reader.changes(after: version))
        guard case .everything = change else {
            Issue.record("A deletion was offered as steps")
            return
        }
    }

    @Test("a caller several versions behind gets every step since")
    func severalBehind() async throws {
        try play("One", at: 0)
        var version: Int?
        var held = ListeningHistory([], songMetadata: metadata)
        try await catchUp(&held, version: &version)

        // Read by someone else in between, as the merge does.
        try play("Two", at: 4)
        _ = try await reader.duplicatePlayGroups(policy: DedupePolicy())
        try play("Three", at: 8)
        _ = try await reader.duplicatePlayGroups(policy: DedupePolicy())
        try play("Two", at: 12)

        #expect(try await catchUp(&held, version: &version))
        try await expectMatchesRebuild(held)
        #expect(held.captures.map(\.title) == ["One", "Two", "Three", "Two"])
    }
}
