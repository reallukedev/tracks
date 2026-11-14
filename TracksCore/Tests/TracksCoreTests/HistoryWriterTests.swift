import Foundation
import SwiftData
import Testing
@testable import TracksCore

/// Capture, the queues and reconciling do their store work in ``HistoryWriter``, so a frame
/// never waits on it. Each test holds the main actor while the writer works: anything that
/// still needed the main actor would sit until the hold gives up, and the test would fail.
@Suite("History writer", .timeLimit(.minutes(1)))
struct HistoryWriterTests {
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// A store with what a sync tends to bring: one station under two spellings, and one play
    /// recorded by two devices.
    @MainActor
    func syncedStore() throws -> TracksStore {
        let store = try TracksStore(inMemory: true)
        store.context.insert(Station(name: "Chill", firstSeenAt: start))
        store.context.insert(Station(name: "chill ", firstSeenAt: start.addingTimeInterval(60)))
        store.context.insert(Capture(
            songID: "1", songKey: "1", title: "Nostalgia", artistName: "Lossapardo",
            capturedAt: start, deviceID: "mac"
        ))
        store.context.insert(Capture(
            songID: "1", songKey: "Nostalgia\u{1F}Lossapardo", title: "Nostalgia", artistName: "Lossapardo",
            kind: .onDemand, capturedAt: start.addingTimeInterval(20), deviceID: "phone"
        ))
        try store.context.save()
        return store
    }

    @Test("reconciling merges stations and plays without the main actor")
    func reconcileOffMain() async throws {
        let store = try await syncedStore()
        let (writer, reader) = await (store.writer, store.historyReader)

        let merged = try await whileMainActorIsHeld {
            await writer.reconcile(reader: reader, policy: DedupePolicy())
        }

        #expect(merged == 2)
        let left = try await writer.read { context in
            (stations: try context.fetchCount(FetchDescriptor<Station>()), plays: try context.fetch(FetchDescriptor<Capture>()).map(\.kind))
        }
        #expect(left.stations == 1)
        // The witnessed radio row is the one kept, as on the main actor.
        #expect(left.plays == [.radio])
    }

    @Test("a capture is dated for dedupe, filed in its session and held from scrobbling without the main actor")
    func captureOffMain() async throws {
        let store = try await TracksStore(inMemory: true)
        let writer = await store.writer
        let start = start
        let capture = HistoryWriter.NewCapture(
            songKey: "6768469976",
            catalogSongID: "6768469976",
            observation: NowPlayingObservation(title: "Dai Dai", artistName: "Shakira & Burna Boy", catalogSongID: "6768469976"),
            kind: .radio,
            session: .init(stationName: "Hits", policy: .default),
            now: start,
            scrobbleHold: ScrobblePolicy.notPlayedEnoughReason
        )

        let (before, id, after, closed) = try await whileMainActorIsHeld {
            let before = try await writer.lastCaptureDate(songKey: "6768469976")
            let id = try await writer.recordCapture(capture)
            let after = try await writer.lastCaptureDate(songKey: "6768469976")
            let closed = try await writer.closeStaleSessions(policy: .default, now: start.addingTimeInterval(3_600), deviceID: DeviceIdentity.current)
            return (before, id, after, closed)
        }

        #expect(before == nil)
        #expect(after == start)
        #expect(closed == 1)
        let row = try await writer.read { context in
            let row = try #require(TracksStore.existingCaptures([id], in: context)[id])
            return (station: row.session?.station?.name, held: row.isHeldFromScrobbling, ended: row.session?.endedAt)
        }
        #expect(row.station == "Hits")
        #expect(row.held)
        #expect(row.ended == start)
    }

    /// Runs `work` while the main actor is held by a blocking wait, and fails if the hold had
    /// to give up before the work was done.
    private func whileMainActorIsHeld<T: Sendable>(
        _ work: @Sendable () async throws -> T
    ) async throws -> T {
        let release = DispatchSemaphore(value: 0)
        let holding = DispatchSemaphore(value: 0)
        let hold = Task { @MainActor in
            holding.signal()
            return Self.wait(for: release, seconds: 5)
        }
        await Task.detached { _ = Self.wait(for: holding, seconds: 5) }.value
        let result = try await work()
        release.signal()
        #expect(await hold.value == .success, "the work needed the main actor")
        return result
    }

    /// Blocks the calling thread, which is the point here.
    private nonisolated static func wait(for semaphore: DispatchSemaphore, seconds: Int) -> DispatchTimeoutResult {
        semaphore.wait(timeout: .now() + .seconds(seconds))
    }
}
