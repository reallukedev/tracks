import WidgetKit
import SwiftUI
import TracksCore

/// The songs you've played most over the last seven days, as covers.
struct TopSongsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.topSongs, provider: TopSongsProvider()) { entry in
            TopSongsView(entry: entry)
                .tint(.tracks)
        }
        .configurationDisplayName("Top Songs")
        .description("What you've played most over the last seven days.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct TopSongsEntry: TimelineEntry {
    let date: Date
    /// Most played first. The first has its cover's colour.
    let songs: [WidgetCapture]
    let isStoreReadable: Bool

    static func sample(count: Int) -> TopSongsEntry {
        let songs = [
            ("Northern Lights", "The Lanterns", 0.02),
            ("Tidewater", "June Atlas", 0.55),
            ("Glasshouse", "Ocean Avenue", 0.32),
            ("Paper Planes at Dusk", "Mira Vale", 0.78),
        ]
        .prefix(count)
        .enumerated()
        .map { index, song in
            WidgetCapture(
                id: "sample-top-\(index)", title: song.0, artistName: song.1,
                capturedAt: .now, artwork: SampleArtwork.cover(hue: song.2)
            )
        }
        return TopSongsEntry(date: .now, songs: Self.colouringFirst(songs), isStoreReadable: true)
    }

    static func colouringFirst(_ songs: [WidgetCapture]) -> [WidgetCapture] {
        guard let first = songs.first else { return songs }
        return [first.withCoverColor()] + songs.dropFirst()
    }
}

struct TopSongsProvider: TimelineProvider {
    func placeholder(in context: Context) -> TopSongsEntry {
        let count = Self.count(for: context.family)
        let songs = (0..<count).map { index in
            WidgetCapture(id: "placeholder-\(index)", title: "Song Title", artistName: "Artist Name", capturedAt: .now)
        }
        return TopSongsEntry(date: .now, songs: songs, isStoreReadable: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (TopSongsEntry) -> Void) {
        let count = Self.count(for: context.family)
        let isGallery = context.isPreview
        Task {
            let entry = await entry(count: count, now: .now)
            // The gallery shows a sample rather than an empty week.
            completion(isGallery && entry.songs.isEmpty ? .sample(count: count) : entry)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TopSongsEntry>) -> Void) {
        let count = Self.count(for: context.family)
        Task {
            let now = Date.now
            let entry = await entry(count: count, now: now)
            // The app reloads this when the order changes (`WidgetRefresher`). This is for
            // rows synced from another device, and for songs falling out of the seven days,
            // which happens at midnight.
            let calendar = Calendar.current
            let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            let next = min(now.addingTimeInterval(60 * 60), midnight.addingTimeInterval(60))
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    /// Small shows the top song alone.
    private static func count(for family: WidgetFamily) -> Int {
        family == .systemSmall ? 1 : WidgetReading.mostTopSongs
    }

    private func entry(count: Int, now: Date) async -> TopSongsEntry {
        guard let tallies = read(count: count, now: now) else {
            return TopSongsEntry(date: now, songs: [], isStoreReadable: false)
        }
        let covers = await CaptureTimelineProvider.covers(at: Set(tallies.compactMap(\.artworkURL)))
        let songs = tallies.map { tally in
            WidgetCapture(
                id: tally.id, title: tally.title, artistName: tally.artistName,
                capturedAt: tally.lastHeard, artwork: tally.artworkURL.flatMap { covers[$0] }
            )
        }
        return TopSongsEntry(date: now, songs: TopSongsEntry.colouringFirst(songs), isStoreReadable: true)
    }

    /// Nil when the database can't be read, so the widget says so instead of an empty week.
    @MainActor
    private func read(count: Int, now: Date) -> [SongTally]? {
        guard let store = try? TracksStore(readOnly: true), case .appGroup = store.backing else { return nil }
        return try? store.widgetTopSongs(limit: count, now: now)
    }
}

struct TopSongsView: View {
    let entry: TopSongsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if entry.songs.isEmpty {
            empty
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(DeepLink.summary.url)
        } else if family == .systemSmall, let top = entry.songs.first {
            small(top)
                .coverBackground(top.coverColor)
                .widgetURL(DeepLink.song(title: top.title, artistName: top.artistName).url)
        } else {
            medium
                .containerBackground(.fill.tertiary, for: .widget)
                // Songs open themselves; the header opens the week.
                .widgetURL(DeepLink.summary.url)
        }
    }

    private var header: some View {
        WidgetSectionHeader(title: "Top Songs", systemImage: "chart.bar.fill")
    }

    private func small(_ top: WidgetCapture) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetArtwork(data: top.artwork, size: 56)
                // Lifts the cover off a background of its own colour.
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 2) {
                Text("Top Song")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .widgetAccentable()
                Text(top.title)
                    .font(.headline)
                    .lineLimit(2)
                    .privacySensitive()
                Text(top.artistName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .privacySensitive()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Top song: \(top.title) by \(top.artistName)")
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack(alignment: .top, spacing: 10) {
                ForEach(0..<WidgetReading.mostTopSongs, id: \.self) { index in
                    if index < entry.songs.count {
                        tile(entry.songs[index], rank: index + 1)
                    } else {
                        // Keeps the first covers their size when the week has fewer songs.
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func tile(_ song: WidgetCapture, rank: Int) -> some View {
        Link(destination: DeepLink.song(title: song.title, artistName: song.artistName).url) {
            VStack(alignment: .leading, spacing: 4) {
                WidgetArtwork(data: song.artwork, size: nil)
                VStack(alignment: .leading, spacing: 0) {
                    Text(song.title)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                    Text(song.artistName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .privacySensitive()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Number \(rank): \(song.title) by \(song.artistName)")
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The header says what the widget is; small has no room for it, so the symbol does.
            if family == .systemSmall {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(.secondary)
                    .widgetAccentable()
            } else {
                header
            }
            Spacer(minLength: 0)
            Text(entry.isStoreReadable ? "Nothing played this week" : "Open Tracks once to set it up.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

#Preview("Small", as: .systemSmall) {
    TopSongsWidget()
} timeline: {
    TopSongsEntry.sample(count: 1)
    TopSongsEntry(date: .now, songs: [], isStoreReadable: true)
}

#Preview("Medium", as: .systemMedium) {
    TopSongsWidget()
} timeline: {
    TopSongsEntry.sample(count: 4)
    TopSongsEntry.sample(count: 2)
    TopSongsEntry(date: .now, songs: [], isStoreReadable: true)
    TopSongsEntry(date: .now, songs: [], isStoreReadable: false)
}
