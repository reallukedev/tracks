import Foundation
import SwiftData

/// What the Last Played and Today widgets read from the store. The app runs the same reading
/// to decide when to reload them, so the two can't disagree about what's on screen.
public struct WidgetReading: Sendable {
    /// The most recent song kept, from any day.
    public let lastPlayed: CaptureSnapshot?
    /// Today's listening, newest first.
    public let today: [CaptureSnapshot]
    /// What play-back will play next, or nil when it wasn't asked for.
    public let upNext: UpNext?

    public struct UpNext: Sendable {
        /// The first few, in play order.
        public let songs: [CaptureSnapshot]
        /// Every song owed.
        public let totalCount: Int
    }

    /// The most rows any widget shows. Widget capacities must stay within these, since the
    /// app only looks this far down when deciding whether to reload.
    public static let mostTodayRows = 6
    public static let mostUpNextRows = 3

    public var allSongs: [CaptureSnapshot] {
        [lastPlayed].compactMap(\.self) + today + (upNext?.songs ?? [])
    }
}

public extension TracksStore {
    /// Reads what a widget with this much room would show. A nil `upNextLimit` skips the
    /// queue, for when Up Next is turned off.
    func widgetReading(
        todayLimit: Int,
        upNextLimit: Int?,
        now: Date = .now,
        calendar: Calendar = .current
    ) throws -> WidgetReading {
        let lastPlayed = try context.fetch(Self.allCaptures(limit: 1)).first
        // A fetch limit of zero means no limit, so skip the fetch instead.
        let today = todayLimit > 0
            ? try context.fetch(Self.allCaptures(
                since: calendar.startOfDay(for: now),
                limit: todayLimit
            ))
            : []
        // The same query the Play button uses, so Up Next matches what Play plays.
        let upNext = try upNextLimit.map { limit in
            let owed = try playBackQueue(now: now, calendar: calendar)
            return WidgetReading.UpNext(songs: owed.prefix(limit).map(\.snapshot), totalCount: owed.count)
        }
        return WidgetReading(
            lastPlayed: lastPlayed?.snapshot,
            today: today.map(\.snapshot),
            upNext: upNext
        )
    }

    /// Everything the largest widgets could show, for comparing before and after a save.
    func widgetFaces(
        showsUpNext: Bool,
        now: Date = .now,
        calendar: Calendar = .current
    ) throws -> WidgetFaces {
        let reading = try widgetReading(
            todayLimit: WidgetReading.mostTodayRows,
            // With Up Next off, the queue isn't on screen, so play-back shouldn't reload.
            upNextLimit: showsUpNext ? WidgetReading.mostUpNextRows : nil,
            now: now,
            calendar: calendar
        )
        return WidgetFaces(reading, captureCount: try context.fetchCount(FetchDescriptor<Capture>()))
    }
}

/// The visible parts of each widget, for comparing before and after a save.
///
/// Most saves (scrobbles, playlist writes, catalog lookups, session updates) change nothing
/// a widget shows. WidgetKit limits how often a background app can reload its widgets, and
/// the Mac app is nearly always in the background, so only visible changes should reload.
public struct WidgetFaces: Equatable, Sendable {
    /// A song as a widget draws it. The row id, capture time and played-back date aren't
    /// shown, so they're left out.
    struct Song: Equatable, Sendable {
        let title: String
        let artistName: String
        let artworkURL: String?

        init(_ snapshot: CaptureSnapshot) {
            title = snapshot.title
            artistName = snapshot.artistName
            artworkURL = snapshot.artworkURL
        }
    }

    let lastPlayed: Song?
    let today: [Song]
    let upNext: [Song]?
    /// Shown as "3 songs" and "2 more".
    let upNextCount: Int?
    /// Stands in for the Listening widget. Its time, bars and streak only move when a row is
    /// added or removed, and counting is much cheaper than working them out.
    let captureCount: Int

    init(_ reading: WidgetReading, captureCount: Int) {
        lastPlayed = reading.lastPlayed.map(Song.init)
        today = reading.today.map(Song.init)
        upNext = reading.upNext?.songs.map(Song.init)
        upNextCount = reading.upNext?.totalCount
        self.captureCount = captureCount
    }

    /// The widget kinds that would look different now than at `previous`.
    public func kindsChanged(since previous: WidgetFaces) -> [String] {
        var kinds: [String] = []
        if lastPlayed != previous.lastPlayed { kinds.append(WidgetKind.lastPlayed) }
        if today != previous.today || upNext != previous.upNext || upNextCount != previous.upNextCount {
            kinds.append(WidgetKind.today)
        }
        if captureCount != previous.captureCount { kinds.append(WidgetKind.listening) }
        return kinds
    }
}
