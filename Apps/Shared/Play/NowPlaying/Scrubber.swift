import SwiftUI
import TracksCore

/// The song's position, as Music draws it: a thin track that thickens under the finger, the
/// time gone on the left and the time left on the right.
struct Scrubber: View {
    let duration: TimeInterval
    let isPlaying: Bool
    let time: () -> TimeInterval
    /// The song, whose audio quality shows between the times as Music shows Lossless.
    var track: PlayerTrack? = nil
    /// How often it moves on while playing.
    var interval: TimeInterval = 0.25
    let onSeek: (TimeInterval) -> Void

    @State private var dragFraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isOnScreen) private var isOnScreen

    var body: some View {
        TimelineView(.animation(minimumInterval: interval, paused: !isPlaying || dragFraction != nil || !isOnScreen)) { _ in
            let fraction = dragFraction ?? Self.fraction(time(), of: duration)
            let elapsed = fraction * duration
            VStack(spacing: 8) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        // Slid along rather than resized, so each tick only redraws.
                        Capsule()
                            .fill(.white.opacity(dragFraction == nil ? 0.7 : 1))
                            .offset(x: -proxy.size.width * (1 - fraction))
                    }
                    .frame(height: dragFraction == nil ? 6 : 12)
                    .clipShape(.capsule)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                withAnimation(reduceMotion ? nil : .snappy(duration: 0.14)) {
                                    dragFraction = min(1, max(0, value.location.x / max(1, proxy.size.width)))
                                }
                            }
                            .onEnded { _ in
                                if let dragFraction { onSeek(dragFraction * duration) }
                                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { dragFraction = nil }
                            }
                    )
                }
                .frame(height: 24)
                // Felt as the bar is taken hold of, and at either end of the song.
                .sensoryFeedback(.impact(weight: .light), trigger: dragFraction != nil) { _, held in held }
                .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.6), trigger: dragFraction.map { $0 <= 0 || $0 >= 1 }) { _, atEnd in atEnd == true }

                HStack {
                    Text(Self.format(elapsed))
                    Spacer()
                    Text(verbatim: "-" + Self.format(max(0, duration - elapsed)))
                }
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(dragFraction == nil ? 0.6 : 0.9))
            }
            .accessibilityElement()
            .accessibilityLabel("Position")
            .accessibilityValue(Text("\(Self.format(elapsed)) of \(Self.format(duration))"))
            .accessibilityAdjustableAction { direction in
                let step: TimeInterval = direction == .increment ? 15 : -15
                onSeek(min(duration, max(0, elapsed + step)))
            }
        }
        // Its own element after the position, since it opens its details, and outside the
        // timeline, which redraws as the song plays. Centred on the times' line: a hidden
        // line of the times' type is its anchor at every text size.
        .overlay(alignment: .bottom) {
            if let track {
                Text(verbatim: "0")
                    .font(.caption.weight(.medium))
                    .hidden()
                    .overlay { AudioQualityBadge(track: track).fixedSize() }
            }
        }
    }

    /// Four times a second on the iPhone; once on the Mac, where each tick lays the whole
    /// window out again.
    static var platformInterval: TimeInterval {
        #if os(macOS)
        1
        #else
        0.25
        #endif
    }

    /// How far through, from 0 to 1. A length or time that isn't a real number, as a broken
    /// file or a stream can report, counts as the start.
    static func fraction(_ time: TimeInterval, of duration: TimeInterval) -> Double {
        guard duration > 0, duration.isFinite, time.isFinite else { return 0 }
        return min(1, max(0, time / duration))
    }

    /// "3:07", or "1:02:07" past an hour.
    static func format(_ seconds: TimeInterval) -> String {
        // Int(_:) traps on NaN and infinity.
        guard seconds.isFinite else { return "--:--" }
        let whole = Int(seconds.rounded(.down))
        return Duration.seconds(whole).formatted(
            .time(pattern: whole >= 3600 ? .hourMinuteSecond : .minuteSecond)
        )
    }
}

/// A live broadcast has no length: the track stays full, marked live.
struct LiveScrubber: View {
    var body: some View {
        VStack(spacing: 8) {
            Capsule().fill(.white.opacity(0.2)).frame(height: 6).frame(height: 24)
            HStack {
                LiveBadge()
                Spacer()
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Live radio")
    }
}
