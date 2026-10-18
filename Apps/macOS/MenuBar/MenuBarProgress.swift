import SwiftUI

/// The song's progress in the menu bar window, as Music's mini player shows it: the time gone,
/// a thin track that thickens under the pointer, to click or drag anywhere in the song, and
/// the time left.
struct MenuBarProgress: View {
    let duration: TimeInterval
    let isPlaying: Bool
    let time: () -> TimeInterval
    let onSeek: (TimeInterval) -> Void
    @Environment(\.isOnScreen) private var isOnScreen
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragFraction: Double?
    @State private var isHovering = false

    var body: some View {
        // Once a second, as the times change: each tick lays the window out again.
        TimelineView(.animation(minimumInterval: 1, paused: !isPlaying || dragFraction != nil || !isOnScreen)) { _ in
            let fraction = dragFraction ?? Scrubber.fraction(time(), of: duration)
            HStack(spacing: 8) {
                label(fraction * duration)
                GeometryReader { proxy in
                    let isActive = isHovering || dragFraction != nil
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .offset(x: -proxy.size.width * (1 - fraction))
                    }
                    .frame(height: isActive ? 6 : 4)
                    .clipShape(.capsule)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
                    .onHover { isHovering = $0 }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                dragFraction = min(1, max(0, value.location.x / max(1, proxy.size.width)))
                            }
                            .onEnded { _ in
                                if let dragFraction { onSeek(dragFraction * duration) }
                                dragFraction = nil
                            }
                    )
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.13), value: isActive)
                }
                .frame(height: 16)
                label(max(0, duration - fraction * duration), isRemaining: true)
            }
            .accessibilityElement()
            .accessibilityLabel("Position")
            .accessibilityValue(Text("\(Scrubber.format(fraction * duration)) of \(Scrubber.format(duration))"))
            .accessibilityAdjustableAction { direction in
                let step: TimeInterval = direction == .increment ? 15 : -15
                onSeek(min(duration, max(0, fraction * duration + step)))
            }
        }
    }

    private func label(_ seconds: TimeInterval, isRemaining: Bool = false) -> some View {
        // Sized by the song's longest time with the ticking one drawn over it, so the track's
        // width never changes as the time does.
        Text(verbatim: (isRemaining ? "-" : "") + Scrubber.format(duration))
            .hidden()
            .overlay(alignment: isRemaining ? .leading : .trailing) {
                Text(verbatim: (isRemaining ? "-" : "") + Scrubber.format(seconds))
            }
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(minWidth: 34, alignment: isRemaining ? .leading : .trailing)
    }
}
