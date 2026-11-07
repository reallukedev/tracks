import Foundation

/// Genres and release years across a range. Only songs whose ``SongMetadata`` has been
/// looked up count, so each figure carries how many plays it's based on.
struct GenreFigures {
    var topGenres: [GenreTally] = []
    var genreCount = 0
    var knownGenrePlays = 0
    /// Every decade from the oldest to the newest, empty ones included.
    var decades: [DecadeCount] = []
    var knownYearPlays = 0
    /// Plays of songs released the year they were played or the year before.
    var recentReleasePlays = 0
    /// Over plays, so a song played ten times counts ten times.
    var medianReleaseYear: Int?
    var oldest: ReleaseRecord?
}

extension StatsCalculator {

    static func genreFigures(
        _ indices: Range<Int>,
        in history: ListeningHistory,
        calendar: Calendar,
        limit: Int
    ) -> GenreFigures {
        guard !history.songMetadata.isEmpty else { return GenreFigures() }

        var genres: [String: (count: Int, seconds: TimeInterval, artists: Set<String>)] = [:]
        var decades: [Int: (count: Int, seconds: TimeInterval)] = [:]
        var years: [Int] = []
        var figures = GenreFigures()
        var oldest: (year: Int, index: Int)?

        var clock = DayClock(calendar: calendar)
        for index in indices {
            guard let metadata = history.metadata(at: index) else { continue }
            let capture = history.captures[index]
            let seconds = history.seconds[index]

            if let genre = metadata.genre {
                figures.knownGenrePlays += 1
                genres[genre, default: (0, 0, [])].count += 1
                genres[genre, default: (0, 0, [])].seconds += seconds
                genres[genre, default: (0, 0, [])].artists.formUnion(capture.creditIdentities)
            }

            if let year = metadata.releaseYear {
                figures.knownYearPlays += 1
                years.append(year)
                decades[year / 10 * 10, default: (0, 0)].count += 1
                decades[year / 10 * 10, default: (0, 0)].seconds += seconds
                if let played = clock.facts(for: capture.capturedAt)?.year, played - year <= 1 {
                    figures.recentReleasePlays += 1
                }
                // Ties go to the most recently played, which history order gives us.
                if oldest.map({ year <= $0.year }) ?? true { oldest = (year, index) }
            }
        }

        figures.genreCount = genres.count
        figures.topGenres = genres
            .map { GenreTally(name: $0.key, count: $0.value.count, seconds: $0.value.seconds, artistCount: $0.value.artists.count) }
            .sorted { ($0.count, $0.seconds, $1.name) > ($1.count, $1.seconds, $0.name) }
            .prefix(limit)
            .map { $0 }

        if let first = decades.keys.min(), let last = decades.keys.max() {
            figures.decades = stride(from: first, through: last, by: 10).map {
                DecadeCount(decade: $0, count: decades[$0]?.count ?? 0, seconds: decades[$0]?.seconds ?? 0)
            }
        }

        if !years.isEmpty {
            years.sort()
            figures.medianReleaseYear = years[(years.count - 1) / 2]
        }

        if let oldest {
            let capture = history.captures[oldest.index]
            figures.oldest = ReleaseRecord(
                songID: capture.songIdentity,
                title: capture.title,
                artistName: capture.artistName,
                year: oldest.year
            )
        }
        return figures
    }

    /// The genre an artist is played in most, for their page.
    static func mainGenre(of members: [Int], in history: ListeningHistory) -> String? {
        var counts: [String: Int] = [:]
        for index in members {
            if let genre = history.metadata(at: index)?.genre { counts[genre, default: 0] += 1 }
        }
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    /// The earliest and latest release years among an artist's songs that were played.
    static func releaseYears(of members: [Int], in history: ListeningHistory) -> ClosedRange<Int>? {
        let years = members.compactMap { history.metadata(at: $0)?.releaseYear }
        guard let first = years.min(), let last = years.max() else { return nil }
        return first...last
    }
}
