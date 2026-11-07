import SwiftUI
import TracksCore

/// One chart as its page shows it: the period, its entries, and the nearest periods either
/// side that have listening in them.
nonisolated struct ChartSnapshot: Equatable, Sendable {
    let kind: ChartKind
    let period: ChartPeriod
    let scope: SourceScope
    let entries: [ChartEntry]
    /// Plays in the period, for the line under its title.
    let playCount: Int
    /// The period's songs in chart order, for Play and Shuffle whichever chart is on show.
    let songs: [MixSong]
    /// The latest earlier period with listening, passing over empty ones.
    let earlier: ChartPeriod?
    /// The earliest later period with listening, or the current one when nothing's been
    /// played since. Nil on the current period.
    let later: ChartPeriod?
    /// Whether anything at all has been played, to tell a quiet day from a new history.
    let hasHistory: Bool
    /// The period's listening bar by bar, with its totals.
    let activity: PeriodActivity

    /// What makes two snapshots the same chart, so only new listening in it animates.
    var identity: String {
        "\(kind.rawValue)|\(period.span.rawValue)|\(period.interval?.start.timeIntervalSinceReferenceDate ?? 0)|\(scope.rawValue)"
    }

    static func make(
        kind: ChartKind,
        period: ChartPeriod,
        scope: SourceScope,
        history: ListeningHistory,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> ChartSnapshot {
        // Every song of the period, so an artist or album whose songs each rank low still
        // has them to play.
        let allSongs = StatsCalculator.songChart(in: period, history: history, calendar: calendar, limit: .max)
        let songChart = Array(allSongs.prefix(100))
        let activity = history.activity(in: period, now: now, calendar: calendar)
        // A collaboration is under each artist on it.
        let byArtist = kind == .artists ? group(allSongs) { $0.credits.map(\.identity) } : [:]
        let byAlbum = kind == .albums ? group(allSongs) { song in
            song.albumTitle.flatMap { CaptureStat.albumIdentity(title: $0, artistName: song.artistName) }.map { [$0] } ?? []
        } : [:]
        let entries: [ChartEntry] = switch kind {
        case .songs:
            songChart.map(ChartEntry.init)
        case .artists:
            // Each artist with the song of theirs played most in the period.
            StatsCalculator.artistChart(in: period, history: history, calendar: calendar).map { ranked in
                var entry = ChartEntry(ranked)
                entry.songs = byArtist[ranked.item.id] ?? []
                entry.songCount = ranked.item.songCount
                entry.isNew = activity.newArtists.contains(ranked.item.id)
                if let song = songChart.first(where: { $0.item.credits.contains { $0.identity == ranked.item.id } }) {
                    entry.detail = String(localized: "Most played: \(song.item.title)")
                }
                return entry
            }
        case .albums:
            StatsCalculator.albumChart(in: period, history: history, calendar: calendar).map { ranked in
                var entry = ChartEntry(ranked)
                entry.songs = byAlbum[ranked.item.id] ?? []
                entry.songCount = ranked.item.songCount
                return entry
            }
        }
        return ChartSnapshot(
            kind: kind,
            period: period,
            scope: scope,
            entries: entries,
            playCount: history.playCount(in: period),
            songs: songChart.map { MixSong(tally: $0.item) },
            earlier: history.period(before: period, calendar: calendar),
            later: history.period(after: period, now: now, calendar: calendar),
            hasHistory: !history.isEmpty,
            activity: activity
        )
    }

    /// The songs under each artist or album, in chart order, a hundred at most.
    private static func group(_ songs: [Ranked<SongTally>], by keys: (SongTally) -> [String]) -> [String: [MixSong]] {
        var groups: [String: [MixSong]] = [:]
        for song in songs {
            for key in keys(song.item) where groups[key, default: []].count < 100 {
                groups[key, default: []].append(MixSong(tally: song.item))
            }
        }
        return groups
    }

    /// "62 plays, 41 songs": the period in one line.
    var summary: String {
        let plays = String(AttributedString(localized: "^[\(playCount) play](inflect: true)").characters)
        let items = switch kind {
        case .songs: String(AttributedString(localized: "^[\(entries.count) song](inflect: true)").characters)
        case .artists: String(AttributedString(localized: "^[\(entries.count) artist](inflect: true)").characters)
        case .albums: String(AttributedString(localized: "^[\(entries.count) album](inflect: true)").characters)
        }
        return String(localized: "\(plays), \(items)")
    }
}

/// A chart row in one shape whatever it ranks.
nonisolated struct ChartEntry: Identifiable, Equatable, Sendable {
    let id: String
    let route: Route
    let title: String
    /// The artist, for a song or an album.
    let subtitle: String?
    /// Everyone the song or album credits, to link each name in the subtitle.
    var credits: [ArtistCredit] = []
    /// The album, for a song.
    let album: String?
    let artworkURL: String?
    let artworkSeed: String
    let isArtist: Bool
    let count: Int
    let rank: Int
    let movement: ChartMovement
    /// The song itself, for its menu and to play it. Nil for artists and albums.
    let song: MixSong?
    /// A line under the name where there's something to say: an artist's song played most.
    var detail: String?
    /// How many different songs of an artist's or album's were played.
    var songCount: Int?
    /// An artist heard for the first time in the period.
    var isNew = false
    /// An artist's or album's songs from the period, most played first, for Play.
    var songs: [MixSong] = []

    init(_ ranked: Ranked<SongTally>) {
        let song = ranked.item
        id = song.id
        route = .song(song.id)
        title = song.title
        subtitle = song.artistName
        credits = song.credits
        album = song.albumTitle
        artworkURL = song.artworkURL
        artworkSeed = song.albumTitle ?? song.title
        isArtist = false
        count = song.count
        rank = ranked.rank
        movement = ranked.movement
        self.song = MixSong(tally: song)
    }

    init(_ ranked: Ranked<ArtistTally>) {
        let artist = ranked.item
        id = artist.id
        route = .artist(artist.id)
        title = artist.name
        subtitle = nil
        album = nil
        artworkURL = artist.artworkURL
        artworkSeed = artist.name
        isArtist = true
        count = artist.count
        rank = ranked.rank
        movement = ranked.movement
        song = nil
    }

    init(_ ranked: Ranked<AlbumTally>) {
        let album = ranked.item
        id = album.id
        route = .album(album.id)
        title = album.title
        subtitle = album.artistName
        credits = ArtistCredits.parse(artist: album.artistName)
        self.album = nil
        artworkURL = album.artworkURL
        artworkSeed = album.title
        isArtist = false
        count = album.count
        rank = ranked.rank
        movement = ranked.movement
        song = nil
    }
}

extension MixSong {
    /// A song of a chart, counted in the chart's period.
    nonisolated init(tally: SongTally) {
        self.init(
            songIdentity: tally.id,
            songID: tally.songID,
            title: tally.title,
            artistName: tally.artistName,
            albumTitle: tally.albumTitle,
            artworkURL: tally.artworkURL,
            plays: tally.count,
            lastHeard: tally.lastHeard
        )
    }
}

// MARK: - Words

extension ChartSpan {
    /// The segment's name.
    var label: LocalizedStringKey {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        case .allTime: "All Time"
        }
    }

    /// The button that comes back to now.
    var currentLabel: LocalizedStringKey {
        switch self {
        case .day: "Today"
        case .week: "This Week"
        case .month: "This Month"
        case .year: "This Year"
        case .allTime: "All Time"
        }
    }

    /// For sentences about stepping: "the day before".
    var unitName: LocalizedStringKey {
        switch self {
        case .day: "day"
        case .week: "week"
        case .month: "month"
        case .year: "year"
        case .allTime: "period"
        }
    }
}

