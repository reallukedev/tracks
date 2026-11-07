import Testing
import Foundation
import SwiftData
@testable import TracksCore

/// Which captures a play-back marks, and when it stops listening to the player.
@MainActor
@Suite("Playback following", .timeLimit(.minutes(1)))
struct PlaybackFollowingTests {
    let store: TracksStore
    let service = FakePlaybackService()
    /// Captures are dated from the start of today, so `playBackToday`, which reads the real
    /// clock, sees them as today's even just after midnight.
    let today = Calendar.current.startOfDay(for: .now)

    init() throws {
        store = try TracksStore(inMemory: true)
    }

    @discardableResult
    func capture(
        _ songID: String,
        kind: CaptureKind = .radio,
        secondsIntoToday: TimeInterval = 1
    ) throws -> Capture {
        let capture = Capture(
            songID: songID,
            title: "T\(songID)",
            artistName: "A",
            kind: kind,
            capturedAt: today.addingTimeInterval(secondsIntoToday),
            deviceID: "this-device"
        )
        store.context.insert(capture)
        try store.context.save()
        return capture
    }

    /// It used to mark every unmarked capture of the song, whatever day or kind.
    @Test("only the captures that were queued are marked")
    func marksOnlyQueuedCaptures() async throws {
        let queued = try capture("1")
        let yesterday = try capture("1", secondsIntoToday: -60)
        let onDemand = try capture("1", kind: .onDemand, secondsIntoToday: 2)

        let controller = PlaybackController(store: store, service: service)
        await controller.playBackToday()
        service.reach("1")

        try await waitUntil { queued.playedBackAt != nil }
        #expect(yesterday.playedBackAt == nil)
        #expect(onDemand.playedBackAt == nil)
    }

    @Test("following stops once every queued song has been reached")
    func stopsWhenDone() async throws {
        let first = try capture("1", secondsIntoToday: 1)
        let second = try capture("2", secondsIntoToday: 2)

        let controller = PlaybackController(store: store, service: service)
        await controller.playBackToday()
        #expect(controller.isFollowingPlayback)
        service.reach("1")
        service.reach("2")

        try await waitUntil { !controller.isFollowingPlayback }
        #expect(first.playedBackAt != nil)
        #expect(second.playedBackAt != nil)
    }

    /// On iOS it followed the system player for good, so a later play of a queued song from
    /// somewhere else marked it.
    @Test("a song that wasn't queued ends the play-back")
    func foreignSongStops() async throws {
        let first = try capture("1", secondsIntoToday: 1)
        let second = try capture("2", secondsIntoToday: 2)

        let controller = PlaybackController(store: store, service: service)
        await controller.playBackToday()
        service.reach("1")
        try await waitUntil { first.playedBackAt != nil }
        service.reach("elsewhere")
        try await waitUntil { !controller.isFollowingPlayback }

        service.reach("2")
        try await Task.sleep(for: .milliseconds(50))
        #expect(second.playedBackAt == nil)
    }

    /// The player can report what it was playing before the queue took over.
    @Test("an unqueued first report doesn't end the play-back")
    func staleFirstReport() async throws {
        let first = try capture("1")

        let controller = PlaybackController(store: store, service: service)
        await controller.playBackToday()
        service.reach("before")
        service.reach("1")

        try await waitUntil { first.playedBackAt != nil }
    }

    @Test("playing a song from statistics marks only today's owed capture of it")
    func itemPlayMarksTodaysCapture() async throws {
        let owed = try capture("1")
        let yesterday = try capture("1", secondsIntoToday: -60)

        let controller = PlaybackController(store: store, service: service)
        await controller.play(PlaybackItem(songID: "1", title: "T1", artistName: "A"))
        service.reach("1")

        try await waitUntil { owed.playedBackAt != nil }
        #expect(yesterday.playedBackAt == nil)
    }

    /// The slow request finishing last used to start following its own queue, which
    /// stopped the newer one being followed and left its song unmarked.
    @Test("a slow earlier request finishing late doesn't take over from a newer one")
    func latestRequestIsFollowed() async throws {
        let older = try capture("1", secondsIntoToday: 1)
        let newer = try capture("2", secondsIntoToday: 2)
        service.slowSongs = ["1"]

        let controller = PlaybackController(store: store, service: service)
        let slow = Task { await controller.play(PlaybackItem(songID: "1", title: "T1", artistName: "A")) }
        try await waitUntil { service.played.count == 1 }
        await controller.play(PlaybackItem(songID: "2", title: "T2", artistName: "A"))
        await slow.value

        service.reach("2")
        try await waitUntil { newer.playedBackAt != nil }
        #expect(older.playedBackAt == nil)
        #expect(controller.queuedCount == 1)
    }

    /// Sync can merge a capture away before playback reaches it.
    @Test("a queued capture deleted before it's reached is skipped")
    func deletedBeforeReached() async throws {
        let gone = try capture("1", secondsIntoToday: 1)
        let kept = try capture("2", secondsIntoToday: 2)

        let controller = PlaybackController(store: store, service: service)
        await controller.playBackToday()
        store.context.delete(gone)
        try store.context.save()
        service.reach("1")
        service.reach("2")

        try await waitUntil { kept.playedBackAt != nil }
    }
}
