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

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute
    ))!
}

private func capture(
    _ title: String,
    artist: String = "An Artist",
    album: String? = nil,
    at when: Date,
    kind: CaptureKind = .onDemand
) -> CaptureStat {
    CaptureStat(
        songKey: title,
        title: title,
        artistName: artist,
        albumTitle: album,
        capturedAt: when,
        kind: kind
    )
}

private func summary(
    _ range: StatsRange,
    _ captures: [CaptureStat],
    now: Date
) -> StatsSummary {
    StatsCalculator.summary(range: range, captures: captures, sessions: [], calendar: calendar, now: now)
}

@Suite("Detailed statistics")
struct StatsDetailsTests {

    // MARK: - Sessions

    @Test("sessions split where the gap is longer than a song, and skip recovered songs")
    func sessionsSplitOnGaps() throws {
        var captures = [
            capture("a", at: date(2026, 9, 8, 10, 0)),
            capture("b", at: date(2026, 9, 8, 10, 4)),
            capture("c", at: date(2026, 9, 8, 10, 8)),
            capture("d", at: date(2026, 9, 8, 11, 0)),
            // Timestamped when it was found, so it mustn't join or start a session.
            capture("recovered", at: date(2026, 9, 8, 11, 2), kind: .imported),
        ]
        // Twenty songs five minutes apart: 19 gaps of 300 seconds and a typical last song.
        captures += (0..<20).map { capture("long \($0)", at: date(2026, 9, 8, 14).addingTimeInterval(Double($0) * 300)) }

        let sessions = summary(.allTime, captures, now: date(2026, 9, 8, 20)).listeningSessions

        #expect(sessions.count == 3)
        #expect(sessions.totalSongs == 24)
        let longest = try #require(sessions.longest)
        #expect(longest.start == date(2026, 9, 8, 14))
        #expect(longest.songCount == 20)
        #expect(longest.seconds == 19 * 300 + ListeningEstimate.typicalSongSeconds)
        #expect(sessions.lengths.map(\.count) == [2, 0, 0, 1, 0])
    }

    @Test("a range with nothing played has no sessions")
    func noSessionsWhenEmpty() {
        let stats = summary(.week, [], now: date(2026, 9, 8)).listeningSessions
        #expect(stats == .none)
        #expect(stats.averageSeconds == 0)
    }

    @Test("session lengths land in the right step", arguments: [
        (0.0, SessionLength.underFifteenMinutes),
        (899, .underFifteenMinutes),
        (900, .underHalfHour),
        (1_800, .underHour),
        (3_599, .underHour),
        (3_600, .underTwoHours),
        (7_200, .twoHoursOrMore),
        (40_000, .twoHoursOrMore),
    ])
    func sessionLengthSteps(seconds: TimeInterval, expected: SessionLength) {
        #expect(SessionLength(seconds: seconds) == expected)
    }

    // MARK: - Parts of the day

    @Test("hours belong to the right part of the day", arguments: [
        (0, DayPart.night),
        (4, .night),
        (5, .morning),
        (11, .morning),
        (12, .afternoon),
        (16, .afternoon),
        (17, .evening),
        (21, .evening),
        (22, .night),
        (23, .night),
    ])
    func dayPartBoundaries(hour: Int, expected: DayPart) {
        #expect(DayPart(hour: hour) == expected)
    }

    @Test("every part of the day is listed, and the busiest is found by listening time")
    func dayPartsAreComplete() throws {
        let captures = [
            capture("a", at: date(2026, 9, 8, 2)),
            capture("b", at: date(2026, 9, 8, 2, 5)),
            capture("c", at: date(2026, 9, 8, 9)),
        ]
        let result = summary(.allTime, captures, now: date(2026, 9, 8, 20))

        #expect(result.dayParts.map(\.part) == DayPart.allCases)
        #expect(result.dayParts.map(\.count) == [1, 0, 0, 2])
        let busiest = try #require(result.busiestDayPart)
        #expect(busiest.part == .night)
    }

    @Test("weekday and weekend averages divide by the days that have happened")
    func dayTypeAverages() throws {
        // Sunday 6 September to Tuesday the 8th: one weekend day and two weekdays so far.
        let captures = [
            capture("a", at: date(2026, 9, 6, 12, 0)),
            capture("b", at: date(2026, 9, 6, 12, 5)),
            capture("c", at: date(2026, 9, 7, 12, 0)),
        ]
        let result = summary(.week, captures, now: date(2026, 9, 8, 20))

        let weekend = try #require(result.weekendAverageSeconds)
        let weekday = try #require(result.weekdayAverageSeconds)
        #expect(weekend == 300 + ListeningEstimate.typicalSongSeconds)
        #expect(weekday == ListeningEstimate.typicalSongSeconds / 2)
    }

    // MARK: - Pace

    /// February is three days shorter than March, so its last total carries across the
    /// days it didn't have instead of the line stopping short.
    @Test("pace runs totals to today and carries a shorter last period forward")
    func paceAgainstShorterMonth() throws {
        let captures = [
            capture("a", at: date(2026, 2, 10)),
            capture("b", at: date(2026, 2, 20)),
            capture("c", at: date(2026, 3, 1)),
            capture("d", at: date(2026, 3, 2)),
        ]
        let result = summary(.month, captures, now: date(2026, 3, 2, 18))
        let song = ListeningEstimate.typicalSongSeconds

        #expect(result.pace.count == 31)
        #expect(result.pace[0].current == song)
        #expect(result.pace[1].current == 2 * song)
        #expect(result.pace[2].current == nil)
        #expect(result.pace[8].previous == 0)
        #expect(result.pace[9].previous == song)
        #expect(result.pace[30].previous == 2 * song)
        #expect(result.pacePrevious == 0)
        #expect(result.paceIsInformative)
    }

