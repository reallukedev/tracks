import WidgetKit
import SwiftUI
import SwiftData
import Charts
import TracksCore

/// The last seven days of listening at a glance: time, a bar per day, and the streak.
struct ListeningWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.listening, provider: ListeningProvider()) { entry in
            ListeningWidgetView(entry: entry)
                .tint(.tracks)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Listening")
        .description("How much you've listened over the last seven days.")
        .supportedFamilies(Self.families)
    }

    private static var families: [WidgetFamily] {
        #if os(iOS)
        [.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline]
        #else
        [.systemSmall, .systemMedium]
        #endif
    }
}

struct ListeningEntry: TimelineEntry {
    let date: Date
    let todaySeconds: TimeInterval
    let todaySongs: Int
    let weekSeconds: TimeInterval
    /// The last seven days, oldest first, today last.
    let days: [TimeBucket]
    let streak: Int
    let topArtist: String?
    let isStoreReadable: Bool

    static let sample = ListeningEntry(
        date: .now,
        todaySeconds: 84 * 60,
        todaySongs: 23,
        weekSeconds: 11 * 3600 + 20 * 60,
        days: [52, 96, 71, 118, 64, 131, 84].enumerated().map { index, minutes in
            TimeBucket(
                start: Calendar.current.date(byAdding: .day, value: index - 6, to: Calendar.current.startOfDay(for: .now)) ?? .now,
                count: Int(minutes / 4),
                seconds: Double(minutes) * 60
            )
        },
        streak: 12,
        topArtist: "Mara Solis",
        isStoreReadable: true
    )
}

struct ListeningProvider: TimelineProvider {
    func placeholder(in context: Context) -> ListeningEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (ListeningEntry) -> Void) {
        Task { @MainActor in
            let entry = read()
            // The gallery shows a sample rather than an empty week.
            completion(context.isPreview && entry.todaySongs == 0 && entry.weekSeconds == 0 ? .sample : entry)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ListeningEntry>) -> Void) {
        Task { @MainActor in
            let now = Date.now
            let calendar = Calendar.current
            let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            // The app reloads this when a song is kept or removed. The midnight entry moves the
            // bars along a day even if the system puts the next reload off, and the reload is
            // for rows synced from another device while the app is closed.
            let entries = read(now: now, alsoAt: midnight, calendar: calendar)
            let next = min(now.addingTimeInterval(30 * 60), midnight.addingTimeInterval(60))
            completion(Timeline(entries: entries, policy: .after(next)))
        }
    }

    @MainActor
    private func read(now: Date = .now, calendar: Calendar = .current) -> ListeningEntry {
        read(now: now, alsoAt: nil, calendar: calendar)[0]
    }

    /// The entry for `now`, then one for `later` if given, both from one read.
    ///
    /// `later` must be no more than a day on: its seven days are then inside the ones read
    /// for `now`.
    @MainActor
    private func read(now: Date, alsoAt later: Date?, calendar: Calendar) -> [ListeningEntry] {
        let dayCount = 7
        guard let store = try? TracksStore(readOnly: true), case .appGroup = store.backing,
              let recent = try? ListeningReading.recentHistory(
                  days: dayCount, in: store.context, calendar: calendar, now: now
              )
        else {
            return [now, later].compactMap(\.self).map { date in
                ListeningEntry(date: date, todaySeconds: 0, todaySongs: 0, weekSeconds: 0, days: [],
                               streak: 0, topArtist: nil, isStoreReadable: false)
            }
        }

        let history = recent.history
        let knownDays = Set(history.captures.map { calendar.startOfDay(for: $0.capturedAt) })
        let streak = (try? ListeningReading.currentStreak(
            knownDays: knownDays, knownFrom: recent.start, container: store.container,
            calendar: calendar, now: now
        )) ?? 0

        func entry(at date: Date, streak: Int) -> ListeningEntry {
            let days = StatsCalculator.recentDays(dayCount, history: history, calendar: calendar, now: date)
            let week = StatsCalculator.summary(range: .week, history: history, sessions: [], calendar: calendar, now: date)
            return ListeningEntry(
                date: date,
                todaySeconds: days.last?.seconds ?? 0,
                todaySongs: days.last?.count ?? 0,
                weekSeconds: days.reduce(0) { $0 + $1.seconds },
                days: days,
                streak: streak,
                topArtist: week.topArtists.first?.name,
                isStoreReadable: true
            )
        }

        var entries = [entry(at: now, streak: streak)]
        if let later {
            // Tomorrow nothing has played yet, so the streak counts back from today and is the
            // same length, unless nothing played today either, which ends it.
            let playedToday = knownDays.contains(calendar.startOfDay(for: now))
            entries.append(entry(at: later, streak: playedToday ? streak : 0))
        }
        return entries
    }
}

