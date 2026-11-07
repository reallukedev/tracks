import Foundation

// The deeper figures under the Summary's headline: sessions, parts of the day, pace against
// last period, new favourites and records.
extension StatsCalculator {

    // MARK: - Sessions

    /// Splits the range into sessions wherever the gap between songs is longer than a song
    /// could plausibly be. Recovered songs are left out: they're timestamped when Tracks found
    /// them, often dozens at once, so their gaps say nothing about when anything played.
    static func listeningSessions(_ indices: Range<Int>, in history: ListeningHistory) -> SessionStats {
        var sessions: [ListeningSession] = []
        var start: Date?
        var last: Date?
        var seconds: TimeInterval = 0
        var songs = 0

        func close() {
            if let start, songs > 0 {
                sessions.append(ListeningSession(start: start, seconds: seconds, songCount: songs))
            }
        }

        for index in indices {
            let capture = history.captures[index]
            guard capture.kind.timeIsKnown else { continue }
            if let last, capture.capturedAt.timeIntervalSince(last) > ListeningEstimate.longestPlausibleGap {
                close()
                start = nil
            }
            if start == nil {
                start = capture.capturedAt
                seconds = 0
                songs = 0
            }
            seconds += history.seconds[index]
            songs += 1
            last = capture.capturedAt
        }
        close()

        guard !sessions.isEmpty else { return .none }
        let byLength = Dictionary(grouping: sessions) { SessionLength(seconds: $0.seconds) }
        return SessionStats(
            count: sessions.count,
            totalSeconds: sessions.reduce(0) { $0 + $1.seconds },
            totalSongs: sessions.reduce(0) { $0 + $1.songCount },
            // Ties go to the most recent.
            longest: sessions.max { ($0.seconds, $0.start) < ($1.seconds, $1.start) },
            lengths: SessionLength.allCases.map {
                SessionLengthCount(length: $0, count: byLength[$0]?.count ?? 0)
            }
        )
    }

    // MARK: - Parts of the day

    /// All four parts, empty ones included, morning first.
    static func dayParts(_ indices: Range<Int>, in history: ListeningHistory, calendar: Calendar) -> [DayPartCount] {
        var counts: [DayPart: (count: Int, seconds: TimeInterval)] = [:]
        var clock = DayClock(calendar: calendar)
        for index in indices {
            guard let hour = clock.facts(for: history.captures[index].capturedAt)?.hour else { continue }
            let part = DayPart(hour: hour)
            counts[part, default: (0, 0)].count += 1
            counts[part, default: (0, 0)].seconds += history.seconds[index]
        }
        return DayPart.allCases.map {
            DayPartCount(part: $0, count: counts[$0]?.count ?? 0, seconds: counts[$0]?.seconds ?? 0)
        }
    }

    /// Listening per weekday and per weekend day, averaged over the days of each kind that
    /// have happened so far. `nil` for a kind with no days yet, like the weekend on a Tuesday.
    static func dayTypeAverages(
        _ indices: Range<Int>,
        in history: ListeningHistory,
        range: StatsRange,
        interval: DateInterval?,
        calendar: Calendar,
        now: Date
    ) -> (weekday: TimeInterval?, weekend: TimeInterval?) {
        guard let first = interval?.start ?? history.first?.capturedAt else { return (nil, nil) }
        let last = min(now, interval?.end.addingTimeInterval(-1) ?? now)
        guard last >= first else { return (nil, nil) }

        var weekdayDays = 0
        var weekendDays = 0
        var cursor = calendar.startOfDay(for: first)
        let lastDay = calendar.startOfDay(for: last)
        while cursor <= lastDay {
            if calendar.isDateInWeekend(cursor) { weekendDays += 1 } else { weekdayDays += 1 }
            // The day's end, not a day added: see `timeline`.
            guard let next = calendar.dateInterval(of: .day, for: cursor)?.end, next > cursor else { break }
            cursor = next
        }

        var weekdaySeconds: TimeInterval = 0
        var weekendSeconds: TimeInterval = 0
        // Whether a play is at the weekend depends only on its day, so it's asked once a day.
        var days = CalendarUnitCursor(calendar: calendar, unit: .day)
        var weekendDay: (start: Date, isWeekend: Bool)?
        for index in indices {
            let capturedAt = history.captures[index].capturedAt
            let dayStart = days.start(of: capturedAt) ?? capturedAt
            if weekendDay?.start != dayStart {
                weekendDay = (dayStart, calendar.isDateInWeekend(capturedAt))
            }
            if weekendDay?.isWeekend == true {
                weekendSeconds += history.seconds[index]
            } else {
                weekdaySeconds += history.seconds[index]
            }
        }
        return (
            weekdayDays > 0 ? weekdaySeconds / Double(weekdayDays) : nil,
            weekendDays > 0 ? weekendSeconds / Double(weekendDays) : nil
        )
    }

    // MARK: - Pace

    /// Running totals across the range, beside last period's at the same point. Last period
    /// is only drawn when there's history from before this one began, and a shorter period
    /// (February, next to March) holds its final total for the days it didn't have.
    static func pace(
        timeline: [TimeBucket],
        range: StatsRange,
        interval: DateInterval?,
        history: ListeningHistory,
        unit: Calendar.Component,
        calendar: Calendar,
        now: Date
    ) -> [PacePoint] {
        var previous: [TimeInterval] = []
        if let interval,
           comparisonInterval(for: range, history: history, calendar: calendar, now: now) != nil,
           let last = range.previousInterval(before: interval, calendar: calendar) {
            var total: TimeInterval = 0
            previous = self.timeline(history.indices(in: last), in: history, unit: unit, span: last, calendar: calendar)
                .map { bucket in
                    total += bucket.seconds
                    return total
                }
        }

        var total: TimeInterval = 0
        return timeline.enumerated().map { offset, bucket in
            total += bucket.seconds
            return PacePoint(
                start: bucket.start,
                current: bucket.start <= now ? total : nil,
                previous: previous.isEmpty ? nil : previous[min(offset, previous.count - 1)]
            )
        }
    }