    @Test("pace has no comparison line without history from before the range")
    func paceWithoutEarlierHistory() {
        let captures = [
            capture("a", at: date(2026, 9, 7)),
            capture("b", at: date(2026, 9, 8)),
        ]
        let result = summary(.week, captures, now: date(2026, 9, 8, 18))

        #expect(!result.pace.isEmpty)
        #expect(result.pace.allSatisfy { $0.previous == nil })
    }

    // MARK: - Discovery and variety

    @Test("new favourites are songs first heard in the range and played again")
    func newFavourites() {
        let captures = [
            capture("old", at: date(2026, 8, 1)),
            capture("old", at: date(2026, 9, 7)),
            capture("old", at: date(2026, 9, 8)),
            capture("keeper", at: date(2026, 9, 7)),
            capture("keeper", at: date(2026, 9, 8)),
            capture("keeper", at: date(2026, 9, 8, 13)),
            capture("once", at: date(2026, 9, 8)),
        ]
        let result = summary(.week, captures, now: date(2026, 9, 8, 18))

        #expect(result.newFavourites.map(\.title) == ["keeper"])
        #expect(result.newFavourites.first?.count == 3)
        #expect(result.newSongTimeline.map(\.count).reduce(0, +) == 2)
    }

    /// In someone's first week, or over all time, every song is new, so the list would
    /// only repeat Top Songs.
    @Test("new favourites need history from before the range", arguments: [StatsRange.week, .allTime])
    func newFavouritesNeedEarlierHistory(range: StatsRange) {
        let captures = [
            capture("keeper", at: date(2026, 9, 7)),
            capture("keeper", at: date(2026, 9, 8)),
        ]
        #expect(summary(range, captures, now: date(2026, 9, 8, 18)).newFavourites.isEmpty)
    }

    @Test("variety counts one-off songs, albums and the deepest artist")
    func varietyFigures() throws {
        let captures = [
            capture("one", artist: "Deep", album: "First", at: date(2026, 9, 8, 9)),
            capture("two", artist: "Deep", album: "First", at: date(2026, 9, 8, 10)),
            capture("three", artist: "Deep", album: "Second", at: date(2026, 9, 8, 11)),
            capture("hit", artist: "Shallow", album: "Single", at: date(2026, 9, 8, 12)),
            capture("hit", artist: "Shallow", album: "Single", at: date(2026, 9, 8, 13)),
            capture("hit", artist: "Shallow", album: "Single", at: date(2026, 9, 8, 14)),
        ]
        let result = summary(.allTime, captures, now: date(2026, 9, 8, 20))

        #expect(result.oneOffSongCount == 3)
        #expect(result.uniqueAlbumCount == 3)
        #expect(result.playsPerSong == 1.5)
        let deepest = try #require(result.deepestArtist)
        #expect(deepest.name == "Deep")
        #expect(deepest.songCount == 3)
    }

    @Test("an artist with fewer than three songs isn't the deepest dive")
    func deepestArtistNeedsThreeSongs() {
        let captures = [
            capture("one", artist: "Pair", at: date(2026, 9, 8, 9)),
            capture("two", artist: "Pair", at: date(2026, 9, 8, 10)),
        ]
        #expect(summary(.allTime, captures, now: date(2026, 9, 8, 20)).deepestArtist == nil)
    }

    @Test("the artist mix puts everyone past the limit into one share")
    func artistMix() {
        let captures = ["A", "A", "A", "B", "B", "C"].enumerated().map { offset, artist in
            capture("song \(offset)", artist: artist, at: date(2026, 9, 8, 9 + offset))
        }
        let mix = summary(.allTime, captures, now: date(2026, 9, 8, 20)).artistMix(limit: 2)

        #expect(mix.artists.map(\.name) == ["A", "B"])
        #expect(mix.otherCount == 1)
    }

    // MARK: - Records

    @Test("records find the biggest day, the most repeated song and the late and early edges")
    func records() throws {
        let captures = [
            capture("a", at: date(2026, 9, 7, 23)),
            capture("b", at: date(2026, 9, 8, 2)),
            // Found at 4:30, but it could have played at any time, so it's no record.
            capture("recovered", at: date(2026, 9, 8, 4, 30), kind: .imported),
            capture("c", at: date(2026, 9, 8, 6, 0)),
            capture("c", at: date(2026, 9, 8, 6, 5)),
            capture("c", at: date(2026, 9, 8, 6, 10)),
        ]
        let records = summary(.allTime, captures, now: date(2026, 9, 8, 20)).records

        let biggest = try #require(records.biggestDay)
        #expect(biggest.day == date(2026, 9, 8, 0))
        #expect(biggest.songCount == 5)
        let repeated = try #require(records.mostRepeated)
        #expect(repeated.title == "c")
        #expect(repeated.count == 3)
        // 2 AM is later in the night than 11 PM.
        #expect(records.latestListen == date(2026, 9, 8, 2))
        #expect(records.earliestListen == date(2026, 9, 8, 6))
        // One artist all day isn't a record for variety.
        #expect(records.mostArtistsDay == nil)
    }

    @Test("records need more than one day before they're shown")
    func recordsNeedTwoDays() {
        let oneDay = [
            capture("a", at: date(2026, 9, 8, 9)),
            capture("b", at: date(2026, 9, 8, 10)),
        ]
        let twoDays = oneDay + [capture("c", at: date(2026, 9, 7, 9))]

        #expect(!summary(.allTime, oneDay, now: date(2026, 9, 8, 20)).recordsAreInformative)
        #expect(summary(.allTime, twoDays, now: date(2026, 9, 8, 20)).recordsAreInformative)
    }
}
