import WidgetKit
import SwiftUI
import TracksCore

/// Artwork, or a placeholder when there is none.
///
/// Without `widgetAccentedRenderingMode(.fullColor)`, a tinted or clear Home Screen draws
/// covers as white rectangles.
struct WidgetArtwork: View {
    let data: Data?
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let data, let image = platformImage(from: data) {
                // `widgetAccentedRenderingMode` only exists on `Image`, so it has to come
                // before `aspectRatio` turns this into `some View`.
                image
                    .resizable()
                    .widgetAccentedRenderingMode(.fullColor)
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size / 7))
        // A cover says what someone listened to as plainly as the title does. Redacted on a
        // locked device when they've asked for that, in the same square.
        .privacySensitive()
        // The title and artist beside it already say what the song is.
        .accessibilityHidden(true)
    }

    private func platformImage(from data: Data) -> Image? {
        #if os(macOS)
        NSImage(data: data).map(Image.init(nsImage:))
        #else
        UIImage(data: data).map(Image.init(uiImage:))
        #endif
    }
}

struct LastCapturedView: View {
    let entry: CaptureEntry

    var body: some View {
        if let capture = entry.lastPlayed {
            LastPlayedCard(capture: capture)
                // A small widget has one tap target, so the whole card opens the song.
                .widgetURL(DeepLink.song(title: capture.title, artistName: capture.artistName).url)
        } else {
            WidgetEmptyState(isStoreReadable: entry.isStoreReadable, compact: true)
                .widgetURL(DeepLink.history.url)
        }
    }
}

/// Today's listening, plus what "Play back" will play next when that's on in Settings.
struct TodayOnRadioView: View {
    let entry: CaptureEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if entry.today.isEmpty {
                WidgetEmptyState(isStoreReadable: entry.isStoreReadable, compact: false)
            } else if let upNext = entry.upNext {
                if family == .systemLarge {
                    StackedUpNextLayout(today: entry.today, upNext: upNext)
                } else if let latest = entry.today.first {
                    SplitUpNextLayout(latest: latest, upNext: upNext)
                }
            } else {
                TodaySection(
                    captures: entry.today,
                    rowStyle: family == .systemLarge ? .regular : .compact,
                    showsPlayButton: true
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        // Songs open themselves; anywhere else opens today's history.
        .widgetURL(DeepLink.history.url)
    }
}

/// Nothing captured today, or the store couldn't be read.
struct WidgetEmptyState: View {
    let isStoreReadable: Bool
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: isStoreReadable ? "radio" : "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Text(isStoreReadable ? "Nothing captured today" : "Can't read captures")
                .font(compact ? .caption : .callout)
                .foregroundStyle(.secondary)
            if !compact {
                Text(isStoreReadable
                     ? "Play an Apple Music radio station."
                     : "Open Tracks once to set it up.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
