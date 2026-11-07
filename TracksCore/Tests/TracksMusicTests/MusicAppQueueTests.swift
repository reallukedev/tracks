import Foundation
import Testing
import TracksCore
@testable import TracksMusic

/// The parts of the Mac's Music.app queue that don't need Music.app: who hears which song
/// the queue reached, and that only one sequencer ever runs.
@Suite("Music.app queue")
struct MusicAppQueueTests {

    /// Every play-back subscribes afresh, and the stream it replaced ends after. Ending used
    /// to clear the subscriber, so the new play-back heard nothing and marked nothing.
    @Test("an old subscription ending leaves the new one hearing songs", .timeLimit(.minutes(1)))
    func oldSubscriptionEndingKeepsTheNewOne() async throws {
        let reports = ReachedSongs()
        let old = reports.subscribe()
        let following = Task { for await _ in old {} }
        let new = reports.subscribe()
        following.cancel()
        await following.value

        reports.deliver("1")
        reports.finish()
        var heard: [String] = []
        for await songID in new { heard.append(songID) }
        #expect(heard == ["1"])
    }

    @Test("a song reached before anyone subscribed is kept for the first subscriber")
    func backlogIsDelivered() async {
        let reports = ReachedSongs()
        reports.deliver("1")
        let stream = reports.subscribe()
        reports.deliver("2")
        reports.finish()
        var heard: [String] = []
        for await songID in stream { heard.append(songID) }
        #expect(heard == ["1", "2"])
    }

    #if os(macOS)
    /// AppleScript's answer ("Music got an error: -1708") means nothing to the person.
    @Test("Music refusing a song is said without the script's error")
    func scriptFailureInWords() {
        let words = MusicAppPlaybackService.describe(.scriptFailed("Music got an error: -1708"), playlist: "Heard on Radio")
        #expect(words == "Music couldn’t start the song. Open Music and try again.")
        #expect(MusicAppPlaybackService.describe(.musicNotRunning, playlist: "Heard on Radio")
            == "Music isn’t open. Open Music and try again.")
    }
    #endif

    /// Two play-backs started together each started a sequencer, and the first was never
    /// cancelled, so two loops drove Music.app at once.
    @Test("starting a sequencer cancels the one before it")
    func replacingCancels() async {
        let slot = TaskSlot()
        let first = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        slot.replace(with: first)
        let second = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        slot.replace(with: second)

        #expect(first.isCancelled)
        #expect(!second.isCancelled)
        slot.cancel()
        #expect(second.isCancelled)
    }
}
