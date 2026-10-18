import Foundation
import TracksCore

/// Another source's observations, dropped while a player that outranks it is making sound.
///
/// On the Mac nothing stops Music.app playing alongside Tracks’ own player, the way starting
/// one interrupts the other on iPhone. The coordinator follows one song at a time, so the two
/// players' observations arriving interleaved would keep restarting each other's minimum
/// listening time, and neither song would be kept. Wrapping Music.app's source in this, with
/// ``TracksPlayerContext/isPlaying``, leaves capture listening to Tracks’ player alone while
/// it plays.
///
/// Asks at each observation rather than when the player starts or stops, so there's no state
/// to fall out of step.
public final class DeferringNowPlayingSource: NowPlayingSource {
    private let source: any NowPlayingSource
    private let isOutranked: @MainActor @Sendable () -> Bool

    /// - Parameter isOutranked: whether the player that outranks `source` is playing now.
    ///   Asked once per observation, on the main actor, where the players keep their state.
    public init(
        _ source: any NowPlayingSource,
        deferringWhile isOutranked: @escaping @MainActor @Sendable () -> Bool
    ) {
        self.source = source
        self.isOutranked = isOutranked
    }

    public func start() -> AsyncStream<NowPlayingObservation> {
        let (stream, continuation) = AsyncStream<NowPlayingObservation>.makeStream()
        let observations = source.start()
        let isOutranked = self.isOutranked
        // Ends when the source finishes its stream, which `stop()` or the next `start()` does.
        let task = Task { @MainActor in
            for await observation in observations where !isOutranked() {
                continuation.yield(observation)
            }
            continuation.finish()
        }
        // The consumer went away, so there's no one to forward to.
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Stops the source. Its stream finishes, and with it this one.
    public func stop() {
        source.stop()
    }
}
