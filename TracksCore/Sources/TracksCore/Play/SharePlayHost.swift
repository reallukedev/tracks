import Foundation

/// The host's first look at a guest's request, before anything is looked up: whether it's
/// one to answer at all, and whether it can go in.
///
/// In a car, a passenger's thumb lands twice, a request can arrive twice, and five people can
/// all pick the same song. The queue is the driver's, so each person gets a few songs a minute
/// and the same song never goes in twice.
public struct SharePlayGate: Sendable {
    public enum Decision: Equatable, Sendable {
        /// Look the song up and add it.
        case accept
        case refuse(SharePlayRefusal)
        /// A request already answered, arriving again: say nothing.
        case ignore
    }

    /// Songs one person can add in ``window``.
    public var burst: Int
    public var window: TimeInterval

    private var seenRequests: Set<UUID> = []
    /// Each person's recent requests that went in, and when, newest last.
    private var recent: [UUID: [(date: Date, identity: String)]] = [:]

    public init(burst: Int = 5, window: TimeInterval = 60) {
        self.burst = burst
        self.window = window
    }

    /// Decides on one request from one person.
    ///
    /// - Parameters:
    ///   - queued: every song on now or coming up at the host, by identity.
    ///   - isStation: a station is playing, which has no queue to add to.
    public mutating func check(
        _ request: SharePlayAddRequest,
        from participant: UUID,
        at date: Date,
        queued: Set<String>,
        isStation: Bool
    ) -> Decision {
        guard seenRequests.insert(request.id).inserted else { return .ignore }
        var mine = (recent[participant] ?? []).filter { date.timeIntervalSince($0.date) < window }
        defer { recent[participant] = mine }
        if isStation { return .refuse(.station) }
        let identity = request.song.identity
        // Already on its way, from anyone, or asked for a moment ago and not in the queue yet.
        if queued.contains(identity) || recent.values.joined().contains(where: { $0.identity == identity && date.timeIntervalSince($0.date) < window }) {
            return .refuse(.alreadyQueued)
        }
        guard mine.count < burst else { return .refuse(.tooMany) }
        mine.append((date, identity))
        return .accept
    }

    /// Forgets a song that didn't go in after all, so it can be asked for again and doesn't
    /// count against the person.
    public mutating func release(_ request: SharePlayAddRequest, from participant: UUID) {
        recent[participant]?.removeAll { $0.identity == request.song.identity }
    }
}

/// Which songs in the host's queue came from SharePlay, by identity, for the glyph on their
/// rows. A song leaves once it has played and gone from the queue.
public struct SharePlayLedger: Sendable, Equatable {
    private(set) public var identities: Set<String> = []

    public init(identities: Set<String> = []) {
        self.identities = identities
    }

    public func contains(_ identity: String) -> Bool {
        identities.contains(identity)
    }

    public mutating func record(_ identity: String) {
        identities.insert(identity)
    }

    /// Keeps only what's still on or coming up.
    public mutating func prune(keeping queued: Set<String>) {
        identities.formIntersection(queued)
    }
}

/// When the host tells the group what's on: only when something they'd see has changed, and
/// again for anyone who's just arrived.
public struct SharePlayBroadcast: Sendable {
    private(set) public var lastSent: SharePlaySnapshot?

    public init() {}

    /// The snapshot to send, or nil when the group already has it.
    public mutating func next(_ snapshot: SharePlaySnapshot) -> SharePlaySnapshot? {
        guard snapshot != lastSent else { return nil }
        lastSent = snapshot
        return snapshot
    }

    /// Someone joined: the next snapshot goes out even if nothing changed.
    public mutating func resend() {
        lastSent = nil
    }
}
