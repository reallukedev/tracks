import Foundation

/// An immutable, `Sendable` view of a ``Session``. See ``CaptureSnapshot`` for why.
public struct SessionSnapshot: Sendable, Identifiable, Hashable {
    public let id: String
    public let stationName: String
    public let startedAt: Date
    public let endedAt: Date?
    public let captureCount: Int
    public let duration: TimeInterval

    public init(
        id: String,
        stationName: String,
        startedAt: Date,
        endedAt: Date?,
        captureCount: Int,
        duration: TimeInterval
    ) {
        self.id = id
        self.stationName = stationName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.captureCount = captureCount
        self.duration = duration
    }

    public var isOpen: Bool { endedAt == nil }
}

public extension Session {
    var snapshot: SessionSnapshot {
        SessionSnapshot(
            id: "\(persistentModelID.hashValue)",
            stationName: station?.name ?? "Unknown Station",
            startedAt: startedAt,
            endedAt: endedAt,
            captureCount: captures?.count ?? 0,
            duration: duration
        )
    }
}
