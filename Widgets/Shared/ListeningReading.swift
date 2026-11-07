import Foundation
import SwiftData
import TracksCore

/// What the Listening widget reads, without loading the whole history.
///
/// A widget extension gets about 30MB. Fetching every `Capture` to draw seven bars and a
/// streak ran past that once a history got long, and the system killed the extension, which
/// leaves the widget showing whatever it last drew.
@MainActor
enum ListeningReading {
    /// How far back to read in one go when a streak runs past the week already fetched.
    static let streakChunkDays = 31

    /// The last `days` days of listening, today included.
    ///
    /// Enough for everything the widget shows except the streak: `recentDays` covers the same
    /// days, a calendar week never starts more than six days ago, and a listening estimate
    /// measures a song against the one after it, which is inside the window too.
    static func recentHistory(
        days: Int,
        in context: ModelContext,
        calendar: Calendar,
        now: Date
    ) throws -> (history: ListeningHistory, start: Date) {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        var descriptor = TracksStore.allCaptures(since: start)
        // Only what `CaptureStat` is built from. Artwork URLs and the queue bookkeeping aren't.
        descriptor.propertiesToFetch = [
            \.songKey, \.title, \.artistName, \.albumTitle, \.capturedAt, \.kindRawValue,
        ]
        let rows = try context.fetch(descriptor)
        let history = ListeningHistory(rows.map { row in
            CaptureStat(
                songKey: row.songKey, title: row.title, artistName: row.artistName,
                albumTitle: row.albumTitle, capturedAt: row.capturedAt, kind: row.kind
            )
        })
        return (history, start)
    }

    /// Consecutive days with listening, counting back from today, or from yesterday when
    /// nothing has played yet today. Matches `StatsCalculator.streak(in:)`'s `current`.
    ///
    /// Starts from the days already read, which run back to `knownFrom`, and only reads
    /// further while the streak reaches the edge of what's known: a month at a time, just the
    /// capture dates, each month in its own context so its rows are let go before the next.
    static func currentStreak(
        knownDays: Set<Date>,
        knownFrom: Date,
        container: ModelContainer,
        calendar: Calendar,
        now: Date
    ) throws -> Int {
        var days = knownDays
        var readFrom = knownFrom
        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
              var cursor = days.contains(today) ? today : (days.contains(yesterday) ? yesterday : nil)
        else { return 0 }

        var streak = 0
        while true {
            if cursor < readFrom {
                guard let chunkStart = calendar.date(byAdding: .day, value: -streakChunkDays, to: readFrom)
                else { break }
                let found = try listeningDays(from: chunkStart, to: readFrom, in: container, calendar: calendar)
                // Nothing at all in a month means the history ends here.
                if found.isEmpty { break }
                days.formUnion(found)
                readFrom = chunkStart
            }
            guard days.contains(cursor) else { break }
            streak += 1
            guard let before = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = before
        }
        return streak
    }

    /// The start of each day in `start..<end` with at least one capture.
    private static func listeningDays(
        from start: Date,
        to end: Date,
        in container: ModelContainer,
        calendar: Calendar
    ) throws -> Set<Date> {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Capture>(
            predicate: #Predicate { $0.capturedAt >= start && $0.capturedAt < end }
        )
        descriptor.propertiesToFetch = [\.capturedAt]
        return Set(try context.fetch(descriptor).map { calendar.startOfDay(for: $0.capturedAt) })
    }
}
