import Testing
import Foundation
@testable import TracksCore

@Suite("Collection history")
struct CollectionHistoryTests {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func facts(_ plays: Int, lastHeardHours hours: Double = 0) -> SongFacts {
        SongFacts(plays: plays, radioPlays: 0, firstHeard: start, lastHeard: start.addingTimeInterval(hours * 3_600))
    }

    @Test("an empty collection says nothing")
    func empty() {
        #expect(CollectionHistory.summary(songIdentities: [], facts: ["a": facts(3)]) == nil)
    }

    @Test("a collection with nothing played is new to you")
    func nothingHeard() throws {
        let history = try #require(CollectionHistory.summary(songIdentities: ["a", "b", "c"], facts: ["other": facts(4)]))
        #expect(history == CollectionHistory(heard: 0, total: 3, lastHeard: nil))
        #expect(history.isNew)
        #expect(history.hasHeardAll == false)
    }

    @Test("counts the songs heard and when any was last heard")
    func someHeard() throws {
        let history = try #require(CollectionHistory.summary(
            songIdentities: ["a", "b", "c", "d"],
            facts: ["a": facts(2, lastHeardHours: 5), "c": facts(9, lastHeardHours: 1), "z": facts(40, lastHeardHours: 50)]
        ))
        #expect(history.heard == 2)
        #expect(history.total == 4)
        #expect(history.lastHeard == start.addingTimeInterval(5 * 3_600))
        #expect(history.isNew == false)
        #expect(history.hasHeardAll == false)
    }

    @Test("a song in a playlist twice counts once")
    func duplicates() throws {
        let history = try #require(CollectionHistory.summary(songIdentities: ["a", "b", "a"], facts: ["a": facts(5), "b": facts(1)]))
        #expect(history.total == 2)
        #expect(history.heard == 2)
        #expect(history.hasHeardAll)
    }

    @Test("songs the catalog couldn't name don't count", arguments: [[""], ["", ""]])
    func unnamed(identities: [String]) {
        #expect(CollectionHistory.summary(songIdentities: identities, facts: ["": facts(2)]) == nil)
    }

    @Test("facts of no plays don't make a song heard")
    func zeroPlays() throws {
        let history = try #require(CollectionHistory.summary(songIdentities: ["a"], facts: ["a": facts(0)]))
        #expect(history.isNew)
        #expect(history.lastHeard == nil)
    }
}

@Suite("Collection history, how recently")
struct CollectionRecencyTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Wednesday, June 17, 2026, mid-afternoon.
    var now: Date { date(2026, 6, 17, hour: 15) }

    func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func recency(lastHeard: Date?) -> CollectionHistory.Recency? {
        CollectionHistory(heard: 1, total: 2, lastHeard: lastHeard).recency(now: now, calendar: calendar)
    }

    @Test("nothing heard has no recency")
    func never() {
        #expect(recency(lastHeard: nil) == nil)
    }

    @Test("earlier today, or a little ahead of a clock set wrong, is today")
    func today() {
        #expect(recency(lastHeard: date(2026, 6, 17, hour: 0)) == .today)
        #expect(recency(lastHeard: date(2026, 6, 18, hour: 2)) == .today)
    }

    @Test("just after midnight yesterday is yesterday, not two days by the clock")
    func yesterday() {
        #expect(recency(lastHeard: date(2026, 6, 16, hour: 0)) == .yesterday)
    }

    @Test("within the week it's the day's name", arguments: [2, 6])
    func weekday(daysAgo: Int) {
        let heard = date(2026, 6, 17 - daysAgo)
        #expect(recency(lastHeard: heard) == .weekday(heard))
    }

    @Test("a week or more ago this year it's the month")
    func month() {
        let heard = date(2026, 6, 10)
        #expect(recency(lastHeard: heard) == .month(heard))
        let january = date(2026, 1, 1, hour: 0)
        #expect(recency(lastHeard: january) == .month(january))
    }

    @Test("before this year it's the year")
    func year() {
        #expect(recency(lastHeard: date(2025, 12, 31, hour: 23)) == .year(2025))
    }
}
