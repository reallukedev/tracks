import Testing
import Foundation
@testable import TracksCore

/// A fixed UTC calendar, so results don't depend on the machine's time zone.
private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 1
    return calendar
}()

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

private func capture(_ title: String, artist: String = "An Artist", songID: String = "", at when: Date) -> CaptureStat {
    CaptureStat(songKey: title, songID: songID, title: title, artistName: artist, capturedAt: when, kind: .onDemand)
}

private func identity(_ title: String, artist: String = "An Artist") -> String {
    HistoryImport.key(title: title, artistName: artist)
}

/// `plays` of each song, an hour apart, on 8 September 2026.
private func history(_ songs: [(title: String, plays: Int, genre: String?, year: Int?)]) -> ListeningHistory {
    var hour = 0
    var captures: [CaptureStat] = []
    var metadata: [String: SongMetadata] = [:]
    for song in songs {
        for _ in 0..<song.plays {
            captures.append(capture(song.title, at: date(2026, 9, 8).addingTimeInterval(Double(hour) * 3_600)))
            hour += 1
        }
        metadata[identity(song.title)] = SongMetadata(genre: song.genre, releaseYear: song.year)
    }
    return ListeningHistory(captures, songMetadata: metadata)
}

private func summary(_ history: ListeningHistory, range: StatsRange = .allTime) -> StatsSummary {
    StatsCalculator.summary(range: range, history: history, sessions: [], calendar: calendar, now: date(2026, 9, 9))
}

@Suite("Genres and release years")
struct GenreStatsTests {

    // MARK: - Reading the catalog

    @Test("the primary genre skips Apple's catch-all", arguments: [
        (["Pop", "Music"], "Pop"),
        (["Music", "Hip-Hop/Rap"], "Hip-Hop/Rap"),
        (["music"], nil),
        (["  ", "Jazz"], "Jazz"),
        ([], nil),
    ] as [([String], String?)])
    func primaryGenre(names: [String], expected: String?) {
        #expect(SongMetadata.primaryGenre(from: names) == expected)
    }

    /// Lists copied from the catalog on a real account. The top-level set is what the
    /// song's `genres` relationship said, each with the root as its parent.
    @Test("a subgenre rolls up to the catalog's top-level genre", arguments: [
        (["Rap", "Music", "Hip-Hop/Rap"], ["Hip-Hop/Rap"], "Hip-Hop/Rap"),
        (["Hip-Hop", "Music", "Hip-Hop/Rap"], ["Hip-Hop/Rap"], "Hip-Hop/Rap"),
        (["Contemporary R&B", "Music", "R&B/Soul"], ["R&B/Soul"], "R&B/Soul"),
        (["Hip-Hop/Rap", "Music", "Rap", "Alternative Rap", "Alternative"], ["Hip-Hop/Rap", "Alternative"], "Hip-Hop/Rap"),
        (["Alternative", "Music", "Dance"], ["Alternative", "Dance"], "Alternative"),
        // A library song has names and no relationships, so its own genre stands.
        (["Rap", "Music", "Hip-Hop/Rap"], [], "Rap"),
    ] as [([String], Set<String>, String)])
    func genreRollsUp(names: [String], topLevel: Set<String>, expected: String) {
        #expect(SongMetadata.primaryGenre(from: names, topLevel: topLevel) == expected)
    }

