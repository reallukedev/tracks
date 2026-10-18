import Foundation

/// Inputs for `insights(_:)`.
struct InsightContext {
    let range: StatsRange
    let interval: DateInterval?
    let history: ListeningHistory
    let indices: Range<Int>
    let inRange: [CaptureStat]
    let sessions: [SessionStat]
    let listeningSeconds: TimeInterval
    let previousListeningSeconds: TimeInterval?
    let firstTimeHeardCount: Int
    let newArtistCount: Int
    let topSongs: [SongTally]
    let topArtists: [ArtistTally]
    let uniqueArtistCount: Int
    let streak: Streak
    let genres: GenreFigures
    let calendar: Calendar

    /// In someone's first week everything is new, so the discovery highlights would be
    /// meaningless. They need some earlier history to compare against.
    var hasHistoryBeforeRange: Bool {
        guard let interval, let first = history.first else { return false }
        return first.capturedAt < interval.start
    }
}

extension StatsCalculator {
    static let milestones = [100, 250, 500, 1_000, 2_500, 5_000, 10_000, 25_000, 50_000, 100_000]

    /// Highlights for the range, most interesting first. Each one has a threshold so we
    /// don't announce a "habit" based on three songs.
    static func insights(_ context: InsightContext) -> [Insight] {
        let inRange = context.inRange
        let total = inRange.count
        guard total >= 3 else { return [] }
        let calendar = context.calendar
        var insights: [Insight] = []

        // Largest milestone passed inside this range.
        let captures = context.history.captures
        if let milestone = milestones.last(where: { threshold in
            threshold <= captures.count && context.indices.contains(threshold - 1)
        }) {
            insights.append(.milestone(count: milestone, reachedOn: captures[milestone - 1].capturedAt))
        }

        if context.streak.current >= 3 {
            insights.append(.streak(days: context.streak.current))
        }

        // Needs half an hour on both sides, otherwise 10 min vs 40 min becomes "+300%".
        if context.range != .allTime,
           let previous = context.previousListeningSeconds, previous >= 1_800,
           context.listeningSeconds >= 1_800 {
            let percent = Int(((context.listeningSeconds - previous) / previous * 100).rounded())
            if abs(percent) >= 10 {
                insights.append(.listeningTrend(percent: percent, range: context.range))
            }
        }

        // One pass for everything that depends on when a play was. Each fact is worked out
        // once per day rather than once per play (see `DayClock`), and plays are counted
        // rather than gathered into arrays.
        var clock = DayClock(calendar: calendar)
        var repeats: [DayAndSong: (count: Int, latest: CaptureStat)] = [:]
        var hours: [Int: Int] = [:]
        var dates = Set<Date>()
        var weekend = 0
        var byWeekday: [Int: Int] = [:]
        var stations: [String: Int] = [:]
        var stationIsBlank: [String: Bool] = [:]
        for capture in inRange {
            if let name = capture.stationName {
                let isBlank = stationIsBlank[name] ?? {
                    let blank = folded(name).isEmpty
                    stationIsBlank[name] = blank
                    return blank
                }()
                if !isBlank { stations[name, default: 0] += 1 }
            }
            guard let facts = clock.facts(for: capture.capturedAt) else { continue }
            let key = DayAndSong(day: facts.day.start, song: capture.songIdentity)
            // `inRange` is oldest first, so the last play seen is the latest.
            repeats[key] = ((repeats[key]?.count ?? 0) + 1, capture)
            hours[facts.hour, default: 0] += 1
            dates.insert(facts.day.start)
            if facts.isWeekend { weekend += 1 }
            byWeekday[facts.weekday, default: 0] += 1
        }

        // Ties go to the earlier day, then the song, so the pick doesn't follow dictionary order.
        let onRepeat = repeats.max {
            ($0.value.count, $1.key.day, $1.key.song) < ($1.value.count, $0.key.day, $0.key.song)
        }
        if let onRepeat, onRepeat.value.count >= 3 {
            insights.append(.onRepeat(
                title: onRepeat.value.latest.title,
                artistName: onRepeat.value.latest.artistName,
                count: onRepeat.value.count,
                day: onRepeat.key.day
            ))
        }

        if context.uniqueArtistCount >= 3, let top = context.topArtists.first, top.count >= 5 {
            let share = Double(top.count) / Double(total)
            if share >= 0.15 {
                insights.append(.topArtistShare(
                    name: top.name,
                    percent: Int((share * 100).rounded()),
                    count: top.count
                ))
            }
        }

        // Out of the plays with a known genre, and only with a few genres to choose from, or
        // someone who only plays one kind of music hears the obvious.
        let genres = context.genres
        if genres.knownGenrePlays >= 10, genres.genreCount >= 3, let top = genres.topGenres.first {
            let share = Double(top.count) / Double(genres.knownGenrePlays)
            if share >= 0.3 {
                insights.append(.topGenre(name: top.name, percent: Int((share * 100).rounded())))
            }
        }

        if genres.knownYearPlays >= 10, genres.decades.count(where: { $0.count > 0 }) >= 2,
           let top = genres.decades.max(by: { ($0.count, $1.decade) < ($1.count, $0.decade) }) {
            let share = Double(top.count) / Double(genres.knownYearPlays)
            if share >= 0.5 {
                insights.append(.favouriteDecade(decade: top.decade, percent: Int((share * 100).rounded())))
            }
        }

        if context.hasHistoryBeforeRange, context.newArtistCount >= 3 {
            insights.append(.newArtists(count: context.newArtistCount))
        }

        if context.hasHistoryBeforeRange, total >= 4 {
            if context.firstTimeHeardCount == total {
                insights.append(.allNew(count: total))
            } else if total >= 10 {
                let share = Double(context.firstTimeHeardCount) / Double(total)
                if share >= 0.5 {
                    insights.append(.mostlyNew(percent: Int((share * 100).rounded())))
                }
            }
        }

        // Twenty songs minimum, so one late night doesn't make someone a night owl.
        func share(_ range: [Int]) -> Double {
            Double(range.reduce(0) { $0 + (hours[$1] ?? 0) }) / Double(total)
        }
        var persona: ListeningPersona?
        if total >= 20 {
            let night = share([22, 23, 0, 1, 2, 3])
            let morning = share([5, 6, 7, 8])
            if night >= 0.35 {
                persona = .nightOwl
                insights.append(.persona(.nightOwl, percent: Int((night * 100).rounded())))
            } else if morning >= 0.3 {
                persona = .earlyBird
                insights.append(.persona(.earlyBird, percent: Int((morning * 100).rounded())))
            }
        }

        // Three-hour blocks are steadier than single hours with this little data.
        if persona == nil {
            var byPart: [Int: Int] = [:]
            for (hour, count) in hours { byPart[hour / 3, default: 0] += count }
            if byPart.count > 1, let top = byPart.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), top.value >= 3 {
                insights.append(.busiestHour(hour: top.key * 3, count: top.value))
            }
        }

