import SwiftUI
import Synchronization
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
    /// The entries' plays added up, which a collaboration counts once per artist on it.
    var entryPlays = 0
    /// The album with the most of its songs played, when that's more than one.
    var deepest: ChartEntry?

    /// What makes two snapshots the same chart, so only new listening in it animates.
    var identity: String {
        "\(kind.rawValue)|\(period.span.rawValue)|\(period.interval?.start.timeIntervalSinceReferenceDate ?? 0)|\(scope.rawValue)"
    }

    static func make(
        kind: ChartKind,
        period: ChartPeriod,
        scope: SourceScope,
        history: ListeningHistory,
        engine: HistoryEngine? = nil,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> ChartSnapshot {
        // The engine's index answers in a few milliseconds however long the history; the
        // calculator over `history` is the fallback if it can't.
        let fromEngine = engine.flatMap { try? EngineCharts(kind: kind, period: period, scope: scope, engine: $0, calendar: calendar) }
        // Every song of the period, so an artist or album whose songs each rank low still
        // has them to play.
        let allSongs = fromEngine?.songs ?? StatsCalculator.songChart(in: period, history: history, calendar: calendar, limit: .max)
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
            (fromEngine?.artists ?? StatsCalculator.artistChart(in: period, history: history, calendar: calendar)).map { ranked in
                var entry = ChartEntry(ranked, artwork: history.artistArtwork[ranked.item.id])
                entry.songs = byArtist[ranked.item.id] ?? []
                entry.songCount = ranked.item.songCount
                entry.isNew = activity.newArtists.contains(ranked.item.id)
                if let song = songChart.first(where: { $0.item.credits.contains { $0.identity == ranked.item.id } }) {
                    entry.detail = String(localized: "Most played: \(song.item.title)")
                }
                return entry
            }
        case .albums:
            (fromEngine?.albums ?? StatsCalculator.albumChart(in: period, history: history, calendar: calendar)).map { ranked in
                var entry = ChartEntry(ranked)
                entry.songs = byAlbum[ranked.item.id] ?? []
                entry.songCount = ranked.item.songCount
                return entry
            }
        }
        var snapshot = ChartSnapshot(
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
        // Worked out here, off the main actor, rather than by the card as it's drawn.
        snapshot.entryPlays = entries.reduce(0) { $0 + $1.count }
        if kind == .albums,
           let deepest = entries.max(by: { ($0.songCount ?? 0, -$0.rank) < ($1.songCount ?? 0, -$1.rank) }),
           (deepest.songCount ?? 0) > 1 {
            snapshot.deepest = deepest
        }
        return snapshot
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

/// A period's charts from the engine: the songs (every one, when an artist's or album's
/// songs are needed to play them), and the chart on show.
nonisolated private struct EngineCharts {
    let songs: [Ranked<SongTally>]
    var artists: [Ranked<ArtistTally>]?
    var albums: [Ranked<AlbumTally>]?

    init(kind: ChartKind, period: ChartPeriod, scope: SourceScope, engine: HistoryEngine, calendar: Calendar) throws {
        songs = try engine.songChart(in: period, scope: scope, calendar: calendar, limit: kind == .songs ? 100 : .max)
        switch kind {
        case .songs: break
        case .artists: artists = try engine.artistChart(in: period, scope: scope, calendar: calendar)
        case .albums: albums = try engine.albumChart(in: period, scope: scope, calendar: calendar)
        }
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
    var songCount: Int? {
        didSet { amounts = songCount.map { "\(countText) · \(ChartWords.songs($0))" } ?? countText }
    }
    /// An artist heard for the first time in the period.
    var isNew = false
    /// An artist's or album's songs from the period, most played first, for Play.
    var songs: [MixSong] = []
    /// "134 plays", worked out with the snapshot so a row doesn't inflect it as it's drawn.
    let countText: String
    /// "134 plays · 12 songs" for an artist or album, or the plays alone.
    private(set) var amounts: String

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
        countText = ChartWords.plays(song.count)
        amounts = countText
        rank = ranked.rank
        movement = ranked.movement
        self.song = MixSong(tally: song)
    }

    /// - Parameter artwork: the artist's own picture, when one's been found, over the cover of
    ///   their most played song.
    init(_ ranked: Ranked<ArtistTally>, artwork: String? = nil) {
        let artist = ranked.item
        id = artist.id
        route = .artist(artist.id)
        title = artist.name
        subtitle = nil
        album = nil
        artworkURL = artwork ?? artist.artworkURL
        artworkSeed = artist.name
        isArtist = true
        count = artist.count
        countText = ChartWords.plays(artist.count)
        amounts = countText
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
        countText = ChartWords.plays(album.count)
        amounts = countText
        rank = ranked.rank
        movement = ranked.movement
        song = nil
    }
}

/// A chart's counts in words, inflected once per number: a long chart repeats the same
/// small counts thousands of times.
nonisolated enum ChartWords {
    private static let plays = Mutex<[Int: String]>([:])
    private static let songs = Mutex<[Int: String]>([:])

    /// "12 plays", as ``PlayCountText/short(_:)`` says it.
    static func plays(_ count: Int) -> String {
        word(count, in: plays) { String(AttributedString(localized: "^[\($0) play](inflect: true)").characters) }
    }

    /// "12 songs".
    static func songs(_ count: Int) -> String {
        word(count, in: songs) { String(AttributedString(localized: "^[\($0) song](inflect: true)").characters) }
    }

    private static func word(_ count: Int, in cache: borrowing Mutex<[Int: String]>, _ make: (Int) -> String) -> String {
        if let known = cache.withLock({ $0[count] }) { return known }
        let made = make(count)
        cache.withLock { words in
            if words.count > 4_096 { words.removeAll() }
            words[count] = made
        }
        return made
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
