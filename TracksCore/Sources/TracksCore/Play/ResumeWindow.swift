import Foundation

/// How long after Tracks closes the song that was on waits, paused where it was left, for you
/// to come back to it. After that Tracks opens with nothing playing, as if it had finished.
public enum ResumeWindow: String, CaseIterable, Codable, Sendable, Identifiable {
    case oneHour
    case eightHours
    case oneDay
    case threeDays
    case oneWeek
    /// Kept until something else plays.
    case always

    public var id: String { rawValue }

    /// The default: long enough to span a night's sleep and a working day.
    public static let standard = ResumeWindow.oneDay

    /// How long it lasts, or nil for no limit.
    public var duration: TimeInterval? {
        switch self {
        case .oneHour: 60 * 60
        case .eightHours: 8 * 60 * 60
        case .oneDay: 24 * 60 * 60
        case .threeDays: 3 * 24 * 60 * 60
        case .oneWeek: 7 * 24 * 60 * 60
        case .always: nil
        }
    }

    /// Whether a session saved at `savedAt` is still waiting at `now`.
    ///
    /// A save from the future (the clock was changed back since) still counts, rather than
    /// losing the song to a clock.
    public func keeps(savedAt: Date, now: Date = .now) -> Bool {
        guard let duration else { return true }
        return now.timeIntervalSince(savedAt) <= duration
    }
}

/// Where to pick a song up again.
public enum ResumePoint {
    /// Where a song left at `time` starts again: a few seconds back, so you land in the
    /// phrase you left rather than mid-word, and from the top when there was barely anything
    /// played or barely anything left.
    public static func time(leftAt time: TimeInterval, duration: TimeInterval?) -> TimeInterval {
        guard time.isFinite, time > 10 else { return 0 }
        if let duration, duration > 0, time > duration - 5 { return 0 }
        return max(0, time - 3)
    }
}
