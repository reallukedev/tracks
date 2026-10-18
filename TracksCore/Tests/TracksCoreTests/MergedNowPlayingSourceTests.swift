import Testing
import Foundation
import Synchronization
@testable import TracksCore

@Suite("Merged now-playing source")
struct MergedNowPlayingSourceTests {
    /// A source whose observations the test sends by hand.
    final class ManualSource: NowPlayingSource {
        private let continuation = Mutex<AsyncStream<NowPlayingObservation>.Continuation?>(nil)
        let starts = Mutex(0)

        func start() -> AsyncStream<NowPlayingObservation> {
            let (stream, continuation) = AsyncStream<NowPlayingObservation>.makeStream()
            self.continuation.withLock {
                $0?.finish()
                $0 = continuation
            }
            starts.withLock { $0 += 1 }
            return stream
        }

        func stop() {
            continuation.withLock {
                $0?.finish()
                $0 = nil
            }
        }

        func send(_ title: String) {
            _ = continuation.withLock { $0?.yield(NowPlayingObservation(title: title, artistName: "A")) }
        }
    }

    @Test("forwards what every source sees")
    func forwards() async {
        let (system, app) = (ManualSource(), ManualSource())
        let merged = MergedNowPlayingSource([system, app])
        let stream = merged.start()
        system.send("From Music")
        app.send("From Tracks")
        merged.stop()

        var titles: [String] = []
        for await observation in stream { titles.append(observation.title) }
        #expect(Set(titles) == ["From Music", "From Tracks"])
    }

    @Test("stopping finishes the stream, and starting again starts every source again")
    func restarts() async {
        let (system, app) = (ManualSource(), ManualSource())
        let merged = MergedNowPlayingSource([system, app])
        let first = merged.start()
        merged.stop()
        for await _ in first {}

        let second = merged.start()
        app.send("Again")
        merged.stop()
        var titles: [String] = []
        for await observation in second { titles.append(observation.title) }
        #expect(titles == ["Again"])
        #expect(system.starts.withLock { $0 } == 2)
        #expect(app.starts.withLock { $0 } == 2)
    }
}