        // Weekends are ~29% of the week, so half the listening there is worth mentioning.
        // Skipped for a single week, where the chart already shows it.
        if context.range != .week, total >= 20, dates.count >= 7 {
            let share = Double(weekend) / Double(total)
            if share >= 0.5 {
                insights.append(.weekendListener(percent: Int((share * 100).rounded())))
            }
        }

        // Needs more than one date (not more than one weekday: someone who only listens
        // on Mondays does have a habit), so a single afternoon isn't called a pattern.
        if context.range != .week, dates.count > 1,
           let top = byWeekday.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }),
           top.value * 2 > total {
            insights.append(.busiestDay(weekday: top.key, count: top.value))
        }

        // Only with two or more stations; one station at 100% isn't interesting.
        let radioWithStation = stations.values.reduce(0, +)
        if stations.count > 1, let top = stations.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }),
           top.value * 2 > radioWithStation {
            insights.append(.dominantStation(name: top.key, count: top.value, total: radioWithStation))
        }

        // Skip if "on repeat" already covers this song.
        if let top = context.topSongs.first, top.count > 1,
           onRepeat.map({ $0.key.song != top.id || $0.value.count < 3 }) ?? true {
            insights.append(.repeatedSong(title: top.title, artistName: top.artistName, count: top.count))
        }

        // Only the part inside the range, as the listening totals count it.
        if let longest = context.sessions.map({ session in
            context.interval.map { overlap(of: session, with: $0) ?? 0 }
                ?? max(0, session.finishedAt.timeIntervalSince(session.startedAt))
        }).max(), longest >= 600 {
            insights.append(.longestSession(minutes: Int(longest / 60)))
        }

        // Play Back only applies to radio songs.
        let radio = inRange.count { $0.kind == .radio }
        let played = inRange.count { $0.kind == .radio && $0.playedBackAt != nil }
        if played > 0 {
            insights.append(.playedBack(count: played, total: radio))
        }

        return insights
    }

    private struct DayAndSong: Hashable {
        let day: Date
        let song: String
    }
}
