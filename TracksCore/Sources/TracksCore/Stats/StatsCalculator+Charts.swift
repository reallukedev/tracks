import Foundation

// Top Songs / Artists / Albums, with movement against the previous period.
extension StatsCalculator {

    public static func songChart(
        range: StatsRange,
        history: ListeningHistory,
        calendar: Calendar = .current,
        now: Date = .now,
        limit: Int = 100
    ) -> [Ranked<SongTally>] {
        chart(range: range, history: history, calendar: calendar, now: now, limit: limit) {
            tallySongs($0, in: history)
        }
    }

    public static func artistChart(
        range: StatsRange,
        history: ListeningHistory,
        calendar: Calendar = .current,
        now: Date = .now,
        limit: Int = 100
    ) -> [Ranked<ArtistTally>] {
        chart(range: range, history: history, calendar: calendar, now: now, limit: limit) {
            tallyArtists($0, in: history)
        }
    }

    public static func albumChart(
        range: StatsRange,
        history: ListeningHistory,
        calendar: Calendar = .current,
        now: Date = .now,
        limit: Int = 100
    ) -> [Ranked<AlbumTally>] {
        chart(range: range, history: history, calendar: calendar, now: now, limit: limit) {
            tallyAlbums($0, in: history)
        }
    }

    /// The songs of one day, week, month or year, with movement against the period before.
    public static func songChart(
        in period: ChartPeriod,
        history: ListeningHistory,
        calendar: Calendar = .current,
        limit: Int = 100
    ) -> [Ranked<SongTally>] {
        chart(period.interval, previous: period.previous(calendar: calendar)?.interval, history: history, limit: limit) {
            tallySongs($0, in: history)
        }
    }

    /// The artists of one day, week, month or year, with movement against the period before.
    public static func artistChart(
        in period: ChartPeriod,
        history: ListeningHistory,
        calendar: Calendar = .current,
        limit: Int = 100
    ) -> [Ranked<ArtistTally>] {
        chart(period.interval, previous: period.previous(calendar: calendar)?.interval, history: history, limit: limit) {
            tallyArtists($0, in: history)
        }
    }

    /// The albums of one day, week, month or year, with movement against the period before.
    public static func albumChart(
        in period: ChartPeriod,
        history: ListeningHistory,
        calendar: Calendar = .current,
        limit: Int = 100
    ) -> [Ranked<AlbumTally>] {
        chart(period.interval, previous: period.previous(calendar: calendar)?.interval, history: history, limit: limit) {
            tallyAlbums($0, in: history)
        }
    }

    static func chart<Item: TallyCountable>(
        range: StatsRange,
        history: ListeningHistory,
        calendar: Calendar,
        now: Date,
        limit: Int,
        tally: (Range<Int>) -> [Item]
    ) -> [Ranked<Item>] {
        let interval = range.interval(containing: now, calendar: calendar)
        let previous = interval.flatMap { range.previousInterval(before: $0, calendar: calendar) }
        return chart(interval, previous: previous, history: history, limit: limit, tally: tally)
    }

    /// Movement is measured against the whole previous period (last week's final chart),
    /// unlike the Summary comparison, and for a period still under way too. If the previous
    /// period was empty we show no movement rather than marking everything new.
    static func chart<Item: TallyCountable>(
        _ interval: DateInterval?,
        previous: DateInterval?,
        history: ListeningHistory,
        limit: Int,
        tally: (Range<Int>) -> [Item]
    ) -> [Ranked<Item>] {
        let current = tally(history.indices(in: interval))

        let previousRanks: [Item.ID: Int]?
        if interval != nil, let previous {
            let items = tally(history.indices(in: previous))
            previousRanks = items.isEmpty ? nil : Dictionary(
                zip(items.map(\.id), competitionRanks(items.map(\.count))),
                uniquingKeysWith: { first, _ in first }
            )
        } else {
            previousRanks = nil
        }

        let ranks = competitionRanks(current.map(\.count))
        return zip(current, ranks).prefix(limit).map { item, rank in
            Ranked(
                item: item,
                rank: rank,
                previousRank: previousRanks?[item.id],
                hasPrevious: previousRanks != nil
            )
        }
    }

    /// Competition ranking ("1, 2, 2, 2, 5") over counts sorted high to low.
    static func competitionRanks(_ counts: [Int]) -> [Int] {
        var ranks: [Int] = []
        ranks.reserveCapacity(counts.count)
        for (index, count) in counts.enumerated() {
            if index > 0, counts[index - 1] == count {
                ranks.append(ranks[index - 1])
            } else {
                ranks.append(index + 1)
            }
        }
        return ranks
    }
}

protocol TallyCountable: Sendable, Equatable, Identifiable where ID: Sendable {
    var count: Int { get }
}

extension SongTally: TallyCountable {}
extension ArtistTally: TallyCountable {}
extension AlbumTally: TallyCountable {}
