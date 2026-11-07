import WidgetKit
import Foundation
import SwiftData
import TracksCore

/// Reads today's captures for the widget.
///
/// Opens the store read-only: the app holds it read-write, and a second read-write open
/// falls back to an empty in-memory store. Fetches here instead of `@Query` because a widget
/// view renders once into a snapshot.
struct CaptureTimelineProvider: TimelineProvider {
    /// What a widget shows, which decides what to fetch.
    enum Content: Sendable {
        case lastPlayed
        case today
    }

    let content: Content

    func placeholder(in context: Context) -> CaptureEntry {
        .placeholder(capacity: capacity(for: context.family))
    }

    func getSnapshot(in context: Context, completion: @escaping (CaptureEntry) -> Void) {
        let capacity = capacity(for: context.family)
        let isGallery = context.isPreview
        Task {
            let entry = await entry(capacity: capacity)
            // In the gallery, show a sample rather than an empty widget.
            let isEmpty = entry.lastPlayed == nil && entry.today.isEmpty
            completion(isGallery && isEmpty ? .sample(capacity: capacity) : entry)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CaptureEntry>) -> Void) {
        let capacity = capacity(for: context.family)
        Task {
            let now = Date.now
            let entry = await entry(capacity: capacity, now: now)
            // The app reloads this when a save changes what it shows (`WidgetRefresher`). The
            // midnight entry empties Today on time even if the system delays the next reload,
            // and the reload picks up what the app can't see: rows synced from another device
            // while it isn't running. Every fifteen minutes asked for more reloads than
            // WidgetKit gives a widget in a day (roughly 40 to 70), and it skips the rest.
            let calendar = Calendar.current
            let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            let next = min(now.addingTimeInterval(30 * 60), midnight.addingTimeInterval(60))
            completion(Timeline(entries: [entry, entry.startingNewDay(at: midnight)], policy: .after(next)))
        }
    }

    /// Read on every request so the Up Next setting applies on the next reload.
    private func capacity(for family: WidgetFamily) -> WidgetCapacity {
        switch content {
        case .lastPlayed:
            .lastPlayed
        case .today:
            .today(family: family, showsUpNext: CaptureSettings().showsUpNextInWidget)
        }
    }

    private func entry(capacity: WidgetCapacity, now: Date = .now) async -> CaptureEntry {
        guard let reading = read(capacity, now: now) else {
            return CaptureEntry(
                date: now,
                lastPlayed: nil,
                today: [],
                upNext: nil,
                isStoreReadable: false
            )
        }

        let covers = await Self.artwork(for: reading.allSongs)
        func widgetCapture(_ snapshot: CaptureSnapshot) -> WidgetCapture {
            WidgetCapture(snapshot: snapshot, artwork: snapshot.artworkURL.flatMap { covers[$0] })
        }

        return CaptureEntry(
            date: now,
            lastPlayed: reading.lastPlayed.map(widgetCapture),
            today: reading.today.map(widgetCapture),
            upNext: reading.upNext.map { queue in
                UpNextQueue(songs: queue.songs.map(widgetCapture), totalCount: queue.totalCount)
            },
            isStoreReadable: true
        )
    }

    /// Nil when the database can't be read, so the widget says so instead of showing an
    /// empty day. The app runs the same reading to decide when to reload.
    @MainActor
    private func read(_ capacity: WidgetCapacity, now: Date) -> WidgetReading? {
        guard let store = try? TracksStore(readOnly: true) else { return nil }
        // In-memory means the real database wasn't reached.
        guard case .appGroup = store.backing else { return nil }
        return try? store.widgetReading(todayLimit: capacity.today, upNextLimit: capacity.upNext, now: now)
    }

    /// Every cover the entry needs, fetched in parallel and once per URL. Seven covers at up
    /// to five seconds each, one after another, could outlast the widget's render budget.
    private static func artwork(for songs: [CaptureSnapshot]) async -> [String: Data] {
        let urls = Set(songs.compactMap(\.artworkURL))
        return await withTaskGroup(of: (String, Data?).self) { group in
            for url in urls {
                group.addTask { (url, await artwork(at: url)) }
            }
            var covers: [String: Data] = [:]
            for await (url, data) in group {
                covers[url] = data
            }
            return covers
        }
    }

    private nonisolated static func artwork(at string: String) async -> Data? {
        guard let url = URL(string: string) else { return nil }
        // A slow image is dropped and the row shows a placeholder.
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        return try? await URLSession.shared.data(for: request).0
    }
}
