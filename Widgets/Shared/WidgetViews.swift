import WidgetKit
import SwiftUI
import TracksCore

/// Artwork, or a placeholder when there is none.
///
/// Without `widgetAccentedRenderingMode(.fullColor)`, a tinted or clear Home Screen draws
/// covers as white rectangles.
struct WidgetArtwork: View {
    let data: Data?
    /// Nil fills the width it's offered, as a square.
    var size: CGFloat? = 44

    var body: some View {
        if let size {
            cover
                .frame(width: size, height: size)
                .clipShape(.rect(cornerRadius: size / 7))
        } else {
            // Clear, so the square takes its size from the width alone.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { cover }
                .clipShape(.rect(cornerRadius: 8))
        }
    }

    private var cover: some View {
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
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
                .coverBackground(capture.coverColor)
        } else {
            WidgetEmptyState(isStoreReadable: entry.isStoreReadable, compact: true)
                .widgetURL(DeepLink.history.url)
                .containerBackground(.fill.tertiary, for: .widget)
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

/// Nothing played yet (Last Played, `compact`) or today (Today), or the store couldn't be read.
struct WidgetEmptyState: View {
    let isStoreReadable: Bool
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: isStoreReadable ? "music.note.list" : "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .widgetAccentable()
            // Last Played shows the last song from any day, so it's only empty before the first.
            Text(isStoreReadable ? (compact ? "Nothing played yet" : "Nothing played today") : "Can't read your history")
                .font(compact ? .caption : .callout)
                .foregroundStyle(.secondary)
            if !isStoreReadable {
                Text("Open Tracks once to set it up.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
