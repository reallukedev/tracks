#if os(macOS)
import Testing
import TracksCore
@testable import TracksMusic

/// Pausing capture stops the source and resuming starts it again. Payloads go in through
/// `deliver(_:)` rather than a posted notification, which every app on the Mac would see.
@Suite("macOS playerInfo source")
struct PlayerInfoSourceTests {
    static let payload = [
        PlayerInfoKey.name: "Lost Boys",
        PlayerInfoKey.artist: "Phoebe Bridgers",
        PlayerInfoKey.playerState: "Playing",
    ]

    @Test("stopping ends the stream start handed out")
    func stopFinishes() async {
        let source = PlayerInfoSource()
        let stream = source.start()
        source.stop()
        // Only returns because the stream finished.
        for await _ in stream {}
    }

    @Test("after a stop, starting again still delivers observations")
    func resumes() async {
        let source = PlayerInfoSource()
        _ = source.start()
        source.stop()

        let resumed = source.start()
        source.deliver(Self.payload)
        source.stop()

        var titles: [String] = []
        for await observation in resumed { titles.append(observation.title) }
        // `contains`, since Music playing on this Mac can post a real notification too.
        #expect(titles.contains("Lost Boys"))
    }

    @Test("starting again hands the observations to the new stream only")
    func restartReplacesStream() async {
        let source = PlayerInfoSource()
        let old = source.start()
        let new = source.start()
        source.deliver(Self.payload)
        source.stop()

        var oldTitles: [String] = []
        for await observation in old { oldTitles.append(observation.title) }
        var newTitles: [String] = []
        for await observation in new { newTitles.append(observation.title) }
        #expect(!oldTitles.contains("Lost Boys"))
        #expect(newTitles.contains("Lost Boys"))
    }
}
#endif
