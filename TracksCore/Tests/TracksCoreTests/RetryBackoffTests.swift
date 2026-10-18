import Testing
import Foundation
@testable import TracksCore

@Suite("Retry backoff")
struct RetryBackoffTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func backoff(initial: TimeInterval = 30, maximum: TimeInterval = 900) -> RetryBackoff {
        var backoff = RetryBackoff()
        backoff.initial = initial
        backoff.maximum = maximum
        return backoff
    }

    /// The delay set by each failure in a row, each recorded at `t0`.
    func delays(_ count: Int, of start: RetryBackoff = RetryBackoff()) -> [TimeInterval] {
        var backoff = start
        return (0..<count).map { _ in
            backoff.recordFailure(at: t0)
            return backoff.notBefore.map { $0.timeIntervalSince(t0) } ?? .nan
        }
    }

    @Test("a fresh backoff allows anything")
    func fresh() {
        let backoff = RetryBackoff()
        #expect(backoff.failures == 0)
        #expect(backoff.notBefore == nil)
        #expect(backoff.allows(at: .distantPast))
        #expect(backoff.allows(at: t0))
        #expect(backoff.allows(at: .distantFuture))
    }

    @Test("the wait doubles with each failure in a row, up to the maximum")
    func doubling() {
        #expect(delays(9) == [30, 60, 120, 240, 480, 900, 900, 900, 900])
    }

    @Test("each wait is measured from that failure, not the last wait's end")
    func measuredFromFailure() {
        var backoff = RetryBackoff()
        backoff.recordFailure(at: t0)
        backoff.recordFailure(at: t0.addingTimeInterval(5))
        #expect(backoff.notBefore == t0.addingTimeInterval(5 + 60))
        #expect(backoff.failures == 2)
    }

    @Test("the gate opens exactly at the end of the wait", arguments: [
        (29.999, false), (30, true), (31, true),
    ])
    func gate(offset: TimeInterval, allowed: Bool) {
        var backoff = RetryBackoff()
        backoff.recordFailure(at: t0)
        #expect(backoff.allows(at: t0.addingTimeInterval(offset)) == allowed)
    }

    @Test("many failures in a row never overflow the maximum", arguments: [100, 10_000])
    func noOverflow(count: Int) throws {
        var backoff = RetryBackoff()
        for _ in 0..<count { backoff.recordFailure(at: t0) }
        let delay = try #require(backoff.notBefore).timeIntervalSince(t0)
        #expect(delay == 900)
        #expect(backoff.failures == count)
    }

    @Test("reset clears the wait, and the next failure starts over")
    func reset() {
        var backoff = RetryBackoff()
        for _ in 0..<4 { backoff.recordFailure(at: t0) }
        backoff.reset()
        #expect(backoff.failures == 0)
        #expect(backoff.notBefore == nil)
        #expect(backoff.allows(at: t0))
        #expect(backoff == RetryBackoff())

        backoff.recordFailure(at: t0)
        #expect(backoff.notBefore == t0.addingTimeInterval(30))
    }

    @Test("custom initial and maximum")
    func custom() {
        #expect(delays(3, of: backoff(initial: 10, maximum: 25)) == [10, 20, 25])
    }

    @Test("a zero initial wait always allows")
    func zeroInitial() {
        var backoff = backoff(initial: 0)
        for _ in 0..<5 {
            backoff.recordFailure(at: t0)
            #expect(backoff.allows(at: t0))
        }
    }

    @Test("a maximum below the initial wait caps every delay at the maximum")
    func maximumBelowInitial() {
        #expect(delays(3, of: backoff(initial: 30, maximum: 5)) == [5, 5, 5])
    }

    @Test("backoffs with the same history are equal")
    func equatable() {
        var a = RetryBackoff()
        var b = RetryBackoff()
        a.recordFailure(at: t0)
        #expect(a != b)
        b.recordFailure(at: t0)
        #expect(a == b)
    }
}
