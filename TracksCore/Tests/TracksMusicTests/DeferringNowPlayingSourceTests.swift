import Testing
import Foundation
import TracksCore
@testable import TracksMusic

/// On the Mac, Music.app is only heard while Tracks’ own player is quiet.
@Suite("Deferring now-playing source")
@MainActor
struct DeferringNowPlayingSourceTests {
    /// Answers whether the outranking player is playing, one scripted answer per observation.
    @MainActor
    final class Script {
        var answers: [Bool]
        init(_ answers: [Bool]) { self.answers = answers }
        func next() -> Bool { answers.removeFirst() }
    }

    @Test("drops what arrives while the other player plays, and forwards the rest")
    func defers() async {
        let music = PushedNowPlayingSource()
        let script = Script([false, true, false])
        let source = DeferringNowPlayingSource(music, deferringWhile: { script.next() })
        let stream = source.start()
        music.publish(NowPlayingObservation(title: "Before", artistName: "A"))
        music.publish(NowPlayingObservation(title: "During", artistName: "A"))
        music.publish(NowPlayingObservation(title: "After", artistName: "A"))
        source.stop()

        var titles: [String] = []
        for await observation in stream { titles.append(observation.title) }
        #expect(titles == ["Before", "After"])
        #expect(script.answers.isEmpty)
    }

    @Test("stopping finishes the stream, and starting again forwards again")
    func restarts() async {
        let music = PushedNowPlayingSource()
        let source = DeferringNowPlayingSource(music, deferringWhile: { false })
        let first = source.start()
        source.stop()
        for await _ in first {}

        let second = source.start()
        music.publish(NowPlayingObservation(title: "Again", artistName: "A"))
        source.stop()
        var titles: [String] = []
        for await observation in second { titles.append(observation.title) }
        #expect(titles == ["Again"])
    }
}
