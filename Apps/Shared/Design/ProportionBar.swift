import SwiftUI

/// A capsule filled to `fraction` of its width over a faint track, for one share of a whole.
/// Decorative: the row it sits in says the number out loud.
struct ProportionBar: View {
    let fraction: Double
    var style = AnyShapeStyle(Color.accentColor)
    var height: CGFloat = 8

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .frame(height: height)
            // A shape rather than a GeometryReader: one in every row measured each bar again
            // on every layout pass of the page around it.
            .overlay { FilledCapsule(fraction: fraction).fill(style) }
            .accessibilityHidden(true)
    }
}

/// The filled part of a ``ProportionBar``: `fraction` of the width from the leading edge.
nonisolated private struct FilledCapsule: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let clamped = min(max(fraction, 0), 1)
        guard clamped > 0 else { return Path() }
        // Never narrower than it is tall, so a sliver still reads as a bar.
        let width = max(rect.height, rect.width * clamped)
        return Capsule().path(in: CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height))
    }
}

/// Lays its children side by side, each as wide as its ``SwiftUI/View/share(_:)`` of the
/// width left after the gaps, and as tall as offered: a bar of shares without a
/// `GeometryReader`.
struct ShareRow: Layout {
    var gap: CGFloat = 2
    /// The narrowest a share is drawn, so a sliver still shows.
    var minimumWidth: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let room = max(0, bounds.width - gap * CGFloat(max(0, subviews.count - 1)))
        var x = bounds.minX
        for subview in subviews {
            let width = max(minimumWidth, room * subview[ShareKey.self])
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + gap
        }
    }
}

nonisolated private struct ShareKey: LayoutValueKey {
    static let defaultValue: Double = 0
}

extension View {
    /// This child's fraction of a ``ShareRow``.
    func share(_ fraction: Double) -> some View {
        layoutValue(key: ShareKey.self, value: fraction)
    }
}