extension ChartPeriod {
    /// The period in words: "Today", "Tuesday, September 22", "This Week", "Week of Sep 14",
    /// "August 2026", "2025" or "All Time". The year is said only when it isn't this one.
    func title(now: Date = .now, calendar: Calendar = .current) -> String {
        guard let start = interval?.start else { return String(localized: "All Time") }
        let isThisYear = calendar.isDate(start, equalTo: now, toGranularity: .year)
        switch span {
        case .day:
            if calendar.isDate(start, inSameDayAs: now) { return String(localized: "Today") }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
               calendar.isDate(start, inSameDayAs: yesterday) {
                return String(localized: "Yesterday")
            }
            let style = Date.FormatStyle.dateTime.weekday(.wide).month(.wide).day()
            return start.formatted(isThisYear ? style : style.year())
        case .week:
            if isCurrent(now: now) { return String(localized: "This Week") }
            let style = Date.FormatStyle.dateTime.month(.abbreviated).day()
            return String(localized: "Week of \(start.formatted(isThisYear ? style : style.year()))")
        case .month:
            return start.formatted(.dateTime.month(.wide).year())
        case .year:
            return start.formatted(.dateTime.year())
        case .allTime:
            return String(localized: "All Time")
        }
    }

    /// The title when there's nothing in the period.
    var emptyTitle: LocalizedStringKey {
        if isCurrent() {
            return switch span {
            case .day: "Nothing Played Yet Today"
            case .week: "Nothing Played Yet This Week"
            case .month: "Nothing Played Yet This Month"
            case .year: "Nothing Played Yet This Year"
            case .allTime: "Nothing Played Yet"
            }
        }
        return switch span {
        case .day: "No Listening That Day"
        case .week: "No Listening That Week"
        case .month: "No Listening That Month"
        case .year: "No Listening That Year"
        case .allTime: "Nothing Played Yet"
        }
    }
}
