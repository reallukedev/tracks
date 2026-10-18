import SwiftUI
import TracksCore

/// How far another device is into its song, to drag to a new place.
struct RemoteScrubber: View {
    let device: NearbyDevices.Device
    let state: NearbyState
    var showsTimes = true
    @Environment(AppModel.self) private var model
    @Environment(\.isOnScreen) private var isOnScreen
    @State private var dragFraction: Double?

    var body: some View {
        if let duration = state.duration, duration > 0 {
            // Still while the other device is paused, or while this can't be seen.
            TimelineView(.animation(minimumInterval: 1, paused: !state.isPlaying || dragFraction != nil || !isOnScreen)) { context in
                let live = min(1, max(0, (state.position(at: context.date) ?? 0) / duration))
                let fraction = dragFraction ?? live
                VStack(spacing: 4) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.primary.opacity(0.18))
                            Capsule()
                                .fill(.primary.opacity(dragFraction == nil ? 0.8 : 1))
                                .offset(x: -proxy.size.width * (1 - fraction))
                        }
                        .frame(height: dragFraction == nil ? 4 : 7)
                        .clipShape(.capsule)
                        .frame(maxHeight: .infinity)
                        .contentShape(.rect)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    dragFraction = min(1, max(0, value.location.x / max(1, proxy.size.width)))
                                }
                                .onEnded { _ in
                                    if let dragFraction { model.nearby.seek(device, to: dragFraction * duration) }
                                    dragFraction = nil
                                }
                        )
                        .animation(.easeOut(duration: 0.13), value: dragFraction == nil)
                    }
                    .frame(height: 14)
                    if showsTimes {
                        HStack {
                            Text(verbatim: Scrubber.format(fraction * duration))
                            Spacer()
                            Text(verbatim: "-" + Scrubber.format(max(0, duration - fraction * duration)))
                        }
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Position")
                .accessibilityValue(Text("\(Scrubber.format(fraction * duration)) of \(Scrubber.format(duration))"))
                .accessibilityAdjustableAction { direction in
                    let step: TimeInterval = direction == .increment ? 15 : -15
                    model.nearby.seek(device, to: min(duration, max(0, fraction * duration + step)))
                }
            }
        }
    }
}
