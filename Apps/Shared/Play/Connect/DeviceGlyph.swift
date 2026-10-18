import SwiftUI

/// A device's symbol in a circle, filled with the accent on the one with the music.
struct DeviceGlyph: View {
    let symbol: String
    var isCurrent = false
    var isAway = false
    #if os(macOS)
    @ScaledMetric(relativeTo: .callout) private var side: CGFloat = 28
    #else
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 38
    #endif

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: side * 0.42, weight: .medium))
            .foregroundStyle(isCurrent ? AnyShapeStyle(.white) : isAway ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .frame(width: side, height: side)
            .background(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary), in: .circle)
            .animation(.snappy(duration: 0.25), value: isCurrent)
            .accessibilityHidden(true)
    }
}
