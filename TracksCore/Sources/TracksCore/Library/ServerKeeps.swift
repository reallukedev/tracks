import Foundation

/// Songs asked of one music server to keep, by song, with when each was asked. Asking stars
/// the song there, which a server like Octo takes as "get me this" and answers by fetching the
/// file into its library. Each song is waited for until a sync brings it in, or a day passes.
public struct ServerKeeps: Codable, Sendable, Equatable {
    /// How long a song is waited for. Past this the server couldn't find it, and a daily sync
    /// will bring it in if it ever does.
    public static let patience: TimeInterval = 24 * 60 * 60

    private var asked: [String: Date] = [:]

    public init() {}

    public var isEmpty: Bool { asked.isEmpty }

    /// - Parameter identity: the song's ``LocalTrack/identity``, which stays the same when
    ///   the server files it under a new id.
    public mutating func ask(for identity: String, at date: Date = .now) {
        asked[identity] = date
    }

    public func isWaiting(for identity: String) -> Bool {
        asked[identity] != nil
    }

    /// Lets go of the songs a sync brought in, and of any waited for longer than ``patience``.
    public mutating func settle(arrived: Set<String>, now: Date = .now) {
        asked = asked.filter { identity, date in
            !arrived.contains(identity) && now.timeIntervalSince(date) < Self.patience
        }
    }
}
