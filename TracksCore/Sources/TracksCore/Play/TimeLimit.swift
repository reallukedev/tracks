import Synchronization

/// Work given so long and no longer. A task group waits for its children even once they're
/// cancelled, so work that doesn't check for cancellation would hold it past its limit; here
/// the work runs on its own and is left to finish, cancelled, when time runs out.
public enum TimeLimit {
    /// What `work` returns if it's back within `limit`, or nil once `limit` passes, or once
    /// the caller is cancelled.
    /// - Parameter sleep: waits out the limit; tests pass their own.
    public static func value<T: Sendable>(
        within limit: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        of work: @escaping @Sendable () async -> T
    ) async -> T? {
        let race = Race<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.start(continuation)
                race.add(Task { race.finish(await work()) })
                race.add(Task {
                    try? await sleep(limit)
                    race.finish(nil)
                })
            }
        } onCancel: {
            race.finish(nil)
        }
    }
}

/// Resumes its caller once, with whichever finishes first, and cancels the rest.
private final class Race<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T?, Never>?
        var tasks: [Task<Void, Never>] = []
        var isFinished = false
    }

    private let state = Mutex(State())

    func start(_ continuation: CheckedContinuation<T?, Never>) {
        let finishedFirst = state.withLock { state in
            if !state.isFinished { state.continuation = continuation }
            return state.isFinished
        }
        // Cancelled before it began.
        if finishedFirst { continuation.resume(returning: nil) }
    }

    func add(_ task: Task<Void, Never>) {
        let finishedFirst = state.withLock { state in
            if !state.isFinished { state.tasks.append(task) }
            return state.isFinished
        }
        if finishedFirst { task.cancel() }
    }

    func finish(_ value: T?) {
        let (continuation, tasks) = state.withLock { state -> (CheckedContinuation<T?, Never>?, [Task<Void, Never>]) in
            guard !state.isFinished else { return (nil, []) }
            state.isFinished = true
            defer {
                state.continuation = nil
                state.tasks = []
            }
            return (state.continuation, state.tasks)
        }
        for task in tasks { task.cancel() }
        continuation?.resume(returning: value)
    }
}
