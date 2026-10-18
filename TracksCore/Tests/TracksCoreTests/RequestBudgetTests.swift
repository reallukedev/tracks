import Testing
import Foundation
import Synchronization
@testable import TracksCore

/// A clock the test moves by hand, which also moves when the budget sleeps.
final class HandClock: Sendable {
    private let time = Mutex(Date(timeIntervalSinceReferenceDate: 800_000_000))

    var now: Date { time.withLock { $0 } }

    func advance(_ seconds: TimeInterval) {
        time.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

@Suite("Asking a server for more")
struct RequestBudgetTests {
    let clock = HandClock()

    func budget(capacity: Int = 3, interval: TimeInterval = 8) -> RequestBudget {
        RequestBudget(
            capacity: capacity,
            interval: interval,
            now: { [clock] in clock.now },
            sleep: { [clock] seconds in clock.advance(seconds) }
        )
    }

    @Test("a few asks at once, then none until one comes back")
    func burst() async {
        let budget = budget()
        #expect(await budget.take())
        #expect(await budget.take())
        #expect(await budget.take())
        #expect(await budget.take() == false)
        #expect(await budget.timeUntilNext == 8)
    }

    @Test("asks come back one per interval, and never more than it holds")
    func refill() async {
        let budget = budget()
        for _ in 0..<3 { _ = await budget.take() }
        clock.advance(4)
        #expect(await budget.take() == false, "Half an interval isn't an ask")
        clock.advance(4)
        #expect(await budget.take())
        clock.advance(8 * 100)
        for _ in 0..<3 { #expect(await budget.take()) }
        #expect(await budget.take() == false, "A long rest fills it only to what it holds")
    }

    @Test("waiting takes the next ask as soon as it's there")
    func waits() async throws {
        let budget = budget(capacity: 1, interval: 5)
        try await budget.wait()
        let before = clock.now
        try await budget.wait()
        #expect(clock.now.timeIntervalSince(before) == 5)
    }

    @Test("a wait cancelled before it starts takes nothing")
    func cancelled() async {
        let budget = budget(capacity: 1, interval: 5)
        _ = await budget.take()
        let waiting = Task { try await budget.wait() }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }
}
