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
    /// Where the drag started, as a fraction: the bar moves by as much as the finger does, as
    /// Music's does, rather than jumping to wherever it landed.
    @State private var dragStart: Double?
    @State private var pendingSeek: PendingSeek?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isOnScreen) private var isOnScreen

    var body: some View {
        TimelineView(.animation(minimumInterval: interval, paused: !isPlaying || dragFraction != nil || !isOnScreen)) { context in
            let shown = PendingSeek.time(time(), pending: pendingSeek, isPlaying: isPlaying, at: context.date)
            let fraction = dragFraction ?? Self.fraction(shown, of: duration)
            let elapsed = fraction * duration
            VStack(spacing: 8) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.2))
                        // Slid along rather than resized, so each tick only redraws.
                        Capsule()
                            .fill(.primary.opacity(dragFraction == nil ? 0.7 : 1))
                            .offset(x: -proxy.size.width * (1 - fraction))
                    }
                    .frame(height: dragFraction == nil ? 6 : 12)
                    .clipShape(.capsule)
                    // Only taking hold and letting go animate: while held, the bar is wherever
                    // the finger is, with nothing easing after it.
                    .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: dragFraction == nil)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let width = max(1, proxy.size.width)
                                #if os(iOS)
                                let start = dragStart ?? fraction
                                dragStart = start
                                dragFraction = min(1, max(0, start + value.translation.width / width))
                                #else
                                // A click goes straight to its place, as Music's bar does.
                                dragFraction = min(1, max(0, value.location.x / width))
                                #endif
                            }
                            .onEnded { value in
                                // A touch that didn't move leaves the song where it is.
                                if let dragFraction, Self.movesOnRelease || abs(value.translation.width) >= 2 {
                                    let time = dragFraction * duration
                                    pendingSeek = PendingSeek(time: time, at: .now)
                                    onSeek(time)
                                }
                                dragStart = nil
                                dragFraction = nil
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
                .foregroundStyle(.primary.opacity(dragFraction == nil ? 0.6 : 0.9))
            }
            .accessibilityElement()
            .accessibilityLabel("Position")
            .accessibilityValue(Text("\(Self.format(elapsed)) of \(Self.format(duration))"))
            .accessibilityAdjustableAction { direction in
                let step: TimeInterval = direction == .increment ? 15 : -15
                let time = min(duration, max(0, elapsed + step))
                pendingSeek = PendingSeek(time: time, at: .now)
                onSeek(time)
            }
        }
        .expiresPendingSeek($pendingSeek)
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

    /// Whether letting go seeks even if the pointer never moved: a click on the Mac, but not
    /// a thumb resting on the bar on the iPhone.
    private static var movesOnRelease: Bool {
        #if os(iOS)
        false
        #else
        true
        #endif
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

/// A position just asked for, shown until the player's own time reaches it, so the bar doesn't
/// spring back to where the song was for a moment before jumping on: Apple Music's player can
/// take a beat to report a seek, longer while a scene changes (see ``PlayerQuiet``).
struct PendingSeek: Equatable {
    let time: TimeInterval
    let at: Date

    /// How long it's shown at most, if the player never gets there.
    static let lifetime: TimeInterval = 1.5

    /// The time to draw: the player's, or the one asked for, carried on while playing, until
    /// the player's is within a second of it.
    static func time(_ live: TimeInterval, pending: PendingSeek?, isPlaying: Bool, at date: Date = .now) -> TimeInterval {
        guard let pending else { return live }
        let since = date.timeIntervalSince(pending.at)
        guard since >= 0, since < lifetime else { return live }
        let expected = pending.time + (isPlaying ? since : 0)
        return abs(live - expected) > 1 ? expected : live
    }
}

extension View {
    /// Forgets a pending seek once it's had its time, redrawing then even while paused.
    func expiresPendingSeek(_ pending: Binding<PendingSeek?>) -> some View {
        task(id: pending.wrappedValue) {
            guard pending.wrappedValue != nil else { return }
            try? await Task.sleep(for: .seconds(PendingSeek.lifetime))
            guard !Task.isCancelled else { return }
            pending.wrappedValue = nil
        }
    }
}

/// A live broadcast has no length: the track stays full, marked live.
struct LiveScrubber: View {
    var body: some View {
        VStack(spacing: 8) {
            Capsule().fill(.primary.opacity(0.2)).frame(height: 6).frame(height: 24)
            HStack {
                LiveBadge()
                Spacer()
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Live radio")
    }
}
