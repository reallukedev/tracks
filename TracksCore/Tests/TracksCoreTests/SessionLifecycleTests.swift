import Testing
import Foundation
import SwiftData
@testable import TracksCore

/// Sessions used to close only when a new one started, so the last one stayed open forever
/// after the music stopped.
@MainActor
@Suite("Session lifecycle")
struct SessionLifecycleTests {
    let store: TracksStore
    let policy = SessionPolicy(silenceTimeout: 900)
    let start = Date(timeIntervalSince1970: 4_000_000)

    init() throws {
        store = try TracksStore(inMemory: true)
    }

    @discardableResult
    func session(startedAt: Date, lastActivity: Date, station: String? = "Apple Music 1") throws -> Session {
        let session = try TracksStore.openSession(in: store.context, stationName: station, policy: policy, now: startedAt)
        session.lastActivityAt = lastActivity
        try store.context.save()
        return session
    }

    @Test("a session still within the timeout stays open")
    func staysOpen() async throws {
        let live = try session(startedAt: start, lastActivity: start)
        let closed = try await store.closeStaleSessions(policy: policy, now: start.addingTimeInterval(899))
        #expect(closed == 0)
        #expect(live.isOpen)
    }

    @Test("a session past the timeout is closed")
    func closesWhenQuiet() async throws {
        let stale = try session(startedAt: start, lastActivity: start)
        let closed = try await store.closeStaleSessions(policy: policy, now: start.addingTimeInterval(900))
        #expect(closed == 1)
        #expect(try !store.stored(stale).isOpen)
    }

    /// Closing at `now` would count the silence as listening.
    @Test("a closed session ends at its last activity, not at the moment it was noticed")
    func endsAtLastActivity() async throws {
        let stale = try session(startedAt: start, lastActivity: start.addingTimeInterval(120))
        try await store.closeStaleSessions(policy: policy, now: start.addingTimeInterval(3_600))
        #expect(try store.stored(stale).endedAt == start.addingTimeInterval(120))
        #expect(try store.stored(stale).duration == 120)
    }

    @Test("a station change starts a new session and closes the old one")
    func stationChange() throws {
        let first = try session(startedAt: start, lastActivity: start)
        let second = try TracksStore.openSession(
            in: store.context,
            stationName: "Apple Música Uno", policy: policy, now: start.addingTimeInterval(60)
        )
        try store.context.save()

        #expect(!first.isOpen)
        #expect(second.isOpen)
        #expect(second.station?.name == "Apple Música Uno")
    }

    @Test("continuing on the same station reuses the open session")
    func sameStationContinues() throws {
        let first = try session(startedAt: start, lastActivity: start)
        let again = try TracksStore.openSession(
            in: store.context,
            stationName: "Apple Music 1", policy: policy, now: start.addingTimeInterval(60)
        )
        #expect(first.persistentModelID == again.persistentModelID)
        #expect(again.lastActivityAt == start.addingTimeInterval(60))
    }

    @Test("one station reuses its row rather than creating duplicates")
    func stationDeduped() async throws {
        try session(startedAt: start, lastActivity: start)
        try await store.closeStaleSessions(policy: policy, now: start.addingTimeInterval(1_000))
        _ = try TracksStore.openSession(
            in: store.context,
            stationName: "Apple Music 1", policy: policy, now: start.addingTimeInterval(2_000)
        )
        try store.context.save()

        let stations = try store.context.fetch(FetchDescriptor<Station>())
        #expect(stations.count == 1)
    }

    @Test("the open session is reported while live and gone once closed")
    func currentOpenSession() async throws {
        try session(startedAt: start, lastActivity: start)
        #expect(try store.currentOpenSession() != nil)
        try await store.closeStaleSessions(policy: policy, now: start.addingTimeInterval(1_000))
        #expect(try store.currentOpenSession() == nil)
    }
}

/// Starting the app mid-station misses the tune-in, so the session starts without a name.
/// The name, once looked up, belongs on that session.
@MainActor
@Suite("Late station naming")
struct LateStationNamingTests {
    let store: TracksStore
    let start = Date(timeIntervalSince1970: 5_000_000)

    init() throws {
        store = try TracksStore(inMemory: true)
    }

    @Test("a nameless session is named once the station becomes known")
    func namesExistingSession() throws {
        let session = try TracksStore.openSession(in: store.context, stationName: nil, now: start)
        try store.context.save()
        #expect(session.station == nil)

        let same = try TracksStore.openSession(
            in: store.context,
            stationName: "Apple Music 1", now: start.addingTimeInterval(30)
        )
        try store.context.save()

        #expect(same.persistentModelID == session.persistentModelID)
        #expect(same.station?.name == "Apple Music 1")
    }

    /// Learning the name isn't a station change.
    @Test("naming an open session does not start a new one")
    func doesNotFragment() throws {
        _ = try TracksStore.openSession(in: store.context, stationName: nil, now: start)
        _ = try TracksStore.openSession(in: store.context, stationName: "Apple Music 1", now: start.addingTimeInterval(30))
        try store.context.save()

        #expect(try store.context.fetch(FetchDescriptor<Session>()).count == 1)
    }

    @Test("a different station still starts a new session")
    func realChangeStillSplits() throws {
        _ = try TracksStore.openSession(in: store.context, stationName: "Apple Music 1", now: start)
        _ = try TracksStore.openSession(in: store.context, stationName: "Apple Música Uno", now: start.addingTimeInterval(30))
        try store.context.save()

        #expect(try store.context.fetch(FetchDescriptor<Session>()).count == 2)
    }
}
