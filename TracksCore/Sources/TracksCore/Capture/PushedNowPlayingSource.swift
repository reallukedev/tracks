import Foundation
import Synchronization

/// A player that says what it's playing rather than being watched: Tracks’ own player for
/// your files and servers, which plays through AVFoundation where MusicKit can't see it.
///
/// The player publishes each change; capture reads them like any other source's.
public final class PushedNowPlayingSource: NowPlayingSource {
    private struct State {
        var continuation: AsyncStream<NowPlayingObservation>.Continuation?
        var current: NowPlayingObservation?
    }

    private let state = Mutex(State())

    public init() {}

    public func start() -> AsyncStream<NowPlayingObservation> {
        let (stream, continuation) = AsyncStream<NowPlayingObservation>.makeStream()
        state.withLock { state in
            state.continuation?.finish()
            state.continuation = continuation
            // Whatever is already playing counts from now.
            if let current = state.current { continuation.yield(current) }
        }
        return stream
    }

    public func stop() {
        state.withLock { state in
            state.continuation?.finish()
            state.continuation = nil
        }
    }

    /// Hands capture the player's latest state: a new song, or a pause or a resume.
    public func publish(_ observation: NowPlayingObservation?) {
        state.withLock { state in
            state.current = observation
            if let observation { state.continuation?.yield(observation) }
        }
    }

    /// What the player last said, for capture's own checks between changes.
    public var current: NowPlayingObservation? {
        state.withLock { $0.current }
    }

    /// Whether the player last said it was playing.
    public var isPlaying: Bool {
        current?.playbackState == .playing
    }
}

extension PushedNowPlayingSource {
    /// The player for your own music on iPhone. One for the process, shared by the player that
    /// publishes and the capture service that listens.
    public static let yourMusic = PushedNowPlayingSource()
}
