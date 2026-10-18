import Foundation

/// How a chart's period went, as its page draws it: listening spread across the period's
/// hours, days, months or years, and the few numbers worth saying about it.
public struct PeriodActivity: Sendable, Equatable {
    /// One bar: an hour of a day, a day of a week or month, a month of a year, a year of all
    /// time.
    public struct Bucket: Sendable, Equatable, Identifiable {
        public let start: Date
        public let end: Date
        public let plays: Int
        public let seconds: TimeInterval

        public var id: Date { start }

        public init(start: Date, end: Date, plays: Int, seconds: TimeInterval) {
            self.start = start
            self.end = end
            self.plays = plays
            self.seconds = seconds
        }
    }

    public let buckets: [Bucket]
    /// What a bar is, so a click on one can open it: nil for a day's hours, which open nothing.
    public let bucketSpan: ChartSpan?
    public let plays: Int
    public let seconds: TimeInterval
    public let songs: Int
    public let artists: Int
    public let albums: Int
    /// Songs heard for the first time ever in the period.
    public let newSongs: Int
    /// The artists heard for the first time ever in the period, by ``CaptureStat/artistIdentity``.
    public let newArtists: Set<String>
    /// Plays in the period before, to say how this one compares. Nil for all time.
    ///
    /// While this period is under way, only the part of the one before that it has caught up
    /// with: Thursday evening against last week up to Thursday evening.
    public let previousPlays: Int?
    /// Listening in the same stretch of the period before as ``previousPlays``.
    public let previousSeconds: TimeInterval?

    public init(
        buckets: [Bucket],
        bucketSpan: ChartSpan?,
        plays: Int,
        seconds: TimeInterval,
        songs: Int,
        artists: Int,
        albums: Int,
        newSongs: Int,
        newArtists: Set<String> = [],
        previousPlays: Int?,
        previousSeconds: TimeInterval? = nil
    ) {
        self.buckets = buckets
        self.bucketSpan = bucketSpan
        self.plays = plays
        self.seconds = seconds
        self.songs = songs
        self.artists = artists
        self.albums = albums
        self.newSongs = newSongs
        self.newArtists = newArtists
        self.previousPlays = previousPlays
        self.previousSeconds = previousSeconds
    }

    /// The busiest bar's plays, so the bars share one scale. Never zero.
    public var busiest: Int { max(1, buckets.map(\.plays).max() ?? 1) }

    /// The change in listening time against the period before, as a fraction: 0.25 for a
    /// quarter more. Seconds rather than plays, so a run of skipped songs isn't more
    /// listening. While this period is under way, against the period before up to the same
    /// point, as ``previousPlays`` says. Nil with nothing to compare against.
    public var change: Double? {
        guard let previousSeconds, previousSeconds > 0 else { return nil }
        return (seconds - previousSeconds) / previousSeconds
    }
}

extension ChartSpan {
    /// What a period of this span is split into for its bars.
    var bucketComponent: Calendar.Component {
        switch self {
        case .day: .hour
        case .week, .month: .day
        case .year: .month
        case .allTime: .year
        }
    }

    /// The span a bar opens as: a week's or a month's day, a year's month, all time's year.
    var bucketSpan: ChartSpan? {
        switch self {
        case .day: nil
        case .week, .month: .day
        case .year: .month
        case .allTime: .year
        }
    }
}

extension ListeningHistory {
    /// The period's listening, bar by bar, with its totals.
    ///
    /// Bars follow the calendar: a day the clocks change has 23 or 25 hours, and all time
    /// runs from the year of the first play to this one. A period still under way has its
    /// later bars, empty, so the week still reads as seven days.
    public func activity(in period: ChartPeriod, now: Date = .now, calendar: Calendar = .current) -> PeriodActivity {
        let range = indices(in: period.interval)
        let component = period.span.bucketComponent

        let whole: DateInterval? = period.interval ?? first.map { first in
            let start = calendar.dateInterval(of: .year, for: first.capturedAt)?.start ?? first.capturedAt
            let end = calendar.dateInterval(of: .year, for: max(now, captures.last?.capturedAt ?? now))?.end ?? now
            return DateInterval(start: start, end: end)
        }

        var buckets: [PeriodActivity.Bucket] = []
        if let whole {
            var cursor = whole.start
            var index = range.lowerBound
            while cursor < whole.end {
                let next = calendar.dateInterval(of: component, for: cursor)?.end ?? whole.end
                let end = min(next, whole.end)
                var plays = 0
                var seconds: TimeInterval = 0
                while index < range.upperBound, captures[index].capturedAt < end {
                    if captures[index].capturedAt >= cursor {
                        plays += 1
                        seconds += self.seconds[index]
                    }
                    index += 1
                }
                buckets.append(.init(start: cursor, end: end, plays: plays, seconds: seconds))
                guard end > cursor else { break }
                cursor = end
            }
        }

        var songs = Set<String>()
        var artists = Set<String>()
        var albums = Set<String>()
        var newSongs = 0
        var newArtists = Set<String>()
        var seconds: TimeInterval = 0
        for index in range {
            let capture = captures[index]
            songs.insert(capture.songIdentity)
            artists.formUnion(capture.creditIdentities)
            if let album = capture.albumIdentity { albums.insert(album) }
            if isFirstHearing[index] { newSongs += 1 }
            newArtists.formUnion(self.newArtists[index])
            seconds += self.seconds[index]
        }

        let previous = comparison(for: period, now: now, calendar: calendar).map { indices(in: $0) }
        return PeriodActivity(
            buckets: buckets,
            bucketSpan: period.span.bucketSpan,
            plays: range.count,
            seconds: seconds,
            songs: songs.count,
            artists: artists.count,
            albums: albums.count,
            newSongs: newSongs,
            newArtists: newArtists,
            previousPlays: previous?.count,
            previousSeconds: previous.map { $0.reduce(0) { $0 + self.seconds[$1] } }
        )
    }

    /// The stretch of the period before `period` to compare it with: all of it, or while
    /// `period` is under way, as far into it as `period` has got.
    func comparison(for period: ChartPeriod, now: Date, calendar: Calendar) -> DateInterval? {
        guard let previous = period.previous(calendar: calendar)?.interval else { return nil }
        guard let current = period.interval, period.isCurrent(now: now) else { return previous }
        let elapsed = now.timeIntervalSince(current.start)
        return DateInterval(start: previous.start, end: min(previous.end, previous.start.addingTimeInterval(elapsed)))
    }
}