struct ListeningWidgetView: View {
    let entry: ListeningEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Label("\(Self.duration(entry.todaySeconds)) today", systemImage: "headphones")
                    .privacySensitive()
            case .accessoryCircular:
                circular
            case .accessoryRectangular:
                rectangular
            case .systemMedium:
                medium
            default:
                small
            }
        }
        .widgetURL(DeepLink.summary.url)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Text(Self.duration(entry.weekSeconds))
                .font(.title)
                .fontWeight(.bold)
                .fontDesign(.rounded)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .privacySensitive()
            Text("last 7 days")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            bars(showsLabels: false)
                .frame(height: 34)
        }
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                header
                Spacer(minLength: 2)
                Text(Self.duration(entry.weekSeconds))
                    .font(.title)
                    .fontWeight(.bold)
                    .fontDesign(.rounded)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .privacySensitive()
                Text("last 7 days")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                if entry.streak > 1 {
                    Label("^[\(entry.streak) day](inflect: true) in a row", systemImage: "flame.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .privacySensitive()
                } else if let artist = entry.topArtist {
                    Text("Top: \(artist)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .privacySensitive()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            bars(showsLabels: true)
                .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        Label("Listening", systemImage: "headphones")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tint)
            .lineLimit(1)
    }

    @ViewBuilder
    private func bars(showsLabels: Bool) -> some View {
        if entry.days.isEmpty {
            Text(entry.isStoreReadable ? "Nothing yet this week" : "Open Tracks once to set it up.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Chart(entry.days) { day in
                BarMark(
                    x: .value("Day", day.start, unit: .day),
                    y: .value("Minutes", max(day.seconds / 60, 0.001))
                )
                .foregroundStyle(Calendar.current.isDateInToday(day.start) ? AnyShapeStyle(Color.tracks) : AnyShapeStyle(Color.tracks.opacity(0.45)))
                .cornerRadius(2)
            }
            .chartYAxis(.hidden)
            .chartXAxis(showsLabels ? .automatic : .hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                }
            }
            .widgetAccentable()
            // The bars give away how much was played each day as surely as the total does.
            // The frame is set by the caller, so a redacted chart takes the same room.
            .privacySensitive()
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label("Listening", systemImage: "headphones")
                .font(.caption.weight(.semibold))
                .widgetAccentable()
            // Lock Screen accessories are the likeliest to be seen by someone else, so the
            // numbers are redacted when the device is locked and that's asked for. The label
            // above stays, so the widget still says what it is.
            Text("\(Self.duration(entry.todaySeconds)) today")
                .font(.headline)
                .privacySensitive()
            Text(entry.streak > 1 ? "^[\(entry.streak) day](inflect: true) in a row" : "^[\(entry.todaySongs) song](inflect: true)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .privacySensitive()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "flame.fill")
                    .font(.caption)
                    .widgetAccentable()
                Text(entry.streak.formatted())
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .privacySensitive()
            }
        }
        .accessibilityLabel("\(entry.streak)-day listening streak")
    }

    /// "3h 5m", "42m".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return Duration.seconds(Double(minutes) * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .narrow, maximumUnitCount: 2, zeroValueUnits: .hide))
            .ifEmpty("0m")
    }
}

extension Color {
    /// The app's accent. Named explicitly because a widget doesn't pick up the global
    /// accent colour the way the app does.
    static let tracks = Color("AccentColor")
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

#Preview("Small", as: .systemSmall) {
    ListeningWidget()
} timeline: {
    ListeningEntry.sample
}

#Preview("Medium", as: .systemMedium) {
    ListeningWidget()
} timeline: {
    ListeningEntry.sample
}
