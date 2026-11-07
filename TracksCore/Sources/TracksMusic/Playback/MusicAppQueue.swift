import Foundation
import Synchronization

/// Hands the songs a play-back reaches to whoever is following it.
///
/// One subscriber at a time, since each play-back subscribes afresh. A song reached before
/// anyone subscribed is kept for the first, so it isn't lost between `play` returning and the
/// controller subscribing.
final class ReachedSongs: Sendable {
    private struct State {
        var buffered: [String] = []
        var continuation: AsyncStream<String>.Continuation?
        /// Which subscription ``continuation`` belongs to, so the stream it replaced ending
        /// afterwards doesn't take it away.
        var subscription = 0
    }

    private let state = Mutex(State())

    /// A new subscription, which ends the one before it.
    func subscribe() -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let (replaced, backlog, subscription) = state.withLock { state in
            state.subscription += 1
            defer {
                state.continuation = continuation
                state.buffered = []
            }
            return (state.continuation, state.buffered, state.subscription)
        }
        // Outside the lock: finishing runs the old stream's termination handler, which takes it.
        replaced?.finish()
        for songID in backlog { continuation.yield(songID) }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { state in
                if state.subscription == subscription { state.continuation = nil }
            }
        }
        return stream
    }

    func deliver(_ songID: String) {
        state.withLock { state in
            if let continuation = state.continuation {
                continuation.yield(songID)
            } else {
                state.buffered.append(songID)
            }
        }
    }

    /// Forgets songs nobody has heard yet, for a new queue.
    func clearBacklog() {
        state.withLock { $0.buffered = [] }
    }

    /// Ends the current subscription.
    func finish() {
        let continuation = state.withLock { state in
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.finish()
    }
}

/// Holds the one task allowed to run, cancelling the one it replaces.
final class TaskSlot: Sendable {
    private let task = Mutex<Task<Void, Never>?>(nil)

    func replace(with new: Task<Void, Never>) {
        task.withLock { current in
            current?.cancel()
            current = new
        }
    }

    func cancel() {
        task.withLock { current in
            current?.cancel()
            current = nil
        }
    }
}
