import Testing
import Foundation
@testable import TracksCore

@Suite("Song story")
struct SongStoryTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Wednesday 23 September 2026, 21:00 UTC.
    var now: Date { date(2026, 9, 23, 21) }

    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func play(_ title: String, at date: Date, kind: CaptureKind = .onDemand, station: String? = nil) -> CaptureStat {
        CaptureStat(songKey: title, title: title, artistName: "Artist", capturedAt: date, stationName: station, kind: kind)
    }

    var songIdentity: String { HistoryImport.key(title: "Song", artistName: "Artist") }

    func story(_ captures: [CaptureStat], listeningSince: Date? = nil) -> SongStory? {
        SongStories.story(of: songIdentity, in: ListeningHistory(captures), listeningSince: listeningSince, now: now, calendar: calendar)
    }

    @Test("a song never kept has no story")
    func neverHeard() {
        #expect(story([play("Other", at: now)]) == nil)
    }

    @Test("counts plays, and knows the first came from the radio")
    func firstFromRadio() throws {
        let result = try #require(story([
            play("Song", at: date(2025, 3, 12, 8), kind: .radio, station: "KEXP"),
            play("Song", at: date(2026, 9, 1, 20)),
            play("Song", at: date(2026, 9, 20, 19)),
        ]))
        #expect(result.plays == 3)
        #expect(result.radioPlays == 1)
        #expect(result.firstHeard == date(2025, 3, 12, 8))
        #expect(result.firstStation == "KEXP")
        #expect(result.lastHeard == date(2026, 9, 20, 19))
    }

    @Test("an on-demand first play has no station")
    func firstOnDemand() throws {
        let result = try #require(story([play("Song", at: date(2026, 1, 1, 9), station: "Ignored")]))
        #expect(result.firstStation == nil)
    }

    @Test("a play kept during this listening isn't the last time it was heard")
    func lastHeardBeforeListening() throws {
        let started = date(2026, 9, 23, 20)
        let earlier = try #require(story([
            play("Song", at: date(2026, 9, 18, 9)),
            play("Song", at: started.addingTimeInterval(40)),
        ], listeningSince: started))
        #expect(earlier.lastHeard == date(2026, 9, 18, 9))
        #expect(earlier.plays == 2)

        let firstTime = try #require(story([play("Song", at: started.addingTimeInterval(40))], listeningSince: started))
        #expect(firstTime.lastHeard == nil)
    }

    @Test("twelve months of plays, this month last, older plays left out")
    func months() throws {
        let result = try #require(story([
            play("Song", at: date(2025, 9, 30, 12)),
            play("Song", at: date(2025, 10, 2, 12)),
            play("Song", at: date(2026, 9, 1, 12)),
            play("Song", at: date(2026, 9, 3, 12)),
        ]))
        #expect(result.months.count == 12)
        #expect(result.months.first?.start == date(2025, 10, 1, 0))
        #expect(result.months.first?.plays == 1)
        #expect(result.months.last?.start == date(2026, 9, 1, 0))
        #expect(result.months.last?.plays == 2)
        #expect(result.busiestMonth == 2)
    }

    @Test("a usual time needs enough plays, most of them in one part of the day")
    func usualTime() throws {
        let evenings = (1...4).map { play("Song", at: date(2026, 9, $0, 20)) }
        #expect(try #require(story(evenings)).usualTime == .evening)

        let tooFew = (1...3).map { play("Song", at: date(2026, 9, $0, 20)) }
        #expect(try #require(story(tooFew)).usualTime == nil, "Three plays aren't a habit")

        let spread = [8, 13, 20, 23].enumerated().map { play("Song", at: date(2026, 9, $0.offset + 1, $0.element)) }
        #expect(try #require(story(spread)).usualTime == nil, "No part of the day holds half")
    }

    @Test("ranks it among this month's songs, ties sharing a place")
    func rank() throws {
        let result = try #require(story([
            play("Top", at: date(2026, 9, 2, 10)),
            play("Top", at: date(2026, 9, 3, 10)),
            play("Top", at: date(2026, 9, 4, 10)),
            play("Tied", at: date(2026, 9, 5, 10)),
            play("Tied", at: date(2026, 9, 6, 10)),
            play("Song", at: date(2026, 9, 7, 10)),
            play("Song", at: date(2026, 9, 8, 10)),
            // Last month's plays don't count toward this month's chart.
            play("Other", at: date(2026, 8, 30, 10)),
            play("Other", at: date(2026, 8, 30, 11)),
            play("Other", at: date(2026, 8, 30, 12)),
        ]))
        #expect(result.rankThisMonth == 2)
    }

    @Test("not played this month, no rank")
    func noRank() throws {
        let result = try #require(story([play("Song", at: date(2026, 8, 1, 10))]))
        #expect(result.rankThisMonth == nil)
    }
}
