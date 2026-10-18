import Foundation

/// A guest's side of a Tracks SharePlay session: where it's got to, what the host has on, and
/// what became of each song this person picked.
public struct SharePlayGuest: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Joined the session, waiting to hear from the host.
        case joining
        case joined
        /// The host ended it, or it ended under this person.
        case ended
    }

    /// One song this person picked.
    public enum AddState: Sendable, Equatable {
        case sending
        case added(SharePlayPlacement)
        case notAdded(SharePlayRefusal)

        /// In, or on its way: nothing more to press.
        public var isDone: Bool {
            switch self {
            case .added, .notAdded(.alreadyQueued): true
            case .sending, .notAdded: false
            }
        }
    }

    /// How long to wait for the host to answer.
    public static let answerTimeout: TimeInterval = 12

    private(set) public var phase: Phase = .joining
    private(set) public var snapshot: SharePlaySnapshot?
    /// By catalog id.
    private(set) public var adds: [String: AddState] = [:]
    private var pending: [UUID: Pending] = [:]

    private struct Pending: Sendable, Equatable {
        let catalogID: String
        let sentAt: Date
    }

    public init() {}

    public func state(of catalogID: String) -> AddState? {
        adds[catalogID]
    }

    /// The host is there and has said what's on.
    public mutating func receive(_ snapshot: SharePlaySnapshot) {
        guard phase != .ended else { return }
        self.snapshot = snapshot
        phase = .joined
    }

    /// The request to send for a song, or nil when it's already in, already on its way, or
    /// can't go in (said on the row instead).
    public mutating func add(_ song: SharePlaySong, placement: SharePlayPlacement, at date: Date, id: UUID = UUID()) -> SharePlayAddRequest? {
        guard phase == .joined, let snapshot else { return nil }
        if let state = adds[song.catalogID], state == .sending || state.isDone { return nil }
        if snapshot.isStation {
            adds[song.catalogID] = .notAdded(.station)
            return nil
        }
        if song.isExplicit, !snapshot.allowsExplicit {
            adds[song.catalogID] = .notAdded(.explicit)
            return nil
        }
        adds[song.catalogID] = .sending
        pending[id] = Pending(catalogID: song.catalogID, sentAt: date)
        return SharePlayAddRequest(id: id, song: song, placement: placement)
    }

    public mutating func receive(_ reply: SharePlayAddReply) {
        guard let request = pending.removeValue(forKey: reply.requestID) else { return }
        switch reply.outcome {
        case .added(let placement): adds[request.catalogID] = .added(placement)
        case .refused(let refusal): adds[request.catalogID] = .notAdded(refusal)
        }
    }

    /// A request that couldn't be sent at all.
    public mutating func failedToSend(_ requestID: UUID) {
        guard let request = pending.removeValue(forKey: requestID) else { return }
        adds[request.catalogID] = .notAdded(.noAnswer)
    }

    /// Gives up on requests the host never answered.
    public mutating func expire(at date: Date) {
        for (id, request) in pending where date.timeIntervalSince(request.sentAt) >= Self.answerTimeout {
            pending[id] = nil
            adds[request.catalogID] = .notAdded(.noAnswer)
        }
    }

    public var hasPending: Bool { !pending.isEmpty }

    public mutating func end() {
        phase = .ended
        for (id, request) in pending {
            pending[id] = nil
            adds[request.catalogID] = .notAdded(.noAnswer)
        }
    }
}
