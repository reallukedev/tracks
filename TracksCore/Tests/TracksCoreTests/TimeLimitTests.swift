import Synchronization
import Testing
@testable import TracksCore

@Suite("Time limit")
struct TimeLimitTests {
    /// Work that ignores cancellation: it returns only once let go.
    final class Stuck: Sendable {
        private let waiting = Mutex<CheckedContinuation<Void, Never>?>(nil)
        private let isLetGo = Mutex(false)

        func work() async -> Int {
            await withCheckedContinuation { continuation in
                let letGo = isLetGo.withLock { $0 }
                if letGo { continuation.resume() } else { waiting.withLock { $0 = continuation } }
            }
            return 1
        }

        func letGo() {
            isLetGo.withLock { $0 = true }
            waiting.withLock { $0.take() }?.resume()
        }
    }

    @Test func `work back in time is returned`() async {
        let value = await TimeLimit.value(within: .seconds(60)) { 7 }
        #expect(value == 7)
    }

    @Test func `work that ignores cancellation doesn't hold the caller past the limit`() async {
        let stuck = Stuck()
        let value = await TimeLimit.value(within: .seconds(4), sleep: { _ in }) { await stuck.work() }
        #expect(value == nil)
        stuck.letGo()
    }

    @Test func `cancelling the caller returns at once`() async {
        let stuck = Stuck()
        let waiting = Task { await TimeLimit.value(within: .seconds(60)) { await stuck.work() } }
        waiting.cancel()
        #expect(await waiting.value == nil)
        stuck.letGo()
    }
}
