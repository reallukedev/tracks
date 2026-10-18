import Foundation

/// What the history says about a collection as a whole: an album, a playlist. The line under
/// its title ("You've heard 9 of 12, most recently Sunday"), the back of its sleeve. It says
/// how much of it you know and when you were last in it, never a total of plays: those belong
/// to each song's own page.
public struct CollectionHistory: Sendable, Equatable {
    /// Different songs in it you've played at least once.
    public let heard: Int
    /// Different songs in it. A playlist that holds a song twice counts it once.
    public let total: Int
    /// The last time any of its songs was played.
    public let lastHeard: Date?

    public init(heard: Int, total: Int, lastHeard: Date?) {
        self.heard = heard
        self.total = total
        self.lastHeard = lastHeard
    }

    /// Nothing in it has been played yet.
    public var isNew: Bool { heard == 0 }

    /// Every song in it has been played at least once.
    public var hasHeardAll: Bool { total > 0 && heard == total }

    /// The history of the songs given, by ``CaptureStat/songIdentity``, in the collection's
    /// order. Nil for an empty collection, which has nothing to say.
    public static func summary(songIdentities: [String], facts: [String: SongFacts]) -> CollectionHistory? {
        var seen = Set<String>()
        var heard = 0
        var lastHeard: Date?
        for identity in songIdentities where !identity.isEmpty && seen.insert(identity).inserted {
            guard let song = facts[identity], song.plays > 0 else { continue }
            heard += 1
            if song.lastHeard > (lastHeard ?? .distantPast) {
                lastHeard = song.lastHeard
            }
        }
        guard !seen.isEmpty else { return nil }
        return CollectionHistory(heard: heard, total: seen.count, lastHeard: lastHeard)
    }

    /// How long ago a collection was last in your ears, in the words a person would use:
    /// today, yesterday, a weekday this past week, a month this year, or a year.
    public enum Recency: Sendable, Equatable {
        case today
        case yesterday
        /// Within the last week: said as the day's name.
        case weekday(Date)
        /// Earlier this year: said as the month.
        case month(Date)
        /// Before this year.
        case year(Int)
    }

    /// When any of its songs was last played, or nil if none has been.
    public func recency(now: Date = .now, calendar: Calendar = .current) -> Recency? {
        guard let lastHeard else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: lastHeard), to: calendar.startOfDay(for: now)).day ?? 0
        // A clock set wrong on another device can put a play a little in the future.
        if days <= 0 { return .today }
        if days == 1 { return .yesterday }
        if days < 7 { return .weekday(lastHeard) }
        if calendar.isDate(lastHeard, equalTo: now, toGranularity: .year) { return .month(lastHeard) }
        return .year(calendar.component(.year, from: lastHeard))
    }
}
