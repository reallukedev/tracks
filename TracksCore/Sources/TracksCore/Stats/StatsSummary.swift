import Foundation

/// Everything the Summary screen shows for one range.
public struct StatsSummary: Sendable, Equatable {
    public let range: StatsRange
    public let generatedAt: Date
    /// `nil` for all time.
    public let interval: DateInterval?
    /// How many periods back from the one containing now: 0 for this month, -1 for last.
    public let periodOffset: Int
    /// Whether anything was played before this period, so there's an earlier one to go to.
    public let hasEarlierPeriod: Bool

    public let captureCount: Int
    public let uniqueSongCount: Int
    public let uniqueArtistCount: Int

    /// Estimated, see `ListeningEstimate`.
    public let listeningSeconds: TimeInterval
    public let activeDays: Int
    /// Averaged over the days that have actually happened, so Wednesday doesn't count the
    /// rest of the week as silence.
    public let dailyAverageSeconds: TimeInterval

    /// The same numbers for the same stretch of the previous period (Monday to Wednesday of
    /// last week, if today is Wednesday). `nil` when there's no history that far back.
    public let previousCaptureCount: Int?
    public let previousListeningSeconds: TimeInterval?

    public let sessionCount: Int
    /// Radio session time, clipped to the range.
    public let radioSessionSeconds: TimeInterval

    /// Songs heard for the first time ever (across all history) inside this range. This is
    /// Tracks’ history, not the user's library: MusicKit can't reliably tell us what's in
    /// the library, so the UI calls these "new to you".
    public let firstTimeHeardCount: Int
    public let newArtistCount: Int

    public let topSongs: [SongTally]
    public let topArtists: [ArtistTally]
    public let topAlbums: [AlbumTally]
    public let topStations: [NamedCount]
    /// First hearings, newest first.
    public let discoveries: [SongTally]

    /// On a real database most captures had no station name, because we only learn it if
    /// we see the tune-in. Counted so the stations list can say so.
    public let capturesWithoutStation: Int

    public let timeline: [TimeBucket]
    public let timelineUnit: Calendar.Component
    public let hourly: [HourCount]
    /// In the locale's week order.
    public let weekdays: [WeekdayCount]
    public let heatMap: [HeatCell]
    public let sources: [SourceCount]
    /// Computed over all history, not just the range.
    public let streak: Streak
    public let insights: [Insight]

    public let uniqueAlbumCount: Int
    /// Songs played exactly once in the range.
    public let oneOffSongCount: Int
    /// The artist with the most different songs in the range, if anyone reached three.
    public let deepestArtist: ArtistTally?
    /// Songs first heard in the range and played again since, most played first.
    public let newFavourites: [SongTally]
    /// First hearings per bucket, lined up with `timeline`.
    public let newSongTimeline: [TimeBucket]
    /// Running totals across the range, beside last period's.
    public let pace: [PacePoint]
    /// Morning, afternoon, evening and night, in that order.
    public let dayParts: [DayPartCount]
    /// Per day of that kind so far. `nil` before the range has had one.
    public let weekdayAverageSeconds: TimeInterval?
    public let weekendAverageSeconds: TimeInterval?
    /// Found from the gaps between songs, unlike `sessionCount`, which counts radio.
    public let listeningSessions: SessionStats
    public let records: ListeningRecords

    /// Most played first. Only songs with a known genre count; see `knownGenrePlays`.
    public let topGenres: [GenreTally]
    public let genreCount: Int
    /// Plays whose genre is known, which the genre shares are out of.
    public let knownGenrePlays: Int
    /// Oldest first, every decade between the first and last included.
    public let decades: [DecadeCount]
    /// Plays whose release year is known, which the decade shares are out of.
    public let knownYearPlays: Int
    /// Plays of songs released the year they were played or the year before.
    public let recentReleasePlays: Int
    public let medianReleaseYear: Int?
    public let oldestRelease: ReleaseRecord?

