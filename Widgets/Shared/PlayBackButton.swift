import SwiftUI
import AppIntents
import TracksCore

/// Plays back today's radio songs. Sits on Up Next when it's showing, otherwise on Today.
///
/// A filled capsule, not bare text: it's the one thing in the widget that does something other
/// than open the app, so it needs an edge people can see and a target they can hit without
/// opening the song beside it. The capsule reaches above and below the header's line of text
/// instead of making the header taller, which in a medium widget would cost a song row.
struct PlayBackButton: View {
    /// Space above and below the label inside the capsule, and how far the capsule overhangs
    /// the header. Grows with the text so the capsule keeps its shape.
    @ScaledMetric(relativeTo: .caption) private var verticalInset: CGFloat = 5
    @ScaledMetric(relativeTo: .caption) private var horizontalInset: CGFloat = 10
    /// Keeps the icon-only form, used when the header is short of room, from shrinking to a
    /// sliver around the glyph.
    @ScaledMetric(relativeTo: .caption) private var minimumWidth: CGFloat = 40

    var body: some View {
        Button(intent: PlayBackTodayIntent()) {
            Label("Play", systemImage: "play.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
                .padding(.horizontal, horizontalInset)
                .padding(.vertical, verticalInset)
                .frame(minWidth: minimumWidth)
                .background(.tint.quaternary, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        // The capsule draws into the widget's margin above and the gap below the header, so
        // the header stays one line of text tall.
        .padding(.vertical, -verticalInset)
        // "Play" alone doesn't say what will play when read out.
        .accessibilityLabel("Play Back Today")
    }
}

extension PlayBackTodayIntent {
    /// The intent runs in the app, which opens for it; this half only keeps the extension,
    /// which has no app model, building.
    @MainActor static func playbackController() throws -> PlaybackController {
        PlaybackController(store: try TracksStore.shared(), service: PlatformPlaybackService.make())
    }
}
