import Testing
import Foundation
import TracksCore

@Suite("Summary figures and when they show")
struct StatsSummaryDerivedTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func summary(
        captures: Int = 0,
        songs: Int = 0,
        activeDays: Int = 0,
        previousCaptures: Int? = nil,
        listening: TimeInterval = 0,
        previousListening: TimeInterval? = nil,
        sessions: Int = 0,
        firstTime: Int = 0,
        topSongs: [SongTally] = [],
        topArtists: [ArtistTally] = [],
        timeline: [TimeBucket] = [],
        heatMap: [HeatCell] = [],
        sources: [SourceCount] = [],
        pace: [PacePoint] = [],
        dayParts: [DayPartCount] = [],
        listeningSessions: SessionStats = .none,
        records: ListeningRecords = .none,
        topGenres: [GenreTally] = [],
        knownGenrePlays: Int = 0,
        decades: [DecadeCount] = [],
        knownYearPlays: Int = 0,
        recentReleasePlays: Int = 0,
        periodOffset: Int = 0
    ) -> StatsSummary {
        StatsSummary(
            range: .month,
            generatedAt: t0,
            captureCount: captures,
            uniqueSongCount: songs,
            uniqueArtistCount: 0,
            listeningSeconds: listening,
            activeDays: activeDays,
            previousCaptureCount: previousCaptures,
            previousListeningSeconds: previousListening,
            sessionCount: sessions,
            firstTimeHeardCount: firstTime,
            topSongs: topSongs,
            topArtists: topArtists,
            timeline: timeline,
            heatMap: heatMap,
            sources: sources,
            pace: pace,
            dayParts: dayParts,
            listeningSessions: listeningSessions,
            records: records,
            topGenres: topGenres,
            knownGenrePlays: knownGenrePlays,
            decades: decades,
            knownYearPlays: knownYearPlays,
            recentReleasePlays: recentReleasePlays,
            periodOffset: periodOffset
        )
    }

    func buckets(_ counts: [Int]) -> [TimeBucket] {
        counts.enumerated().map { TimeBucket(start: t0.addingTimeInterval(Double($0.offset) * 86_400), count: $0.element) }
    }

    func song(_ id: String, count: Int) -> SongTally {
        SongTally(songKey: id, songID: id, title: id, artistName: "A", artworkURL: nil, count: count, firstHeard: t0)
    }

    func artist(_ name: String, count: Int) -> ArtistTally {
        ArtistTally(id: name, name: name, count: count, songCount: 1, listeningSeconds: 0, artworkURL: nil, firstHeard: t0, lastHeard: t0)
    }

    func sessions(_ count: Int) -> SessionStats {
        SessionStats(count: count, totalSeconds: 0, totalSongs: 0, longest: nil, lengths: [])
    }

    // MARK: - Rates and changes

    @Test("first-time share is nil with no captures, otherwise first-time over captures")
    func firstTimeHeardRate() {
        #expect(summary().firstTimeHeardRate == nil)
        #expect(summary(captures: 10, firstTime: 0).firstTimeHeardRate == 0.0)
        #expect(summary(captures: 10, firstTime: 10).firstTimeHeardRate == 1.0)
        #expect(summary(captures: 10, firstTime: 4).firstTimeHeardRate == 0.4)
    }

    @Test("the capture change needs a previous count and may be negative")
    func captureCountDelta() {
        #expect(summary(captures: 5).captureCountDelta == nil)
        #expect(summary(captures: 5, previousCaptures: 8).captureCountDelta == -3)
        #expect(summary(captures: 8, previousCaptures: 5).captureCountDelta == 3)
    }

    @Test("the listening change needs ten minutes before to compare with", arguments: [
        (900.0, TimeInterval?.none, Double?.none),
        (900, 599, nil),
        (900, 600, 0.5),
        (0, 1_200, -1.0),
    ])
    func listeningChange(current: TimeInterval, previous: TimeInterval?, expected: Double?) {
        #expect(summary(listening: current, previousListening: previous).listeningChange == expected)
    }

    @Test("plays per song is zero with no songs, never NaN")
    func playsPerSong() {
        #expect(summary(captures: 5, songs: 0).playsPerSong == 0)
        #expect(summary(captures: 12, songs: 4).playsPerSong == 3.0)
    }

    @Test("genre coverage is zero with no captures, otherwise known over captures")
    func genreCoverage() {
        #expect(summary(knownGenrePlays: 0).genreCoverage == 0)
        #expect(summary(captures: 20, knownGenrePlays: 5).genreCoverage == 0.25)
    }

    @Test("recent release share needs a known year")
    func recentReleaseShare() {
        #expect(summary(knownYearPlays: 0, recentReleasePlays: 0).recentReleaseShare == nil)
        #expect(summary(knownYearPlays: 12, recentReleasePlays: 3).recentReleaseShare == 0.25)
    }

    // MARK: - Peaks

    @Test("the peak bucket is the highest count, with nothing when all are empty")
    func peakBucket() {
        #expect(summary(timeline: buckets([1, 5, 2])).peakBucket?.count == 5)
        #expect(summary(timeline: buckets([1, 5, 2])).peakBucket?.start == t0.addingTimeInterval(86_400))
        #expect(summary(timeline: buckets([0, 0])).peakBucket == nil)
        #expect(summary(timeline: []).peakBucket == nil)
    }

    /// Pins the tie-break: the earlier of equal buckets.
    @Test("equal peak buckets resolve to the earlier one")
    func peakBucketTie() {
        #expect(summary(timeline: buckets([3, 1, 3])).peakBucket?.start == t0)
    }

    @Test("the busiest heat map cell, ignoring empty ones")
    func busiestCell() {
        let cells = [HeatCell(weekday: 1, hour: 9, count: 2), HeatCell(weekday: 3, hour: 20, count: 7), HeatCell(weekday: 5, hour: 1, count: 0)]
        #expect(summary(heatMap: cells).busiestCell == HeatCell(weekday: 3, hour: 20, count: 7))
        #expect(summary(heatMap: [HeatCell(weekday: 1, hour: 1, count: 0)]).busiestCell == nil)
        #expect(summary(heatMap: []).busiestCell == nil)
    }

    @Test("the busiest part of the day by seconds, earlier part on a tie, ignoring empty parts")
    func busiestDayPart() {
        let parts = [
            DayPartCount(part: .morning, count: 2, seconds: 600),
            DayPartCount(part: .afternoon, count: 1, seconds: 300),
            DayPartCount(part: .evening, count: 3, seconds: 600),
            DayPartCount(part: .night, count: 0, seconds: 900),
        ]
        #expect(summary(dayParts: parts).busiestDayPart?.part == .morning)
        #expect(summary(dayParts: parts.map { DayPartCount(part: $0.part, count: 0, seconds: $0.seconds) }).busiestDayPart == nil)
    }

    @Test("the top decade has the most plays, the older on a tie, ignoring empty ones")
    func topDecade() {
        let decades = [
            DecadeCount(decade: 2000, count: 4, seconds: 0),
            DecadeCount(decade: 1990, count: 4, seconds: 0),
            DecadeCount(decade: 1980, count: 0, seconds: 0),
        ]
        #expect(summary(decades: decades).topDecade?.decade == 1990)
        #expect(summary(decades: [DecadeCount(decade: 1980, count: 0, seconds: 0)]).topDecade == nil)
    }

    @Test("pace's previous figure comes from the last point that has happened")
    func pacePrevious() {
        let pace = [
            PacePoint(start: t0, current: 100, previous: 80),
            PacePoint(start: t0.addingTimeInterval(86_400), current: 200, previous: 150),
            PacePoint(start: t0.addingTimeInterval(2 * 86_400), current: nil, previous: 400),
        ]
        #expect(summary(pace: pace).pacePrevious == 150)
    }

    // MARK: - Gates

    @Test("a timeline says something with two buckets and at least one lit", arguments: [
        ([5], false), ([0, 1], true), ([0, 0], false), ([], false),
    ])
    func timelineIsInformative(counts: [Int], expected: Bool) {
        #expect(summary(timeline: buckets(counts)).timelineIsInformative == expected)
    }

    @Test("a heat map says something from six lit cells", arguments: [(5, false), (6, true)])
    func heatMapIsInformative(lit: Int, expected: Bool) {
        let cells = (0..<lit).map { HeatCell(weekday: 1, hour: $0, count: 1) } + [HeatCell(weekday: 2, hour: 0, count: 0)]
        #expect(summary(heatMap: cells).heatMapIsInformative == expected)
    }

    @Test("a ranking means something once a song was played more than once")
    func rankingIsMeaningful() {
        #expect(summary(topSongs: [song("a", count: 1), song("b", count: 2)]).rankingIsMeaningful)
        #expect(!summary(topSongs: [song("a", count: 1), song("b", count: 1)]).rankingIsMeaningful)
        #expect(!summary(topSongs: []).rankingIsMeaningful)
    }

    @Test("sources say something with more than one")
    func sourcesAreInformative() {
        #expect(!summary(sources: [SourceCount(kind: .radio, count: 4)]).sourcesAreInformative)
        #expect(summary(sources: [SourceCount(kind: .radio, count: 4), SourceCount(kind: .onDemand, count: 1)]).sourcesAreInformative)
    }

    @Test("pace says something with two points that have happened and some listening")
    func paceIsInformative() {
        let one = [PacePoint(start: t0, current: 100, previous: nil), PacePoint(start: t0.addingTimeInterval(86_400), current: nil, previous: nil)]
        let two = [PacePoint(start: t0, current: 100, previous: nil), PacePoint(start: t0.addingTimeInterval(86_400), current: 200, previous: nil)]
        #expect(!summary(listening: 300, pace: one).paceIsInformative)
        #expect(summary(listening: 300, pace: two).paceIsInformative)
        #expect(!summary(listening: 0, pace: two).paceIsInformative)
    }

    @Test("new versus familiar needs a timeline and five captures", arguments: [(4, false), (5, true)])
    func newVsFamiliar(captures: Int, expected: Bool) {
        #expect(summary(captures: captures, timeline: buckets([0, 1])).newVsFamiliarIsInformative == expected)
        #expect(!summary(captures: captures, timeline: buckets([1])).newVsFamiliarIsInformative)
    }

    @Test("sessions say something from two")
    func sessionsAreInformative() {
        #expect(!summary(listeningSessions: sessions(1)).sessionsAreInformative)
        #expect(summary(listeningSessions: sessions(2)).sessionsAreInformative)
    }

    @Test("records need two active days and a biggest day")
    func recordsAreInformative() {
        let records = ListeningRecords(
            biggestDay: DayRecord(day: t0, seconds: 600, songCount: 3, artistCount: 2),
            mostArtistsDay: nil, mostRepeated: nil, longestSession: nil, latestListen: nil, earliestListen: nil
        )
        #expect(summary(activeDays: 2, records: records).recordsAreInformative)
        #expect(!summary(activeDays: 1, records: records).recordsAreInformative)
        #expect(!summary(activeDays: 2, records: .none).recordsAreInformative)
    }

    @Test("genres need ten known plays and a top genre", arguments: [(9, false), (10, true)])
    func genresAreInformative(known: Int, expected: Bool) {
        let genres = [GenreTally(name: "Jazz", count: known, seconds: 0, artistCount: 1)]
        #expect(summary(topGenres: genres, knownGenrePlays: known).genresAreInformative == expected)
        #expect(!summary(topGenres: [], knownGenrePlays: known).genresAreInformative)
    }

    @Test("decades need ten known years and some decades", arguments: [(9, false), (10, true)])
    func decadesAreInformative(known: Int, expected: Bool) {
        let decades = [DecadeCount(decade: 1990, count: known, seconds: 0)]
        #expect(summary(decades: decades, knownYearPlays: known).decadesAreInformative == expected)
        #expect(!summary(decades: [], knownYearPlays: known).decadesAreInformative)
    }

    @Test("a summary is empty only with no captures and no sessions")
    func isEmpty() {
        #expect(summary().isEmpty)
        #expect(!summary(captures: 1).isEmpty)
        #expect(!summary(sessions: 1).isEmpty)
    }

    @Test("only offset zero is the current period")
    func isCurrentPeriod() {
        #expect(summary(periodOffset: 0).isCurrentPeriod)
        #expect(!summary(periodOffset: -1).isCurrentPeriod)
    }

    @Test("an artist mix of none puts every play in the other share")
    func artistMixOfNone() {
        let mix = summary(captures: 6, topArtists: [artist("A", count: 3), artist("B", count: 2), artist("C", count: 1)]).artistMix(limit: 0)
        #expect(mix.artists.isEmpty)
        #expect(mix.otherCount == 6)
    }
}
