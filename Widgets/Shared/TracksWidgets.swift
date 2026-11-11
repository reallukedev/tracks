import WidgetKit
import SwiftUI
import AppIntents
import TracksCore

@main
struct TracksWidgetBundle: WidgetBundle {
    var body: some Widget {
        ListeningWidget()
        TopSongsWidget()
        LastCapturedWidget()
        TodayOnRadioWidget()
        PlayInTracksControl()
        SaveRadioSongControl()
        IdentifySongControl()
        PlayBackTodayControl()
    }
}

/// The most recent capture, whatever it came from.
struct LastCapturedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: WidgetKind.lastPlayed,
            provider: CaptureTimelineProvider(content: .lastPlayed)
        ) { entry in
            // Sets its own background, from the cover.
            LastCapturedView(entry: entry)
                .tint(.tracks)
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
