import Foundation

/// Several players watched as one.
///
/// An iPhone has two: the system player, which is the Music app, and Tracks’ own player on the
/// Play tab. The capture loop takes one stream, so this starts every source and forwards
/// whatever any of them sees, in the order it arrives. Only one of them is ever audible at a
/// time, since starting one interrupts the other.
public final class MergedNowPlayingSource: NowPlayingSource {
    private let sources: [any NowPlayingSource]

    public init(_ sources: [any NowPlayingSource]) {
        self.sources = sources
    }

    public func start() -> AsyncStream<NowPlayingObservation> {
        let (stream, continuation) = AsyncStream<NowPlayingObservation>.makeStream()
        // Each source hands back a fresh stream and finishes the one before, so the forwarding
        // for an earlier stream drains what it has and ends on its own. Not cancelled here:
        // a cancelled iteration drops whatever was still buffered.
        let streams = sources.map { $0.start() }
        let tasks = streams.map { source in
            Task {
                for await observation in source {
                    continuation.yield(observation)
                }
            }
        }
        Task {
            for task in tasks { await task.value }
            continuation.finish()
        }
        // The consumer went away, so there's no one to forward to.
        continuation.onTermination = { _ in
            tasks.forEach { $0.cancel() }
        }
        return stream
    }

    /// Stops every source. Their streams finish, and with them this one.
    public func stop() {
        for source in sources { source.stop() }
    }
}
