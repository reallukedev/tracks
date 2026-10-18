import WidgetKit
import SwiftUI
import AppIntents
import TracksCore

@main
struct TracksWidgetBundle: WidgetBundle {
    var body: some Widget {
        ListeningWidget()
        LastCapturedWidget()
        TodayOnRadioWidget()
        // Gated here because a `@main` type can't be `@available`, and gating the bundle
        // would drop the other widgets on older systems.
        if #available(iOS 18.0, macOS 26.0, *) {
            PlayBackTodayControl()
        }
    }
}

/// The most recent capture, whatever it came from.
struct LastCapturedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: WidgetKind.lastPlayed,
            provider: CaptureTimelineProvider(content: .lastPlayed)
        ) { entry in
            LastCapturedView(entry: entry)
                .tint(.tracks)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Last Played")
        .description("The last song Tracks kept.")
        .supportedFamilies([.systemSmall])
    }
}

/// Today's listening, what play-back will play next, and a button to play it.
struct TodayOnRadioWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: WidgetKind.today,
            provider: CaptureTimelineProvider(content: .today)
        ) { entry in
            TodayOnRadioView(entry: entry)
                .tint(.tracks)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Today")
        // Play back is radio-only, so the description says so.
        .description("What you've listened to today, and the radio songs up next to play back.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
