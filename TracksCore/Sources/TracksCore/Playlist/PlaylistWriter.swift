import Foundation

/// Creates and appends to the user's "Heard on Radio" playlist.
///
/// One implementation serves both platforms, since the Apple Music REST API is the only
/// write path on both.
public protocol PlaylistWriter: Sendable {
    /// Creates the playlist and returns its library identifier.
    func createPlaylist(name: String, description: String?) async throws -> String
    /// Appends songs. Succeeding with no response body is normal (HTTP 204).
    func addSongs(ids: [String], toPlaylist playlistID: String) async throws
    /// Whether the playlist is still in the user's library.
    ///
    /// Adding to a playlist the user deleted answers 404, the same as a song Apple won't take.
    /// Asked only after that 404, to tell the two apart.
    func playlistExists(_ playlistID: String) async throws -> Bool
    /// The library playlist with this name, if there is one. Asked before creating one, so a
    /// device that hasn't heard the synced ID yet adopts the playlist rather than making
    /// another.
    func existingPlaylist(named name: String) async throws -> String?
}

extension PlaylistWriter {
    /// Writers that can't tell assume it is, which keeps the old behaviour.
    public func playlistExists(_ playlistID: String) async throws -> Bool { true }
    /// Writers that can't look assume there's none.
    public func existingPlaylist(named name: String) async throws -> String? { nil }
}

/// Why a playlist write failed, in terms the retry queue can act on.
public enum PlaylistWriteError: Error, Sendable, Equatable {
    /// Transport or server problem. Worth retrying.
    case transient(statusCode: Int?, message: String)
    /// The request or the song is wrong and will never succeed.
    case permanent(statusCode: Int?, message: String)
    /// No Apple Music subscription, so catalog writes can't work.
    case notSubscribed
    /// MusicKit couldn't issue a token. Usually a setup problem: the App ID needs MusicKit
    /// enabled under App Services and the build signed with that team. The UI shows
    /// `guidance`.
    ///
    /// Not retryable straight away, but not the song's fault either, and a token can also
    /// fail while a new App ID propagates or the network is out. So the queue keeps the song
    /// and tries again after a pause rather than giving up on it.
    case notConfigured(reason: String, guidance: String)

    /// Whether trying the same write again soon could succeed. Only `transient` failures
    /// can; the others need something to change first. Whether a failure costs the song an
    /// attempt is a separate question, which only `permanent` answers yes to.
    public var isRetryable: Bool {
        if case .transient = self { return true }
        return false
    }

    /// Actionable text for the cases a user can actually do something about.
    public var guidance: String? {
        switch self {
        case .notConfigured(_, let guidance): guidance
        case .notSubscribed: "Playing and saving catalog songs needs an active Apple Music subscription."
        default: nil
        }
    }

    /// Classifies an HTTP status. 401/403 are treated as transient because a token can be
    /// refreshed; 4xx otherwise means the request itself is wrong.
    public static func classify(statusCode: Int, message: String) -> PlaylistWriteError {
        switch statusCode {
        case 401, 403, 408, 429: .transient(statusCode: statusCode, message: message)
        case 500...599: .transient(statusCode: statusCode, message: message)
        case 400...499: .permanent(statusCode: statusCode, message: message)
        default: .transient(statusCode: statusCode, message: message)
        }
    }
}

/// Give up on a row after this many failed writes so one bad song cannot pin the queue.
public let maxPlaylistWriteAttempts = 5
