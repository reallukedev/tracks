import Foundation

/// Everything the history says about one song, for the back of its sleeve: how often, since
/// when, where it came from, how the last year went, and when in the day it's played.
public struct SongStory: Sendable, Equatable {
    /// Plays kept, the one playing now included once it's kept.
    public let plays: Int
    public let radioPlays: Int
    public let firstHeard: Date
    /// The station of the first play, when it came from the radio.
    public let firstStation: String?
    /// The play before this listening, or nil when there's been none.
    public let lastHeard: Date?
    /// Plays in each of the last twelve months, oldest first, this month last.
    public let months: [MonthPlays]
    /// The part of the day that holds most of its plays, once there are enough to say so.
    public let usualTime: DayPart?
    /// Its place among every song played this month, when it's in the top 25.
    public let rankThisMonth: Int?

    public struct MonthPlays: Sendable, Equatable, Identifiable {
        /// The first moment of the month.
        public let start: Date
        public let plays: Int

        public var id: Date { start }

        public init(start: Date, plays: Int) {
            self.start = start
            self.plays = plays
        }
    }

    public init(
        plays: Int,
        radioPlays: Int,
        firstHeard: Date,
        firstStation: String?,
        lastHeard: Date?,
        months: [MonthPlays],
        usualTime: DayPart?,
        rankThisMonth: Int?
    ) {
        self.plays = plays
        self.radioPlays = radioPlays
        self.firstHeard = firstHeard
        self.firstStation = firstStation
        self.lastHeard = lastHeard
        self.months = months
        self.usualTime = usualTime
        self.rankThisMonth = rankThisMonth
    }

    /// The busiest month's plays, so the bars share one scale. Never zero.
    public var busiestMonth: Int { max(1, months.map(\.plays).max() ?? 1) }
}

public enum SongStories {
    /// A part of the day is "usual" once the song has this many plays...
    static let usualMinimumPlays = 4
    /// ...and at least this share of them fall in it.
    static let usualShare = 0.5
    /// Ranks past this aren't worth saying.
    static let rankLimit = 25

    /// The story of the song with this ``CaptureStat/songIdentity``, or nil if it's never been
    /// kept.
    ///
    /// - Parameter listeningSince: when the current listening started, so a play kept during
    ///   it doesn't count as the last time it was heard. Nil when it isn't playing.
    public static func story(
        of identity: String,
        in history: ListeningHistory,
        listeningSince: Date? = nil,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> SongStory? {
        let thisMonth = calendar.dateInterval(of: .month, for: now)
        guard let thisMonthStart = thisMonth?.start,
              let firstMonth = calendar.date(byAdding: .month, value: -11, to: thisMonthStart)
        else { return nil }

        var plays = 0
        var radioPlays = 0
        var first: CaptureStat?
        var lastBefore: Date?
        var monthly = [Int](repeating: 0, count: 12)
        var dayParts: [DayPart: Int] = [:]
        // Every song's plays this month, for the rank.
        var monthCounts: [String: Int] = [:]

        for capture in history.captures {
            if let thisMonth, thisMonth.contains(capture.capturedAt) {
                monthCounts[capture.songIdentity, default: 0] += 1
            }
            guard capture.songIdentity == identity else { continue }
            plays += 1
            if capture.kind == .radio { radioPlays += 1 }
            if first == nil { first = capture }
            if listeningSince.map({ capture.capturedAt < $0 }) ?? true {
                lastBefore = capture.capturedAt
            }
            if capture.capturedAt >= firstMonth,
               let months = calendar.dateComponents([.month], from: firstMonth, to: capture.capturedAt).month,
               monthly.indices.contains(months) {
                monthly[months] += 1
            }
            dayParts[DayPart(hour: calendar.component(.hour, from: capture.capturedAt)), default: 0] += 1
        }
        guard let first else { return nil }

        let months = monthly.enumerated().compactMap { offset, count in
            calendar.date(byAdding: .month, value: offset, to: firstMonth).map { SongStory.MonthPlays(start: $0, plays: count) }
        }
        return SongStory(
            plays: plays,
            radioPlays: radioPlays,
            firstHeard: first.capturedAt,
            firstStation: first.kind == .radio ? first.stationName.flatMap { $0.isEmpty ? nil : $0 } : nil,
            lastHeard: lastBefore,
            months: months,
            usualTime: usualTime(dayParts, plays: plays),
            rankThisMonth: rank(of: identity, in: monthCounts)
        )
    }

    /// The part of the day holding at least half the plays, once there are enough of them.
    static func usualTime(_ parts: [DayPart: Int], plays: Int) -> DayPart? {
        guard plays >= usualMinimumPlays,
              let top = parts.max(by: { ($0.value, $1.key.rawValue) < ($1.value, $0.key.rawValue) }),
              Double(top.value) / Double(plays) >= usualShare
        else { return nil }
        return top.key
    }

    /// 1 for the song played most this month. Ties share the better place, as charts do.
    static func rank(of identity: String, in counts: [String: Int]) -> Int? {
        guard let mine = counts[identity], mine > 0 else { return nil }
        let rank = counts.values.filter { $0 > mine }.count + 1
        return rank <= rankLimit ? rank : nil
    }
}