    // MARK: - Discovery

    /// Songs first heard in the range and played again since, most played first. The ones
    /// that stuck, rather than everything that happened to come on once.
    static func newFavourites(
        _ indices: Range<Int>,
        firstHearings: [Int],
        in history: ListeningHistory,
        limit: Int
    ) -> [SongTally] {
        let discovered = Set(firstHearings.map { history.captures[$0].songIdentity })
        guard !discovered.isEmpty else { return [] }
        let plays = indices.filter { discovered.contains(history.captures[$0].songIdentity) }
        return Array(tallySongs(plays, in: history).filter { $0.count > 1 }.prefix(limit))
    }

    /// The artist with the most different songs, if anyone reached three.
    static func deepestArtist(in artists: [ArtistTally]) -> ArtistTally? {
        artists
            .filter { $0.songCount >= 3 }
            .max { ($0.songCount, $0.count, $1.name) < ($1.songCount, $1.count, $0.name) }
    }

    // MARK: - Records

    /// Seconds past midnight on the clock, for a date inside `day`.
    ///
    /// On a day the clocks don't change, that's simply the time since the day began, which
    /// saves asking the calendar for the hour, minute and second of every play. On the two
    /// days a year they do change, the calendar is asked.
    static func clockSeconds(of date: Date, in day: DateInterval, calendar: Calendar) -> Int {
        clockSeconds(of: date, in: day, isSteady: DayClock.isSteady(day, calendar: calendar), calendar: calendar)
    }

    /// The same, with ``DayClock/isSteady(_:calendar:)`` already worked out for `day`.
    static func clockSeconds(of date: Date, in day: DateInterval, isSteady: Bool, calendar: Calendar) -> Int {
        if isSteady {
            return Int(date.timeIntervalSince(day.start))
        }
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return (parts.hour ?? 0) * 3_600 + (parts.minute ?? 0) * 60 + (parts.second ?? 0)
    }

    static func records(
        _ indices: Range<Int>,
        in history: ListeningHistory,
        longestSession: ListeningSession?,
        calendar: Calendar
    ) -> ListeningRecords {
        struct Day {
            var seconds: TimeInterval = 0
            var songs = 0
            var artists = Set<String>()
            var plays: [String: (count: Int, capture: CaptureStat)] = [:]
        }

        var days: [Date: Day] = [:]
        // Seconds after 5 AM, so the small hours count as late rather than early.
        var latest: (offset: Int, date: Date)?
        var earliest: (offset: Int, date: Date)?

        var dayCursor = CalendarUnitCursor(calendar: calendar, unit: .day)
        var steadyDay: (start: Date, isSteady: Bool)?
        for index in indices {
            let capture = history.captures[index]
            guard let day = dayCursor.interval(containing: capture.capturedAt) else { continue }
            let dayStart = day.start
            if steadyDay?.start != dayStart {
                steadyDay = (dayStart, DayClock.isSteady(day, calendar: calendar))
            }
            days[dayStart, default: Day()].seconds += history.seconds[index]
            days[dayStart, default: Day()].songs += 1
            days[dayStart, default: Day()].artists.formUnion(capture.creditIdentities)
            let previousPlays = days[dayStart]?.plays[capture.songIdentity]?.count ?? 0
            days[dayStart, default: Day()].plays[capture.songIdentity] = (previousPlays + 1, capture)

            // Recovered songs carry the time Tracks found them, not when they played.
            guard capture.kind.timeIsKnown else { continue }
            let sinceMidnight = clockSeconds(
                of: capture.capturedAt, in: day, isSteady: steadyDay?.isSteady ?? false, calendar: calendar
            )
            let offset = (sinceMidnight - 5 * 3_600 + 86_400) % 86_400
            // `>=` and `<=` so ties go to the most recent.
            if latest.map({ offset >= $0.offset }) ?? true { latest = (offset, capture.capturedAt) }
            if earliest.map({ offset <= $0.offset }) ?? true { earliest = (offset, capture.capturedAt) }
        }

        func record(_ entry: (key: Date, value: Day)) -> DayRecord {
            DayRecord(
                day: entry.key,
                seconds: entry.value.seconds,
                songCount: entry.value.songs,
                artistCount: entry.value.artists.count
            )
        }

        // Ties go to the most recent day.
        let biggest = days.max { ($0.value.seconds, $0.key) < ($1.value.seconds, $1.key) }
        let widest = days.max { ($0.value.artists.count, $0.key) < ($1.value.artists.count, $1.key) }
        let repeated = days.compactMap { day, entry -> RepeatRecord? in
            guard let top = entry.plays.max(by: { ($0.value.count, $0.key) < ($1.value.count, $1.key) }) else { return nil }
            return RepeatRecord(
                songID: top.key,
                title: top.value.capture.title,
                artistName: top.value.capture.artistName,
                count: top.value.count,
                day: day
            )
        }
        .max { ($0.count, $0.day) < ($1.count, $1.day) }

        return ListeningRecords(
            biggestDay: biggest.map(record),
            mostArtistsDay: widest.flatMap { $0.value.artists.count >= 3 ? record($0) : nil },
            mostRepeated: repeated.flatMap { $0.count >= 2 ? $0 : nil },
            longestSession: longestSession,
            latestListen: latest?.date,
            earliestListen: earliest?.date
        )
    }
}
