import Foundation

/// Builds the Play tab's mixes from the listening history.
///
/// Pure and synchronous, so it runs off the main actor and the tests can pin every rule. Each
/// mix says why it holds what it holds (see ``MixKind``), leaves out songs the person skips or
/// asked to hear less of, and is only offered when it has enough songs to be worth playing.
public enum MixBuilder {
    /// Songs in a mix at most.
    public static let mixLength = 40
    /// Songs a mix needs before it's offered.
    public static let minimumSongs = 6
    /// The Right Now mix needs a few more: it leads the page.
    public static let minimumRightNowSongs = 8

    public struct Output: Sendable, Equatable {
        /// For the top of the page: what you play at this hour. Nil until the history shows a
        /// habit for it.
        public let rightNow: Mix?
        /// The rest of today's kind of day, from the next part of it on: what the top of the
        /// page can be swiped to.
        public let otherTimes: [Mix]
        /// The shelf, in the order it shows.
        public let mixes: [Mix]

        public init(rightNow: Mix?, otherTimes: [Mix] = [], mixes: [Mix]) {
            self.rightNow = rightNow
            self.otherTimes = otherTimes
            self.mixes = mixes
        }

        public static let empty = Output(rightNow: nil, mixes: [])

        public var all: [Mix] {
            [rightNow].compactMap(\.self) + otherTimes + mixes
        }

        public func mix(id: String) -> Mix? {
            all.first { $0.id == id }
        }
    }

