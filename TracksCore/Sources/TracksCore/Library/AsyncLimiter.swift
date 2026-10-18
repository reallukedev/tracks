import Foundation

/// Runs at most so many operations at once; the rest wait their turn, first come first
/// served. For a server that slows down, or has what it asks of others refused, when it's
/// asked too much at once, as Octo does when its lookups on Deezer are rate limited.
public actor AsyncLimiter {
    public let limit: Int
    private var running = 0
    private var waiting: [(id: UUID, turn: CheckedContinuation<Void, any Error>)] = []

    public init(limit: Int) {
        precondition(limit > 0, "A limiter that lets nothing run would wait forever")
        self.limit = limit
    }

    /// Runs `operation` once there's room. Waiting stops with `CancellationError` if the
    /// task is cancelled first, without taking a turn from anyone.
    public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await start()
        defer { finish() }
        return try await operation()
    }

    private func start() async throws {
        try Task.checkCancellation()
        if running < limit {
            running += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await waitForTurn(id)
        } onCancel: {
            Task { await self.giveUp(id) }
        }
    }

    private func waitForTurn(_ id: UUID) async throws {
        try await withCheckedThrowingContinuation { (turn: CheckedContinuation<Void, any Error>) -> Void in
            if Task.isCancelled {
                turn.resume(throwing: CancellationError())
            } else {
                waiting.append((id: id, turn: turn))
            }
        }
    }

    /// Hands the turn straight to whoever's waited longest, so `running` counts them already.
    private func finish() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().turn.resume()
        }
    }

    /// How many are waiting for a turn, for tests.
    var waitingCount: Int { waiting.count }

    private func giveUp(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).turn.resume(throwing: CancellationError())
    }
}
