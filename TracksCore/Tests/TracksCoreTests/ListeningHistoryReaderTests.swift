import Foundation
import SwiftData
import Testing
@testable import TracksCore

/// The reader must end up where a full read of the store would, while reading only what
/// changed.
@MainActor
@Suite("Reading the history in the background")
struct ListeningHistoryReaderTests {
    private let store: TracksStore
    private let reader: ListeningHistoryReader
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        store = try TracksStore(inMemory: true)
        reader = ListeningHistoryReader(container: store.container)
    }

    @discardableResult
    private func insert(_ title: String, at offset: TimeInterval = 0, session: Session? = nil) throws -> Capture {
        let capture = Capture(
            songID: "1",
            title: title,
            artistName: "Artist",
            kind: .onDemand,
            capturedAt: start.addingTimeInterval(offset),
            session: session
        )
        store.context.insert(capture)
        try store.context.save()
        return capture
    }

    private func titles(_ snapshot: ListeningHistoryReader.Snapshot?) throws -> [String] {
        try #require(snapshot).captures.map(\.title).sorted()
    }

    @Test("the first read reads everything")
    func firstReadIsFull() async throws {
        try insert("One")
        try insert("Two", at: 60)

        let snapshot = try await reader.read()

        #expect(try titles(snapshot) == ["One", "Two"])
        #expect(await reader.lastRead == .full)
    }

    @Test("with nothing saved since, a read reports no change")
    func unchanged() async throws {
        try insert("One")
        _ = try await reader.read()

        #expect(try await reader.read() == nil)
        #expect(await reader.lastRead == .unchanged)
    }

    @Test("a new play is picked up without reading everything again")
    func insertIsIncremental() async throws {
        try insert("One")
        _ = try await reader.read()

        try insert("Two", at: 60)
        let snapshot = try await reader.read()

        #expect(try titles(snapshot) == ["One", "Two"])
        #expect(await reader.lastRead == .incremental)
    }

    @Test("a change to a play is picked up")
    func updateIsApplied() async throws {
        let capture = try insert("One")
        _ = try await reader.read()

        capture.artworkURL = "https://example.com/cover.jpg"
        try store.context.save()
        let snapshot = try #require(try await reader.read())

        #expect(snapshot.captures.first?.artworkURL == "https://example.com/cover.jpg")
        #expect(await reader.lastRead == .incremental)
    }

    @Test("a deleted play is dropped")
    func deleteIsApplied() async throws {
        let capture = try insert("One")
        try insert("Two", at: 60)
        _ = try await reader.read()

        try store.deletePlay(capture)
        let snapshot = try await reader.read()

        #expect(try titles(snapshot) == ["Two"])
    }

    @Test("a play joining a session takes its station's name")
    func sessionGivesStationName() async throws {
        _ = try await reader.read()

        let station = Station(name: "Chill", firstSeenAt: start)
        let session = Session(startedAt: start, station: station)
        store.context.insert(station)
        store.context.insert(session)
        try insert("One", session: session)
        let snapshot = try #require(try await reader.read())

        #expect(snapshot.captures.first?.stationName == "Chill")
        #expect(snapshot.sessions.first?.stationName == "Chill")
    }

    /// A merge of two stations, or a rename, changes no capture row, only the station.
    @Test("renaming a station renames it on every play in its sessions")
    func stationRenameReachesPlays() async throws {
        let station = Station(name: "Chill", firstSeenAt: start)
        let session = Session(startedAt: start, station: station)
        store.context.insert(station)
        store.context.insert(session)
        try insert("One", session: session)
        try insert("Two", at: 60, session: session)
        _ = try await reader.read()

        station.name = "Apple Music Chill"
        try store.context.save()
        let snapshot = try #require(try await reader.read())

        #expect(snapshot.captures.allSatisfy { $0.stationName == "Apple Music Chill" })
    }

    @Test("a play leaving its session loses the station name")
    func leavingSessionClearsStation() async throws {
        let station = Station(name: "Chill", firstSeenAt: start)
        let session = Session(startedAt: start, station: station)
        store.context.insert(station)
        store.context.insert(session)
        let capture = try insert("One", session: session)
        _ = try await reader.read()

        capture.session = nil
        try store.context.save()
        let snapshot = try #require(try await reader.read())

        #expect(snapshot.captures.first?.stationName == nil)
    }

    /// Whatever sequence of changes it has folded in, the reader must agree with a reader
    /// that has just read the store from scratch.
    @Test("after a run of changes it matches a fresh read")
    func matchesFreshRead() async throws {
        let station = Station(name: "Chill", firstSeenAt: start)
        let session = Session(startedAt: start, station: station)
        store.context.insert(station)
        store.context.insert(session)
        let first = try insert("One", session: session)
        try insert("Two", at: 60)
        _ = try await reader.read()

        let third = try insert("Three", at: 120, session: session)
        first.playedBackAt = start.addingTimeInterval(3_600)
        try store.context.save()
        _ = try await reader.read()
        try store.deletePlay(third)
        station.name = "Late Chill"
        try insert("Four", at: 180, session: session)
        let incremental = try #require(try await reader.read())

        let fresh = try #require(try await ListeningHistoryReader(container: store.container).read())
        let order = { (lhs: CaptureStat, rhs: CaptureStat) in lhs.title < rhs.title }
        #expect(incremental.captures.sorted(by: order) == fresh.captures.sorted(by: order))
        #expect(incremental.sessions == fresh.sessions)
    }
}
