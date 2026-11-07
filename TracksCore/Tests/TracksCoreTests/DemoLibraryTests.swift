import Testing
import Foundation
import SwiftData
@testable import TracksCore

@Suite("Demo library")
struct DemoLibraryTests {
    /// A fixed calendar, so the days the history is laid out on, and the streak and month
    /// counted from them, don't move with the machine's time zone.
    let calendar: Calendar
    /// Midday on 2026-09-13 in that calendar, well clear of either day boundary.
    let now: Date

    init() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        self.calendar = calendar
        now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 12)))
    }

    @Test func `the same seed gives the same history`() {
        #expect(
            DemoLibrary.plays(endingAt: now, calendar: calendar)
                == DemoLibrary.plays(endingAt: now, calendar: calendar)
        )
    }

    @Test func `it looks like real listening`() {
        let plays = DemoLibrary.plays(endingAt: now, calendar: calendar)
        #expect((3_000...8_000).contains(plays.count))
        #expect(plays.allSatisfy { $0.capturedAt <= now })
        #expect(Set(plays.map(\.kind)) == Set(CaptureKind.allCases))

        let history = ListeningHistory(plays.map {
            CaptureStat(songKey: $0.title, title: $0.title, artistName: $0.artistName,
                        albumTitle: $0.albumTitle, capturedAt: $0.capturedAt,
                        stationName: $0.stationName, kind: $0.kind)
        })
        #expect(StatsCalculator.streak(in: history, calendar: calendar, now: now).current >= 12)
        let month = StatsCalculator.summary(
            range: .month, history: history, sessions: [], calendar: calendar, now: now
        )
        #expect(month.insights.count >= 4)
    }

    @MainActor
    @Test func `seeding fills an in-memory store`() throws {
        let store = try TracksStore(inMemory: true)
        let plays = DemoLibrary.plays(endingAt: now, calendar: calendar, days: 20)
        try store.seedDemoData(plays)
        let captures = try store.context.fetch(FetchDescriptor<Capture>())
        #expect(captures.count == plays.count)
        #expect(try store.context.fetch(FetchDescriptor<Station>()).count <= DemoLibrary.stations.count)
        // Nothing left for the real queues to pick up.
        #expect(captures.allSatisfy { !$0.needsPlaylistWrite })
    }
}
