import Testing
import Foundation
import SwiftData
@testable import TracksCore

/// What "Play back" still has to play, read from the store. The widget's Up Next section
/// shows the same list, so these cover it too.
@MainActor
@Suite("Play back queue")
struct PlayBackQueueTests {
    let store: TracksStore
    /// Midday, well clear of the day boundary.
    let now = Date(timeIntervalSince1970: 1_700_049_600)
    let calendar: Calendar

    init() throws {
        store = try TracksStore(inMemory: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        self.calendar = calendar
    }

    @discardableResult
    func capture(
        _ title: String,
        minutesAgo: Double,
        kind: CaptureKind = .radio,
        songID: String? = nil,
        playedBack: Bool = false
    ) -> Capture {
        let capture = Capture(
            songID: songID ?? "id-\(title)",
            title: title,
            artistName: "Artist",
            kind: kind,
            capturedAt: now.addingTimeInterval(-minutesAgo * 60),
            deviceID: "this-device"
        )
        capture.playedBackAt = playedBack ? now : nil
        store.context.insert(capture)
        return capture
    }

    func queue() throws -> [String] {
        try store.playBackQueue(now: now, calendar: calendar).map(\.title)
    }

    @Test("today's radio songs queue in the order they were heard")
    func queuesInListeningOrder() throws {
        capture("Third", minutesAgo: 5)
        capture("First", minutesAgo: 60)
        capture("Second", minutesAgo: 30)
        try store.context.save()

        #expect(try queue() == ["First", "Second", "Third"])
    }

    @Test("only songs play-back can and should play are queued")
    func excludesEverythingNotOwed() throws {
        capture("Owed", minutesAgo: 10)
        capture("On demand", minutesAgo: 10, kind: .onDemand)
        capture("Imported", minutesAgo: 10, kind: .imported)
        capture("Yesterday", minutesAgo: 60 * 24)
        capture("Already played back", minutesAgo: 10, playedBack: true)
        capture("Unidentified", minutesAgo: 10, songID: "")
        try store.context.save()

        #expect(try queue() == ["Owed"])
    }

    @Test("a song leaves the queue once it has been played back")
    func playedBackSongLeaves() throws {
        let first = capture("First", minutesAgo: 20)
        capture("Second", minutesAgo: 10)
        try store.context.save()

        first.playedBackAt = now
        try store.context.save()

        #expect(try queue() == ["Second"])
    }

    @Test("an empty day queues nothing")
    func emptyDayQueuesNothing() throws {
        #expect(try queue().isEmpty)
    }

    /// Fails if `playBackToday` stops using `playBackQueue` and picks its own songs.
    ///
    /// `playBackToday` reads the real clock and the machine's calendar, and has no way to be
    /// given either. So the songs are dated a few seconds after the start of the local day
    /// rather than a few seconds ago: "seconds ago" is yesterday for the first seconds after
    /// midnight, which would empty the queue and fail this.
    @Test("Play Back Today plays exactly the queue, in the same order")
    func playBackTodayPlaysTheQueue() async throws {
        let today = Calendar.current.startOfDay(for: .now)
        for (index, title) in ["A", "B", "C"].enumerated() {
            store.context.insert(Capture(
                songID: "id-\(title)",
                title: title,
                artistName: "Artist",
                capturedAt: today.addingTimeInterval(Double(index + 1)),
                deviceID: "this-device"
            ))
        }
        store.context.insert(Capture(
            songID: "id-on-demand", title: "On demand", artistName: "Artist",
            kind: .onDemand, capturedAt: today.addingTimeInterval(2), deviceID: "this-device"
        ))
        try store.context.save()

        let queued = try store.playBackQueue().map(\.songID)
        let service = FakePlaybackService()
        await PlaybackController(store: store, service: service).playBackToday()

        #expect(queued == ["id-A", "id-B", "id-C"])
        #expect(service.played == [queued])
    }
}