    /// The catalog's bare dates are midnight UTC; read in New York, New Year's Day would
    /// be New Year's Eve.
    @Test("the release year is read in UTC")
    func releaseYearIsUTC() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let newYear = utc.date(from: DateComponents(year: 1999, month: 1, day: 1))
        #expect(SongMetadata.releaseYear(from: newYear) == 1999)
        #expect(SongMetadata.releaseYear(from: nil) == nil)
    }

    @Test("placeholder release dates are ignored")
    func placeholderYears() {
        #expect(SongMetadata.releaseYear(from: .distantPast) == nil)
    }

    // MARK: - What to look up

    @Test("lookups go most played first, and a catalog id beats a library id or a search")
    func pendingOrder() throws {
        let captures = [
            capture("rare", songID: "", at: date(2026, 9, 1)),
            capture("hit", songID: "i.libraryID", at: date(2026, 9, 2)),
            capture("hit", songID: "1440833098", at: date(2026, 9, 3)),
            capture("hit", songID: "", at: date(2026, 9, 4)),
        ]
        let requests = SongMetadataLookup.pending(
            in: ListeningHistory(captures),
            lookedUp: [],
            limit: 10,
            searchLimit: 10
        )

        #expect(requests.map(\.title) == ["hit", "rare"])
        let hit = try #require(requests.first)
        #expect(hit.hasCatalogID)
        #expect(requests.last?.needsSearch == true)
    }

    @Test("songs already looked up aren't asked about again")
    func pendingSkipsKnown() {
        let captures = [capture("known", at: date(2026, 9, 1)), capture("new", at: date(2026, 9, 1))]
        let requests = SongMetadataLookup.pending(
            in: ListeningHistory(captures),
            lookedUp: [identity("known")],
            limit: 10,
            searchLimit: 10
        )
        #expect(requests.map(\.title) == ["new"])
    }

    /// A search is one request per song, so a history of unresolved songs mustn't turn a
    /// round into hundreds of them.
    @Test("searches are limited per round, batched lookups separately")
    func pendingLimitsSearches() {
        let searches = (0..<5).map { capture("search \($0)", at: date(2026, 9, 1)) }
        let batched = (0..<5).map { capture("id \($0)", songID: "10000000\($0)", at: date(2026, 9, 1)) }
        let requests = SongMetadataLookup.pending(
            in: ListeningHistory(searches + batched),
            lookedUp: [],
            limit: 3,
            searchLimit: 2
        )
        #expect(requests.count { $0.needsSearch } == 2)
        #expect(requests.count { !$0.needsSearch } == 3)
    }

    @Test("the cache remembers misses and keeps earlier rounds")
    func cacheRecords() throws {
        let url = URL.temporaryDirectory.appending(path: "SongMetadata-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = SongMetadataCache(url: url)
        let jazz = SongMetadata(genre: "Jazz", releaseYear: 1959)

        let first = cache.record(found: ["a": jazz], asked: ["a", "b"], into: [:])
        cache.record(found: [:], asked: ["c"], into: first)

        let loaded = cache.load()
        #expect(loaded["a"] == jazz)
        #expect(loaded["b"] == .unknown)
        #expect(loaded["c"] == .unknown)
    }

    // MARK: - Figures

    @Test("genres are ranked by plays and their shares are out of known plays")
    func topGenres() throws {
        let result = summary(history([
            ("a", 5, "Jazz", 1959),
            ("b", 3, "Pop", 2024),
            ("c", 2, nil, nil),
        ]))

        #expect(result.topGenres.map(\.name) == ["Jazz", "Pop"])
        #expect(result.topGenres.map(\.count) == [5, 3])
        #expect(result.knownGenrePlays == 8)
        #expect(result.genreCount == 2)
        #expect(result.genreCoverage == 0.8)
    }

    @Test("decades run from the oldest to the newest with the gaps kept")
    func decades() throws {
        let result = summary(history([
            ("old", 2, "Jazz", 1965),
            ("new", 3, "Pop", 1994),
        ]))

        #expect(result.decades.map(\.decade) == [1960, 1970, 1980, 1990])
        #expect(result.decades.map(\.count) == [2, 0, 0, 3])
        #expect(result.topDecade?.decade == 1990)
    }

    @Test("recent releases, the median year and the oldest song")
    func releaseFigures() throws {
        let result = summary(history([
            ("fresh", 3, "Pop", 2026),
            ("last year", 1, "Pop", 2025),
            ("classic", 1, "Jazz", 1959),
        ]))

        #expect(result.recentReleasePlays == 4)
        #expect(result.recentReleaseShare == 0.8)
        #expect(result.medianReleaseYear == 2026)
        let oldest = try #require(result.oldestRelease)
        #expect(oldest.title == "classic")
        #expect(oldest.year == 1959)
    }

    @Test("without any lookups there are no genre figures")
    func noMetadata() {
        let result = summary(ListeningHistory([capture("a", at: date(2026, 9, 8))]))
        #expect(result.topGenres.isEmpty)
        #expect(result.decades.isEmpty)
        #expect(!result.genresAreInformative)
        #expect(result.recentReleaseShare == nil)
    }

    // MARK: - Highlights and profiles

    @Test("a dominant genre and decade become highlights")
    func highlights() {
        let result = summary(history([
            ("a", 8, "Jazz", 1959),
            ("b", 2, "Pop", 2024),
            ("c", 2, "Folk", 2023),
        ]))

        #expect(result.insights.contains(.topGenre(name: "Jazz", percent: 67)))
        #expect(result.insights.contains(.favouriteDecade(decade: 1950, percent: 67)))
    }

    /// With only one or two genres, "mostly jazz" tells a jazz fan nothing.
    @Test("a genre highlight needs three genres to choose from")
    func genreHighlightNeedsVariety() {
        let result = summary(history([("a", 8, "Jazz", nil), ("b", 4, "Pop", nil)]))
        #expect(!result.insights.contains { $0.id == "topGenre" })
    }

    @Test("an artist's page gets their main genre and the span of their releases")
    func artistProfile() throws {
        let captures = [
            capture("early", artist: "Band", at: date(2026, 9, 1)),
            capture("late", artist: "Band", at: date(2026, 9, 2)),
            capture("late", artist: "Band", at: date(2026, 9, 3)),
        ]
        let history = ListeningHistory(captures, songMetadata: [
            identity("early", artist: "Band"): SongMetadata(genre: "Rock", releaseYear: 1971),
            identity("late", artist: "Band"): SongMetadata(genre: "Alternative", releaseYear: 1994),
        ])
        let profile = try #require(StatsCalculator.artistProfile(id: "band", history: history, calendar: calendar))

        #expect(profile.genre == "Alternative")
        #expect(profile.releaseYears == 1971...1994)
    }

    @Test("search finds songs by genre")
    func searchByGenre() {
        let history = ListeningHistory(
            [capture("Blue in Green", at: date(2026, 9, 1)), capture("Other", at: date(2026, 9, 1))],
            songMetadata: [identity("Blue in Green"): SongMetadata(genre: "Jazz", releaseYear: 1959)]
        )
        #expect(StatsCalculator.search("jazz", in: history).songs.map(\.title) == ["Blue in Green"])
    }

    @Test("sample data has a genre and year for every song it plays")
    func demoMetadataCoversDemoPlays() {
        let metadata = DemoLibrary.songMetadata()
        let plays = DemoLibrary.plays(endingAt: date(2026, 9, 9), calendar: calendar, days: 30)
        #expect(plays.allSatisfy { metadata[HistoryImport.key(title: $0.title, artistName: $0.artistName)]?.genre != nil })
    }
}
