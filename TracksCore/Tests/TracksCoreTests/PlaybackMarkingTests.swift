import Testing
import Foundation
import SwiftData
@testable import TracksCore

/// When a capture counts as played back. It must never record a play that didn't happen.
@MainActor
@Suite("Playback marking")
struct PlaybackMarkingTests {
    let store: TracksStore
    let service = FakePlaybackService()
    /// Where captures are dated from.
    ///
    /// `playBackToday` only plays what was captured since the start of the local day, and
    /// reads the real clock and calendar to find it, with no way to be given either. Dating
    /// captures "now" would fail whenever midnight fell between writing a capture and playing
    /// it back, so they are dated a few seconds into today instead. That only goes wrong if
    /// the few milliseconds of the test itself straddle midnight.
    let today = Calendar.current.startOfDay(for: .now)

    init() throws {
        store = try TracksStore(inMemory: true)
    }

    /// Captures are dated `id` seconds into today, so numeric ids also fix the play order.
    @discardableResult
    func capture(id: String) -> Capture {
        let capture = Capture(
            songID: id, title: "T\(id)", artistName: "A",
            capturedAt: today.addingTimeInterval(Double(id) ?? 0),
            deviceID: "this-device"
        )
        store.context.insert(capture)
        return capture
    }

    /// Queueing used to mark everything straight away, even if playback never started.
    @Test("queueing alone does not mark anything played back")
    func queueingMarksNothing() async throws {
        let first = capture(id: "1")
        let second = capture(id: "2")
        try store.context.save()

        let controller = PlaybackController(store: store, service: service)
        await controller.playBackToday()

        #expect(service.played == [["1", "2"]])
        #expect(first.playedBackAt == nil)
        #expect(second.playedBackAt == nil)
    }

    @Test("a capture is marked once playback reaches it")
    func marksOnReach() async throws {
        let first = capture(id: "1")
        let second = capture(id: "2")
        try store.context.save()

        let controller = PlaybackController(store: store, service: service)
        await controller.playBackToday()
        service.reach("1")

        // The stream is consumed on another task. Poll rather than sleep a fixed time: a
        // freshly booted Simulator took longer than 200ms and failed this.
        let deadline = ContinuousClock.now + .seconds(5)
        while first.playedBackAt == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(first.playedBackAt != nil)
        #expect(second.playedBackAt == nil)
    }

    @Test("a failed play marks nothing")
    func failedPlayMarksNothing() async throws {
        let only = capture(id: "1")
        try store.context.save()
        service.playResult = .failure(PlaybackError.notSubscribed)

        let controller = PlaybackController(store: store, service: service)
        await controller.playBackToday()

        #expect(only.playedBackAt == nil)
        #expect(controller.lastError?.contains("subscription") == true)
    }

    /// The Mac opens a song that isn't in the library in Music, which is the right outcome
    /// for a click, not an error to show.
    @Test("a song opened in Music instead is neither an error nor playing, and isn't marked")
    func openedInMusicIsNotAnError() async throws {
        let only = capture(id: "1")
        try store.context.save()
        service.playResult = .failure(PlaybackError.openedInMusic)

        let controller = PlaybackController(store: store, service: service)
        await controller.play(only)

        #expect(controller.lastError == nil)
        #expect(!controller.isPlaying)
        #expect(only.playedBackAt == nil)
    }
}