    public init(
        range: StatsRange,
        generatedAt: Date = .now,
        interval: DateInterval? = nil,
        captureCount: Int,
        uniqueSongCount: Int,
        uniqueArtistCount: Int,
        listeningSeconds: TimeInterval = 0,
        activeDays: Int = 0,
        dailyAverageSeconds: TimeInterval = 0,
        previousCaptureCount: Int? = nil,
        previousListeningSeconds: TimeInterval? = nil,
        sessionCount: Int = 0,
        radioSessionSeconds: TimeInterval = 0,
        firstTimeHeardCount: Int = 0,
        newArtistCount: Int = 0,
        topSongs: [SongTally] = [],
        topArtists: [ArtistTally] = [],
        topAlbums: [AlbumTally] = [],
        topStations: [NamedCount] = [],
        discoveries: [SongTally] = [],
        capturesWithoutStation: Int = 0,
        timeline: [TimeBucket] = [],
        timelineUnit: Calendar.Component = .day,
        hourly: [HourCount] = [],
        weekdays: [WeekdayCount] = [],
        heatMap: [HeatCell] = [],
        sources: [SourceCount] = [],
        streak: Streak = .none,
        insights: [Insight] = [],
        uniqueAlbumCount: Int = 0,
        oneOffSongCount: Int = 0,
        deepestArtist: ArtistTally? = nil,
        newFavourites: [SongTally] = [],
        newSongTimeline: [TimeBucket] = [],
        pace: [PacePoint] = [],
        dayParts: [DayPartCount] = [],
        weekdayAverageSeconds: TimeInterval? = nil,
        weekendAverageSeconds: TimeInterval? = nil,
        listeningSessions: SessionStats = .none,
        records: ListeningRecords = .none,
        topGenres: [GenreTally] = [],
        genreCount: Int = 0,
        knownGenrePlays: Int = 0,
        decades: [DecadeCount] = [],
        knownYearPlays: Int = 0,
        recentReleasePlays: Int = 0,
        medianReleaseYear: Int? = nil,
        oldestRelease: ReleaseRecord? = nil,
        periodOffset: Int = 0,
        hasEarlierPeriod: Bool = false
    ) {
        self.range = range
        self.generatedAt = generatedAt
        self.interval = interval
        self.periodOffset = periodOffset
        self.hasEarlierPeriod = hasEarlierPeriod
        self.captureCount = captureCount
        self.uniqueSongCount = uniqueSongCount
        self.uniqueArtistCount = uniqueArtistCount
        self.listeningSeconds = listeningSeconds
        self.activeDays = activeDays
        self.dailyAverageSeconds = dailyAverageSeconds
        self.previousCaptureCount = previousCaptureCount
        self.previousListeningSeconds = previousListeningSeconds
        self.sessionCount = sessionCount
        self.radioSessionSeconds = radioSessionSeconds
        self.firstTimeHeardCount = firstTimeHeardCount
        self.newArtistCount = newArtistCount
        self.topSongs = topSongs
        self.topArtists = topArtists
        self.topAlbums = topAlbums
        self.topStations = topStations
        self.discoveries = discoveries
        self.capturesWithoutStation = capturesWithoutStation
        self.timeline = timeline
        self.timelineUnit = timelineUnit
        self.hourly = hourly
        self.weekdays = weekdays
        self.heatMap = heatMap
        self.sources = sources
        self.streak = streak
        self.insights = insights
        self.uniqueAlbumCount = uniqueAlbumCount
        self.oneOffSongCount = oneOffSongCount
        self.deepestArtist = deepestArtist
        self.newFavourites = newFavourites
        self.newSongTimeline = newSongTimeline
        self.pace = pace
        self.dayParts = dayParts
        self.weekdayAverageSeconds = weekdayAverageSeconds
        self.weekendAverageSeconds = weekendAverageSeconds
        self.listeningSessions = listeningSessions
        self.records = records
        self.topGenres = topGenres
        self.genreCount = genreCount
        self.knownGenrePlays = knownGenrePlays
        self.decades = decades
        self.knownYearPlays = knownYearPlays
        self.recentReleasePlays = recentReleasePlays
        self.medianReleaseYear = medianReleaseYear
        self.oldestRelease = oldestRelease
    }

    /// `nil` rather than 0 when nothing was captured, since 0% would read as "nothing new".
    public var firstTimeHeardRate: Double? {
        guard captureCount > 0 else { return nil }
        return Double(firstTimeHeardCount) / Double(captureCount)
    }

    public var busiestCell: HeatCell? {
        heatMap.filter { $0.count > 0 }.max { $0.count < $1.count }
    }

    public var isEmpty: Bool { captureCount == 0 && sessionCount == 0 }