    public static func build(
        from history: ListeningHistory,
        signals: ListeningSignals = ListeningSignals(),
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Output {
        guard !history.isEmpty else { return .empty }
        let songs = aggregate(history, signals: signals, now: now, calendar: calendar)
        guard !songs.isEmpty else { return .empty }

        let context = Context(songs: songs, history: history, now: now, calendar: calendar)
        let mixes = [
            onRepeat(context),
            newFinds(context),
            allTimeFavorites(context),
            deepCuts(context),
            radioFinds(context),
            rediscover(context),
            throwback(context),
        ].compactMap(\.self)

        let isWeekend = calendar.isDateInWeekend(now)
        let current = DayPart(hour: calendar.component(.hour, from: now))
        let later = DayPart.allCases.indices.map { DayPart.allCases[(current.rawValue + 1 + $0) % DayPart.allCases.count] }
            .filter { $0 != current }
        let otherTimes = later.compactMap { timeOfDay(context, part: $0, isWeekend: isWeekend) }
        return Output(rightNow: timeOfDay(context, part: current, isWeekend: isWeekend), otherTimes: otherTimes, mixes: mixes)
    }

    // MARK: - The mixes

    /// Plays at this part of the day on this kind of day (weekday or weekend), the last few
    /// months counting most. Leaves out what was heard in the last couple of hours.
    static func rightNow(_ context: Context) -> Mix? {
        timeOfDay(
            context,
            part: DayPart(hour: context.calendar.component(.hour, from: context.now)),
            isWeekend: context.calendar.isDateInWeekend(context.now)
        )
    }

    /// Plays at one part of the day, on weekdays or weekends.
    static func timeOfDay(_ context: Context, part: DayPart, isWeekend: Bool) -> Mix? {
        let halfLife: TimeInterval = 60 * day
        let recent = context.now.addingTimeInterval(-2 * 60 * 60)

        let wanted = Aggregate.slot(part, isWeekend: isWeekend)
        let scored = context.songs.compactMap { song -> (Aggregate, Double)? in
            guard song.lastHeard < recent else { return nil }
            var score = 0.0
            var matches = 0
            for (date, slot) in zip(song.dates, song.slots) where slot == wanted {
                matches += 1
                score += decay(context.now.timeIntervalSince(date), halfLife: halfLife)
            }
            return matches >= 2 ? (song, score) : nil
        }
        return mix(.rightNow(part, isWeekend: isWeekend), from: scored, context: context, minimum: minimumRightNowSongs)
    }

    /// The most played ever, favouring the ones still in rotation. A song needs five plays.
    static func allTimeFavorites(_ context: Context) -> Mix? {
        let scored = context.songs.compactMap { song -> (Aggregate, Double)? in
            guard song.dates.count >= 5 else { return nil }
            let stillPlayed = 0.5 + 0.5 * decay(context.now.timeIntervalSince(song.lastHeard), halfLife: 365 * day)
            return (song, Double(song.dates.count) * stillPlayed)
        }
        return mix(.allTimeFavorites, from: scored, context: context)
    }

    /// Songs heard once or twice, by the ten artists played most in the last six months, and
    /// not in the last month: the corners of favourite artists barely explored.
    static func deepCuts(_ context: Context) -> Mix? {
        let start = context.now.addingTimeInterval(-180 * day)
        var artistPlays: [String: Int] = [:]
        for song in context.songs {
            artistPlays[song.song.artistKey, default: 0] += song.dates.count { $0 >= start }
        }
        let top = artistPlays.filter { $0.value > 0 }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(10)
        let rank = Dictionary(uniqueKeysWithValues: top.enumerated().map { ($1.key, $0) })
        let recent = context.now.addingTimeInterval(-30 * day)

        let scored = context.songs.compactMap { song -> (Aggregate, Double)? in
            guard let position = rank[song.song.artistKey], (1...2).contains(song.dates.count),
                  song.lastHeard < recent
            else { return nil }
            // Better-loved artists first; within one, the most recently found.
            let recency = decay(context.now.timeIntervalSince(song.lastHeard), halfLife: 180 * day)
            return (song, Double(10 - position) + recency)
        }
        return mix(.deepCuts, from: scored, context: context)
    }

    /// The last thirty days, with the last two weeks counting most. A song needs three plays.
    static func onRepeat(_ context: Context) -> Mix? {
        let start = context.now.addingTimeInterval(-30 * day)
        let scored = context.songs.compactMap { song -> (Aggregate, Double)? in
            let dates = song.dates.filter { $0 >= start }
            guard dates.count >= 3 else { return nil }
            let score = dates.reduce(0) { $0 + decay(context.now.timeIntervalSince($1), halfLife: 10 * day) }
            return (song, score)
        }
        return mix(.onRepeat, from: scored, context: context)
    }

    /// First heard in the last thirty days, and played at least twice since.
    static func newFinds(_ context: Context) -> Mix? {
        let start = context.now.addingTimeInterval(-30 * day)
        let scored = context.songs.compactMap { song -> (Aggregate, Double)? in
            guard song.firstHeard >= start, song.dates.count >= 2 else { return nil }
            return (song, Double(song.dates.count))
        }
        return mix(.newFinds, from: scored, context: context)
    }

    /// Heard on a station and never chosen: no on-demand play and no recovered one either,
    /// since a recovered play may well have been on demand.
    static func radioFinds(_ context: Context) -> Mix? {
        let scored = context.songs.compactMap { song -> (Aggregate, Double)? in
            guard song.radioPlays > 0, song.radioPlays == song.dates.count else { return nil }
            // Heard more than once on the radio ranks first; then the most recent.
            let recency = decay(context.now.timeIntervalSince(song.lastHeard), halfLife: 30 * day)
            return (song, Double(song.radioPlays) + recency)
        }
        return mix(.radioFinds, from: scored, context: context)
    }

    /// Four plays or more, none in the last sixty days. Needs ninety days of history, or
    /// everything would look forgotten.
    static func rediscover(_ context: Context) -> Mix? {
        guard let first = context.history.first?.capturedAt,
              context.now.timeIntervalSince(first) >= 90 * day
        else { return nil }
        let cutoff = context.now.addingTimeInterval(-60 * day)
        let scored = context.songs.compactMap { song -> (Aggregate, Double)? in
            guard song.dates.count >= 4, song.lastHeard < cutoff else { return nil }
            // Loved more, and gone longer, both count; a song gone a year counts in full.
            let absence = min(1, context.now.timeIntervalSince(song.lastHeard) / (365 * day))
            return (song, Double(song.dates.count) * (0.5 + absence))
        }
        return mix(.rediscover, from: scored, context: context)
    }

    /// A week either side of this date, a year ago, or six or three months ago when the
    /// history doesn't reach back a year or that week was quiet.
    static func throwback(_ context: Context) -> Mix? {
        guard let first = context.history.first?.capturedAt else { return nil }
        for months in [12, 6, 3] {
            guard let around = context.calendar.date(byAdding: .month, value: -months, to: context.now),
                  around.addingTimeInterval(-7 * day) >= first
            else { continue }
            let window = DateInterval(start: around.addingTimeInterval(-7 * day), end: around.addingTimeInterval(7 * day))
            let scored = context.songs.compactMap { song -> (Aggregate, Double)? in
                let inWindow = song.dates.count { window.contains($0) }
                return inWindow > 0 ? (song, Double(inWindow)) : nil
            }
            if let mix = mix(.throwback(monthsAgo: months, around: around), from: scored, context: context) {
                return mix
            }
        }
        return nil
    }

    // MARK: - Assembly

    /// The top ``mixLength`` by score, sequenced for the day.
    private static func mix(
        _ kind: MixKind,
        from scored: [(Aggregate, Double)],
        context: Context,
        minimum: Int = minimumSongs
    ) -> Mix? {
        guard scored.count >= minimum else { return nil }
        let top = scored
            .sorted { $0.1 == $1.1 ? $0.0.identity < $1.0.identity : $0.1 > $1.1 }
            .prefix(mixLength)
            .map(\.0)
        let songs = top.map(\.song)
        let ordered = FreshShuffle.order(
            songs,
            artist: \.artistKey,
            seed: FreshShuffle.dailySeed(for: context.now, calendar: context.calendar, salt: kind.id)
        )
        return Mix(kind: kind, songs: ordered, playCount: top.reduce(0) { $0 + $1.dates.count })
    }

    private static func decay(_ age: TimeInterval, halfLife: TimeInterval) -> Double {
        pow(0.5, max(0, age) / halfLife)
    }

    private static let day: TimeInterval = 24 * 60 * 60

    // MARK: - Per song

    struct Aggregate {
        let identity: String
        var song: MixSong
        /// Every play, oldest first.
        var dates: [Date]
        /// The part of the day and kind of day of each play, alongside ``dates``, worked out
        /// once rather than by every time-of-day mix.
        var slots: [UInt8]
        /// The hour and kind of day of each play, alongside ``dates``: `hour * 2`, plus one on
        /// a weekend. For Tracks Radio following the time of day.
        var hours: [UInt8]
        var radioPlays: Int

        static func slot(_ part: DayPart, isWeekend: Bool) -> UInt8 {
            UInt8(part.rawValue * 2 + (isWeekend ? 1 : 0))
        }

        static func hourSlot(_ hour: Int, isWeekend: Bool) -> UInt8 {
            UInt8(hour * 2 + (isWeekend ? 1 : 0))
        }
        var firstHeard: Date { dates.first ?? song.lastHeard }
        var lastHeard: Date { song.lastHeard }
    }

    /// One entry per song, with the newest spelling, id and cover any of its plays had.
    static func aggregate(
        _ history: ListeningHistory,
        signals: ListeningSignals,
        now: Date,
        calendar: Calendar
    ) -> [Aggregate] {
        var byIdentity: [String: Aggregate] = [:]
        for capture in history.captures {
            let identity = capture.songIdentity
            let hour = calendar.component(.hour, from: capture.capturedAt)
            let isWeekend = calendar.isDateInWeekend(capture.capturedAt)
            let slot = Aggregate.slot(DayPart(hour: hour), isWeekend: isWeekend)
            let hourSlot = Aggregate.hourSlot(hour, isWeekend: isWeekend)
            if var existing = byIdentity[identity] {
                existing.dates.append(capture.capturedAt)
                existing.slots.append(slot)
                existing.hours.append(hourSlot)
                if capture.kind == .radio { existing.radioPlays += 1 }
                let song = existing.song
                existing.song = MixSong(
                    songIdentity: identity,
                    songID: capture.songID.isEmpty ? song.songID : capture.songID,
                    title: capture.title,
                    artistName: capture.artistName,
                    albumTitle: capture.albumTitle ?? song.albumTitle,
                    artworkURL: capture.artworkURL ?? song.artworkURL,
                    plays: existing.dates.count,
                    lastHeard: capture.capturedAt
                )
                byIdentity[identity] = existing
            } else {
                byIdentity[identity] = Aggregate(
                    identity: identity,
                    song: MixSong(
                        songIdentity: identity,
                        songID: capture.songID,
                        title: capture.title,
                        artistName: capture.artistName,
                        albumTitle: capture.albumTitle,
                        artworkURL: capture.artworkURL,
                        plays: 1,
                        lastHeard: capture.capturedAt
                    ),
                    dates: [capture.capturedAt],
                    slots: [slot],
                    hours: [hourSlot],
                    radioPlays: capture.kind == .radio ? 1 : 0
                )
            }
        }
        return byIdentity.values.filter { !signals.excludes($0.identity, now: now) }
    }

    /// Everything the mixes share, worked out once.
    struct Context {
        let songs: [Aggregate]
        let history: ListeningHistory
        let now: Date
        let calendar: Calendar

    }
}
