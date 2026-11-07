import Foundation
import SwiftData

/// Cached aggregates for the ranges too expensive to recompute on every render.
///
/// Week and Month take a few milliseconds, so they're computed on demand. Year and All-time
/// are cached here and recomputed when a session closes, on launch if older than
/// ``staleAfter``, and on year rollover.
@Model
public final class StatsSnapshot {
    public var rangeRawValue: String = StatsRange.allTime.rawValue
    public var computedAt: Date = Date.distantPast

    public var captureCount: Int = 0
    public var uniqueSongCount: Int = 0
    public var uniqueArtistCount: Int = 0
    public var sessionCount: Int = 0
    public var totalListeningSeconds: Double = 0
    /// Share of captured songs that weren't already in the user's library.
    public var discoveryRate: Double = 0

    public init(range: StatsRange, computedAt: Date = .now) {
        self.rangeRawValue = range.rawValue
        self.computedAt = computedAt
    }

    public var range: StatsRange {
        get { StatsRange(rawValue: rangeRawValue) ?? .allTime }
        set { rangeRawValue = newValue.rawValue }
    }

    public static let staleAfter: TimeInterval = 24 * 60 * 60

    public func isStale(now: Date = .now) -> Bool {
        now.timeIntervalSince(computedAt) > Self.staleAfter
    }
}

public enum StatsRange: String, Codable, Sendable, CaseIterable {
    case week, month, year, allTime

    /// Week and month are cheap enough to compute per render; the others are cached.
    public var isCached: Bool {
        switch self {
        case .week, .month: false
        case .year, .allTime: true
        }
    }
}
