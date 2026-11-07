import Foundation

/// What the player for your own music does when a song streaming from a server stops part way:
/// a dropped connection or a server slow to answer is tried again from where it got to, a
/// couple of times, before the song is given up on.
public enum StreamRetry {
    public enum Step: Equatable, Sendable {
        /// Load the song again after a moment and carry on from where it was.
        case retry(after: Duration)
        /// Move on: it isn't a stream, it's been tried enough, or it won't play however often
        /// it's tried.
        case giveUp
    }

    /// Tries a song gets after the first.
    public static let tries = 2

    /// - Parameters:
    ///   - error: what the player said, if anything.
    ///   - isStream: whether the song was coming from a server rather than a file here.
    ///   - tried: how many times it's been tried again already.
    public static func step(after error: (any Error)?, isStream: Bool, tried: Int) -> Step {
        guard isStream, tried < tries else { return .giveUp }
        // No word of why is most often a connection that went quiet.
        let failure = error.map(PlaybackFailure.init) ?? .timedOut
        switch failure {
        case .offline, .timedOut: return .retry(after: .seconds(tried + 1))
        case .superseded, .interrupted, .unavailable, .accessDenied, .noSubscription, .other: return .giveUp
        }
    }
}

/// Whether a change of where sound goes should pause the music: only when what it was going
/// to was private, headphones or a Bluetooth set, and it's gone, so it would go on out loud
/// from the speaker. A car or an AirPlay speaker dropping out for a moment, or a Bluetooth
/// set reconnecting, isn't a reason to stop.
public enum RoutePause {
    /// - Parameters:
    ///   - previous: the outputs before the change.
    ///   - current: the outputs now.
    ///   - isPrivate: whether an output is heard by the listener alone: headphones or a
    ///     Bluetooth set.
    public static func shouldPause<Output>(previous: [Output], current: [Output], isPrivate: (Output) -> Bool) -> Bool {
        previous.contains(where: isPrivate) && !current.contains(where: isPrivate)
    }
}