    /// This week, month or year, rather than one that has already ended.
    public var isCurrentPeriod: Bool { periodOffset == 0 }

    public var captureCountDelta: Int? {
        previousCaptureCount.map { captureCount - $0 }
    }

    /// 0.25 means a quarter more than last time. `nil` if last time was under ten minutes,
    /// where any percentage would be silly.
    public var listeningChange: Double? {
        guard let previous = previousListeningSeconds, previous >= 600 else { return nil }
        return (listeningSeconds - previous) / previous
    }

    public var peakBucket: TimeBucket? {
        timeline.filter { $0.count > 0 }.max { $0.count < $1.count }
    }

    /// Whether the Listening card draws its bars. One lit bar still earns the chart: the
    /// axis shows where it falls in the range, and without the chart a first day's card
    /// is an empty box that looks broken. Nothing played, or a range with a single bucket,
    /// has nothing to show.
    public var timelineIsInformative: Bool {
        timeline.count >= 2 && timeline.contains { $0.count > 0 }
    }

    /// Below six lit cells the 7×24 grid looks broken rather than sparse, so the screen
    /// describes the busiest time in words instead.
    public var heatMapIsInformative: Bool {
        heatMap.count { $0.count > 0 } >= 6
    }

    /// Whether any song was played more than once.
    public var rankingIsMeaningful: Bool {
        (topSongs.map(\.count).max() ?? 0) > 1
    }

    public var sourcesAreInformative: Bool {
        sources.count > 1
    }

    /// Plays for each different song. 1 means nothing was played twice.
    public var playsPerSong: Double {
        uniqueSongCount > 0 ? Double(captureCount) / Double(uniqueSongCount) : 0
    }

    /// Where most of the listening happened. `nil` with nothing played.
    public var busiestDayPart: DayPartCount? {
        dayParts.filter { $0.count > 0 }.max { ($0.seconds, $1.part.rawValue) < ($1.seconds, $0.part.rawValue) }
    }

    /// Two or more lines' worth of days, or there's no pace to speak of.
    public var paceIsInformative: Bool {
        pace.count { $0.current != nil } >= 2 && listeningSeconds > 0
    }

    /// Last period's running total at the latest point this period has reached.
    public var pacePrevious: TimeInterval? {
        pace.last { $0.current != nil }?.previous
    }

    /// Whether there are enough days and plays to split into new and familiar.
    public var newVsFamiliarIsInformative: Bool {
        timelineIsInformative && captureCount >= 5
    }

    /// One session doesn't make a pattern.
    public var sessionsAreInformative: Bool {
        listeningSessions.count >= 2
    }

    /// Records need more than one day to beat.
    public var recordsAreInformative: Bool {
        activeDays >= 2 && records.biggestDay != nil
    }

    /// Ten plays with a genre before there's a genre chart, so one song doesn't make a taste.
    public var genresAreInformative: Bool {
        knownGenrePlays >= 10 && !topGenres.isEmpty
    }

    public var decadesAreInformative: Bool {
        knownYearPlays >= 10 && !decades.isEmpty
    }

    /// Share of the range's plays whose genre is known. Below 1 while lookups are still
    /// coming in, or for songs Apple Music doesn't have.
    public var genreCoverage: Double {
        captureCount > 0 ? Double(knownGenrePlays) / Double(captureCount) : 0
    }

    public var topDecade: DecadeCount? {
        decades.filter { $0.count > 0 }.max { ($0.count, $1.decade) < ($1.count, $0.decade) }
    }

    /// Out of the plays whose release year is known.
    public var recentReleaseShare: Double? {
        knownYearPlays > 0 ? Double(recentReleasePlays) / Double(knownYearPlays) : nil
    }

    /// The top `limit` artists, plays by everyone else, and what their shares are of. A
    /// collaboration counts for each artist on it, so when the artists' plays add up to more
    /// than the plays themselves, the whole is their sum and the shares still fill it once.
    public func artistMix(limit: Int) -> (artists: [ArtistTally], otherCount: Int, whole: Int) {
        let top = Array(topArtists.prefix(limit))
        let whole = max(captureCount, topArtists.reduce(0) { $0 + $1.count })
        return (top, max(0, whole - top.reduce(0) { $0 + $1.count }), whole)
    }
}
