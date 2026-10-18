import Testing
import Foundation
@testable import TracksCore

@Suite("Listening signals")
struct ListeningSignalsTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test(
        "what counts as a skip",
        arguments: [
            (playedFor: 5.0, duration: 200.0 as Double?, isSkip: true),
            (playedFor: 29, duration: 200, isSkip: true),
            (playedFor: 31, duration: 200, isSkip: false),
            // A third of a short song.
            (playedFor: 15, duration: 40, isSkip: false),
            (playedFor: 10, duration: 40, isSkip: true),
            // Ran to the end.
            (playedFor: 40, duration: 40, isSkip: false),
            // Length not known.
            (playedFor: 5, duration: nil, isSkip: false),
        ]
    )
    func skipRule(playedFor: TimeInterval, duration: TimeInterval?, isSkip: Bool) {
        #expect(ListeningSignals.isSkip(playedFor: playedFor, duration: duration) == isSkip)
    }

    @Test("two recent skips drop a song; old ones are forgotten")
    func skipsExpire() {
        var signals = ListeningSignals()
        signals.recordSkip(of: "song", at: now)
        #expect(!signals.excludes("song", now: now))
        signals.recordSkip(of: "song", at: now)
        #expect(signals.excludes("song", now: now))

        let later = now.addingTimeInterval(ListeningSignals.skipMemory + 1)
        #expect(signals.recentSkips(of: "song", now: later) == 0)
        #expect(!signals.excludes("song", now: later))
    }

    @Test("suggest less can be turned on and off")
    func suggestLess() {
        var signals = ListeningSignals()
        signals.setSuggestLess("song", true)
        #expect(signals.excludes("song", now: now))
        signals.setSuggestLess("song", false)
        #expect(!signals.excludes("song", now: now))
    }

    @Test("the number of songs remembered is capped, oldest skips first")
    func capped() {
        var signals = ListeningSignals()
        for index in 0...ListeningSignals.songLimit {
            signals.recordSkip(of: "song \(index)", at: now.addingTimeInterval(TimeInterval(index)))
        }
        #expect(signals.skips.count == ListeningSignals.songLimit)
        #expect(signals.skips["song 0"] == nil)
        #expect(signals.skips["song \(ListeningSignals.songLimit)"] != nil)
    }

    @Test("round-trips through JSON")
    func codable() throws {
        var signals = ListeningSignals()
        signals.recordSkip(of: "a", at: now)
        signals.setSuggestLess("b", true)
        let decoded = try JSONDecoder().decode(ListeningSignals.self, from: JSONEncoder().encode(signals))
        #expect(decoded == signals)
    }
}
