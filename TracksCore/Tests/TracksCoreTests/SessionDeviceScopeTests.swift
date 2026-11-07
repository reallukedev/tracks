import Testing
import Foundation
import SwiftData
@testable import TracksCore

/// Sessions sync, so two devices listening at the same time each see the other's open
/// session. Each must leave the other's alone.
@MainActor
@Suite("Session device scope")
struct SessionDeviceScopeTests {
    let store: TracksStore
    let policy = SessionPolicy(silenceTimeout: 900)
    let start = Date(timeIntervalSince1970: 6_000_000)

    init() throws {
        store = try TracksStore(inMemory: true)
    }

    @Test("a new session records the device that opened it")
    func stampsDevice() throws {
        let session = try store.openSession(stationName: "Chill", policy: policy, now: start, deviceID: "mac")
        #expect(session.deviceID == "mac")
    }

    /// The Mac on one station and the iPhone on another used to close each other's session
    /// on every observation, as if the station had changed.
    @Test("two devices on different stations keep their own sessions open")
    func concurrentDevicesDoNotSplitEachOther() throws {
        let mac = try store.openSession(stationName: "Chill", policy: policy, now: start, deviceID: "mac")
        let phone = try store.openSession(
            stationName: "Hits", policy: policy, now: start.addingTimeInterval(10), deviceID: "phone"
        )
        let macAgain = try store.openSession(
            stationName: "Chill", policy: policy, now: start.addingTimeInterval(20), deviceID: "mac"
        )
        try store.context.save()

        #expect(macAgain === mac)
        #expect(mac.isOpen)
        #expect(phone.isOpen)
        #expect(try store.context.fetchCount(FetchDescriptor<Session>()) == 2)
        #expect(try store.currentOpenSession(deviceID: "mac") === mac)
        #expect(try store.currentOpenSession(deviceID: "phone") === phone)
    }

    /// The other device's session looks quiet here only because this device doesn't extend it.
    @Test("closing stale sessions leaves another device's session alone")
    func closeIsScopedToDevice() throws {
        let phone = try store.openSession(stationName: "Hits", policy: policy, now: start, deviceID: "phone")
        try store.context.save()

        let closed = try store.closeStaleSessions(
            policy: policy, now: start.addingTimeInterval(3_600), deviceID: "mac"
        )
        #expect(closed.isEmpty)
        #expect(phone.isOpen)

        let closedByOwner = try store.closeStaleSessions(
            policy: policy, now: start.addingTimeInterval(3_600), deviceID: "phone"
        )
        #expect(closedByOwner.count == 1)
        #expect(!phone.isOpen)
    }

    /// Sessions from before the field have no device. Left out of every device's lookups,
    /// one left open by an older build would stay open for good.
    @Test("a session from before sessions had a device still closes")
    func legacySessionCloses() throws {
        let legacy = Session(startedAt: start, deviceID: nil)
        store.context.insert(legacy)
        try store.context.save()

        #expect(try store.currentOpenSession(deviceID: "mac") === legacy)
        let closed = try store.closeStaleSessions(
            policy: policy, now: start.addingTimeInterval(3_600), deviceID: "mac"
        )
        #expect(closed.count == 1)
        #expect(!legacy.isOpen)
    }

    @Test("a legacy session extended here becomes this device's")
    func legacySessionIsAdopted() throws {
        let legacy = Session(startedAt: start, station: nil, deviceID: nil)
        store.context.insert(legacy)
        try store.context.save()

        let continued = try store.openSession(
            stationName: nil, policy: policy, now: start.addingTimeInterval(60), deviceID: "mac"
        )
        #expect(continued === legacy)
        #expect(legacy.deviceID == "mac")
        #expect(try store.currentOpenSession(deviceID: "phone") == nil)
    }
}

/// Station rows are matched the way ``TracksStore/mergeDuplicateStations()`` groups them.
@MainActor
@Suite("Station matching")
struct StationMatchingTests {
    let store: TracksStore
    let policy = SessionPolicy(silenceTimeout: 900)
    let start = Date(timeIntervalSince1970: 7_000_000)

    init() throws {
        store = try TracksStore(inMemory: true)
    }

    /// An exact-name lookup made a new row for every spelling, which the next merge deleted
    /// again, once per session.
    @Test("a differently cased or spaced name reuses the existing station")
    func matchesOnNormalisedName() throws {
        _ = try store.openSession(stationName: "Café Radio", policy: policy, now: start, deviceID: "mac")
        try store.closeStaleSessions(policy: policy, now: start.addingTimeInterval(1_000), deviceID: "mac")
        let next = try store.openSession(
            stationName: "  cafe radio ", policy: policy, now: start.addingTimeInterval(2_000), deviceID: "mac"
        )
        try store.context.save()

        #expect(try store.context.fetchCount(FetchDescriptor<Station>()) == 1)
        #expect(next.station?.name == "Café Radio")
    }

    @Test("a respelling of the open session's station continues the session")
    func respellingIsNotAStationChange() throws {
        let first = try store.openSession(stationName: "Chill", policy: policy, now: start, deviceID: "mac")
        let again = try store.openSession(
            stationName: "CHILL", policy: policy, now: start.addingTimeInterval(30), deviceID: "mac"
        )
        #expect(again === first)
    }

    /// Two rows that haven't been merged yet: every device must pick the one the merge keeps.
    @Test("with duplicates present, the oldest station is used")
    func picksTheOldestDuplicate() throws {
        let newer = Station(name: "chill", firstSeenAt: start.addingTimeInterval(60))
        let older = Station(name: "Chill", firstSeenAt: start)
        store.context.insert(newer)
        store.context.insert(older)
        try store.context.save()

        let session = try store.openSession(
            stationName: "CHILL", policy: policy, now: start.addingTimeInterval(120), deviceID: "mac"
        )
        #expect(session.station === older)
    }

    /// With a cascade, deleting a station another device merged away took sessions this
    /// device hadn't synced to it yet.
    @Test("deleting a station keeps its sessions and their plays")
    func deletingStationKeepsSessions() throws {
        let station = Station(name: "Chill", firstSeenAt: start)
        store.context.insert(station)
        let session = Session(startedAt: start, station: station, deviceID: "phone")
        store.context.insert(session)
        store.context.insert(Capture(
            songID: "1", title: "T", artistName: "A", capturedAt: start, deviceID: "phone", session: session
        ))
        try store.context.save()

        store.context.delete(station)
        try store.context.save()

        let sessions = try store.context.fetch(FetchDescriptor<Session>())
        #expect(sessions.count == 1)
        #expect(sessions.first?.station == nil)
        #expect(sessions.first?.captures?.count == 1)
    }

    @Test("an open session that lost its station is named again on its next observation")
    func reattachesOpenSession() throws {
        let session = try store.openSession(stationName: "Chill", policy: policy, now: start, deviceID: "mac")
        try store.context.save()
        let station = try #require(session.station)
        store.context.delete(station)
        try store.context.save()
        #expect(session.station == nil)

        let again = try store.openSession(
            stationName: "Chill", policy: policy, now: start.addingTimeInterval(30), deviceID: "mac"
        )
        #expect(again === session)
        #expect(session.station?.name == "Chill")
    }
}
