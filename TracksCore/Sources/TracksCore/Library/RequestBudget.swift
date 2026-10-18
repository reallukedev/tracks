import Foundation

/// How often a server may be asked for more: a few at once, then one every so often, however
/// fast someone scrolls. Each ask a server like Octo answers by looking songs up on Last.fm,
/// Deezer, iTunes and YouTube, and asked too often, those services turn it away and it slows
/// for everyone.
///
/// A token bucket: ``capacity`` asks are there to start with, and one comes back every
/// ``interval``. Waiting takes the next one as soon as it's there.
public actor RequestBudget {
    public let capacity: Int
    public let interval: TimeInterval
    private var tokens: Double
    private var refilledAt: Date
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        capacity: Int,
        interval: TimeInterval,
        now: @escaping @Sendable () -> Date = { .now },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        precondition(capacity > 0 && interval > 0, "A budget that never allows an ask would wait forever")
        self.capacity = capacity
        self.interval = interval
        self.tokens = Double(capacity)
        self.now = now
        self.sleep = sleep
        self.refilledAt = now()
    }

    /// Takes an ask if one's there, without waiting.
    public func take() -> Bool {
        refill()
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }

    /// Waits for an ask and takes it. Throws `CancellationError` if the task is cancelled
    /// while waiting, without taking one.
    public func wait() async throws {
        while !take() {
            try await sleep(timeUntilNext)
            try Task.checkCancellation()
        }
    }

    /// How long until the next ask is there: nothing if one already is.
    public var timeUntilNext: TimeInterval {
        refill()
        return tokens >= 1 ? 0 : (1 - tokens) * interval
    }

    private func refill() {
        let current = now()
        let earned = current.timeIntervalSince(refilledAt) / interval
        tokens = min(Double(capacity), tokens + max(0, earned))
        refilledAt = current
    }
}
