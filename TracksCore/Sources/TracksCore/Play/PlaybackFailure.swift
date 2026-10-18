import Foundation

/// Why Apple Music didn't play, read from the error it gave, so the player can say it in words
/// and decide whether one more try is worth it. The raw error ("MPMusicPlayerControllerErrorDomain
/// error 2") never reaches the person.
public enum PlaybackFailure: Equatable, Sendable {
    /// Another request replaced this one before it started. Nothing to tell anyone.
    case superseded
    /// The player gave up preparing the queue, as it does when something changes the queue
    /// under it. Worth one quiet try again.
    case interrupted
    /// No connection, or it dropped.
    case offline
    /// Apple Music took too long to answer.
    case timedOut
    /// The song can't be played here: gone from Apple Music, or not in this country.
    case unavailable
    /// Tracks isn't allowed to use Apple Music.
    case accessDenied
    /// The account can't play the catalog.
    case noSubscription
    /// Anything else.
    case other

    /// The error domain of the player MusicKit plays through.
    static let playerDomain = "MPMusicPlayerControllerErrorDomain"
    /// MediaPlayer's own errors, `MPError`.
    static let mediaPlayerDomain = "MPErrorDomain"

    public init(_ error: any Error) {
        if error is CancellationError {
            self = .superseded
            return
        }
        // The error itself, then what it wraps, until one says something plainer than "other".
        var next: NSError? = error as NSError
        var depth = 0
        while let current = next, depth < 4 {
            let failure = Self.reading(domain: current.domain, code: current.code)
            if failure != .other {
                self = failure
                return
            }
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        self = .other
    }

    /// What happened and what to do, for someone who asked for a song.
    public var words: String {
        switch self {
        case .superseded: String(localized: "Something else started playing first. Try again.")
        case .interrupted: String(localized: "Apple Music stopped before the song started. Try again.")
        case .offline: String(localized: "You’re offline. Connect to the internet and try again.")
        case .timedOut: String(localized: "Apple Music took too long to answer. Try again in a moment.")
        case .unavailable: String(localized: "That song isn’t available in Apple Music here. Try another.")
        case .accessDenied:
            String(localized: "Tracks isn’t allowed to use Apple Music. Turn on Media & Apple Music for Tracks in Settings.")
        case .noSubscription: String(localized: "Playing songs needs an active Apple Music subscription.")
        case .other: String(localized: "Apple Music couldn’t play that. Try again.")
        }
    }

    /// Whether playing the same request again, once, might work.
    public var isWorthRetrying: Bool {
        switch self {
        case .interrupted, .timedOut, .other: true
        case .superseded, .offline, .unavailable, .accessDenied, .noSubscription: false
        }
    }

    static func reading(domain: String, code: Int) -> PlaybackFailure {
        switch domain {
        case playerDomain:
            // 2 is the queue's preparation being cut short; the others say nothing more.
            return code == 2 ? .interrupted : .other
        case mediaPlayerDomain:
            switch code {
            case 1: return .accessDenied
            case 2: return .noSubscription
            case 3: return .offline
            case 4, 5: return .unavailable
            case 6: return .superseded
            case 7: return .timedOut
            default: return .other
            }
        case NSURLErrorDomain:
            switch code {
            case NSURLErrorCancelled: return .superseded
            case NSURLErrorTimedOut: return .timedOut
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed,
                 NSURLErrorInternationalRoamingOff, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                 NSURLErrorDNSLookupFailed:
                return .offline
            default: return .other
            }
        default:
            return .other
        }
    }
}
