import Testing
@testable import TracksCore

/// Counts operations running at once, and the most there ever were.
private actor Gauge {
    private(set) var now = 0
    private(set) var most = 0

    func enter() {
        now += 1
        most = max(most, now)
    }

    func leave() { now -= 1 }
}

@Suite("Running a few at a time")
struct AsyncLimiterTests {
    @Test("never runs more at once than its limit, and runs everything", arguments: [1, 3])
    func limit(_ limit: Int) async throws {
        let limiter = AsyncLimiter(limit: limit)
        let gauge = Gauge()
        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<12 {
                group.addTask {
                    try await limiter.run {
                        await gauge.enter()
                        for _ in 0..<5 { await Task.yield() }
                        await gauge.leave()
                        return index
                    }
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.sorted() == Array(0..<12))
        #expect(await gauge.most <= limit)
        #expect(await gauge.now == 0)
    }

    @Test("a wait cancelled before its turn ends, and doesn't use up a turn")
    func cancelledWait() async throws {
        let limiter = AsyncLimiter(limit: 1)
        let (gate, open) = AsyncStream<Void>.makeStream()
        let (holding, holds) = AsyncStream<Void>.makeStream()
        let holder = Task {
            try await limiter.run {
                holds.yield()
                for await _ in gate { break }
            }
        }
        // The holder has the turn before the waiter asks, or the waiter could take it first.
        for await _ in holding { break }
        let waiter = Task {
            try await limiter.run { "ran" }
        }
        // Until the waiter is queued behind the holder.
        while await limiter.waitingCount == 0 { await Task.yield() }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }

        open.yield()
        try await holder.value
        #expect(try await limiter.run { "next" } == "next")
    }

    @Test("an operation's error reaches the caller, and frees its turn")
    func errors() async throws {
        struct Refused: Error, Equatable {}
        let limiter = AsyncLimiter(limit: 1)
        await #expect(throws: Refused()) { try await limiter.run { throw Refused() } }
        #expect(try await limiter.run { 1 } == 1)
    }
}
