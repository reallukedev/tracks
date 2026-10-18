import Testing
import Foundation
@testable import TracksCore

/// What "Play back today" queues.
@Suite("Playback selection")
struct PlaybackSelectionTests {
    let today = Date(timeIntervalSince1970: 1_700_000_000)

    func capture(
        id: String,
        at date: Date,
        kind: CaptureKind = .radio,
        playedBack: Date? = nil
    ) -> Capture {
        let capture = Capture(
            songID: id, title: "T\(id)", artistName: "A", kind: kind, capturedAt: date,
            deviceID: "this-device"
        )
        capture.playedBackAt = playedBack
        return capture
    }

    @Test("today's unplayed captures are selected oldest first")
    func ordersOldestFirst() {
        let captures = [
            capture(id: "2", at: today.addingTimeInterval(-60)),
            capture(id: "1", at: today.addingTimeInterval(-600)),
            capture(id: "3", at: today),
        ]
        let selection = PlaybackSelection.todaysUnplayed(from: captures, now: today)
        #expect(selection.map(\.songID) == ["1", "2", "3"])
    }

    /// Apple has already logged these; replaying would inflate the play count.
    @Test("captures already played back are excluded")
    func excludesPlayedBack() {
        let captures = [
            capture(id: "played", at: today, playedBack: today),
            capture(id: "fresh", at: today),
        ]
        let selection = PlaybackSelection.todaysUnplayed(from: captures, now: today)
        #expect(selection.map(\.songID) == ["fresh"])
    }

    @Test("captures from other days are not included")
    func excludesOtherDays() {
        let captures = [
            capture(id: "old", at: today.addingTimeInterval(-60 * 60 * 30)),
            capture(id: "today", at: today),
        ]
        let selection = PlaybackSelection.todaysUnplayed(from: captures, now: today)
        #expect(selection.map(\.songID) == ["today"])
    }

    /// Apple has already logged on-demand plays.
    @Test("on-demand plays are never queued")
    func excludesOnDemand() {
        let captures = [capture(id: "ondemand", at: today, kind: .onDemand)]
        #expect(PlaybackSelection.todaysUnplayed(from: captures, now: today).isEmpty)
    }

    @Test("captures with no catalog id are skipped rather than failing the queue")
    func skipsUnresolved() {
        let captures = [capture(id: "", at: today), capture(id: "good", at: today)]
        let selection = PlaybackSelection.todaysUnplayed(from: captures, now: today)
        #expect(selection.map(\.songID) == ["good"])
    }

    @Test("nothing to play back yields an empty selection")
    func emptyWhenNothingOwed() {
        #expect(PlaybackSelection.todaysUnplayed(from: [], now: today).isEmpty)
    }
}


/// Records what it was asked to play, and lets a test drive "what is playing now".
final class FakePlaybackService: PlaybackService, @unchecked Sendable {
    private let lock = NSLock()
    private var _played: [[String]] = []
    private let continuation: AsyncStream<String>.Continuation
    private let stream: AsyncStream<String>
    var playResult: Result<Void, any Error> = .success(())
    /// Songs the player takes a while to start, as Apple Music does on a poor connection.
    var slowSongs: Set<String> = []

    var played: [[String]] { lock.withLock { _played } }

    init() {
        (stream, continuation) = AsyncStream<String>.makeStream()
    }

    func play(songIDs: [String]) async throws {
        lock.withLock { _played.append(songIDs) }
        if !slowSongs.isDisjoint(with: songIDs) { try? await Task.sleep(for: .milliseconds(200)) }
        try playResult.get()
    }

    func pause() async {}
    func skipToNext() async throws {}
    func nowPlayingIDs() -> AsyncStream<String> { stream }

    /// Simulates playback reaching a song.
    func reach(_ songID: String) { continuation.yield(songID) }
}
