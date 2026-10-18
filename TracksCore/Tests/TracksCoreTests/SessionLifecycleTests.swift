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
        let session = try store.openSession(stationName: station, policy: policy, now: startedAt)
        session.lastActivityAt = lastActivity
        try store.context.save()
        return session
    }

    @Test("a session still within the timeout stays open")
    func staysOpen() throws {
        let live = try session(startedAt: start, lastActivity: start)
        let closed = try store.closeStaleSessions(policy: policy, now: start.addingTimeInterval(899))
        #expect(closed.isEmpty)
        #expect(live.isOpen)
    }

    @Test("a session past the timeout is closed")
    func closesWhenQuiet() throws {
        let stale = try session(startedAt: start, lastActivity: start)
        let closed = try store.closeStaleSessions(policy: policy, now: start.addingTimeInterval(900))
        #expect(closed.count == 1)
        #expect(!stale.isOpen)
    }

    /// Closing at `now` would count the silence as listening.
    @Test("a closed session ends at its last activity, not at the moment it was noticed")
    func endsAtLastActivity() throws {
        let stale = try session(startedAt: start, lastActivity: start.addingTimeInterval(120))
        try store.closeStaleSessions(policy: policy, now: start.addingTimeInterval(3_600))
        #expect(stale.endedAt == start.addingTimeInterval(120))
        #expect(stale.duration == 120)
    }

    @Test("a station change starts a new session and closes the old one")
    func stationChange() throws {
        let first = try session(startedAt: start, lastActivity: start)
        let second = try store.openSession(
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
        let again = try store.openSession(
            stationName: "Apple Music 1", policy: policy, now: start.addingTimeInterval(60)
        )
        #expect(first.persistentModelID == again.persistentModelID)
        #expect(again.lastActivityAt == start.addingTimeInterval(60))
    }

    @Test("one station reuses its row rather than creating duplicates")
    func stationDeduped() throws {
        try session(startedAt: start, lastActivity: start)
        try store.closeStaleSessions(policy: policy, now: start.addingTimeInterval(1_000))
        _ = try store.openSession(
            stationName: "Apple Music 1", policy: policy, now: start.addingTimeInterval(2_000)
        )
        try store.context.save()

        let stations = try store.context.fetch(FetchDescriptor<Station>())
        #expect(stations.count == 1)
    }

    @Test("the open session is reported while live and gone once closed")
    func currentOpenSession() throws {
        try session(startedAt: start, lastActivity: start)
        #expect(try store.currentOpenSession() != nil)
        try store.closeStaleSessions(policy: policy, now: start.addingTimeInterval(1_000))
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
        let session = try store.openSession(stationName: nil, now: start)
        try store.context.save()
        #expect(session.station == nil)

        let same = try store.openSession(
            stationName: "Apple Music 1", now: start.addingTimeInterval(30)
        )
        try store.context.save()

        #expect(same.persistentModelID == session.persistentModelID)
        #expect(same.station?.name == "Apple Music 1")
    }

    /// Learning the name isn't a station change.
    @Test("naming an open session does not start a new one")
    func doesNotFragment() throws {
        _ = try store.openSession(stationName: nil, now: start)
        _ = try store.openSession(stationName: "Apple Music 1", now: start.addingTimeInterval(30))
        try store.context.save()

        #expect(try store.context.fetch(FetchDescriptor<Session>()).count == 1)
    }

    @Test("a different station still starts a new session")
    func realChangeStillSplits() throws {
        _ = try store.openSession(stationName: "Apple Music 1", now: start)
        _ = try store.openSession(stationName: "Apple Música Uno", now: start.addingTimeInterval(30))
        try store.context.save()

        #expect(try store.context.fetch(FetchDescriptor<Session>()).count == 2)
    }
}
