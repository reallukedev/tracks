import SwiftUI

/// Cards side by side when there's room for each to be at least `minimumWidth`, otherwise
/// stacked, and always stacked at accessibility text sizes. Side by side, every card is as
/// tall as the tallest, so a row never ends raggedly.
///
/// The choice depends on the space rather than on how long a line of text in the card
/// happens to be. A layout rather than `ViewThatFits`, which built and measured every card
/// twice, charts and all, once for each arrangement.
struct CardPair<Content: View>: View {
    var minimumWidth: CGFloat = 320
    var spacing: CGFloat = Metrics.cardSpacing
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        CardPairLayout(minimumWidth: minimumWidth, spacing: spacing, alwaysStacks: typeSize.isAccessibilitySize) {
            content
        }
    }
}

/// Side by side in equal columns as tall as the tallest card, or a `VStack`'s column.
private struct CardPairLayout: Layout {
    let minimumWidth: CGFloat
    let spacing: CGFloat
    let alwaysStacks: Bool

    /// Whether the cards go side by side: what fit for `ViewThatFits`, each card's ideal
    /// width being `minimumWidth`.
    private func isSideBySide(_ proposal: ProposedViewSize, count: Int) -> Bool {
        guard !alwaysStacks, count > 0 else { return false }
        let needed = minimumWidth * CGFloat(count) + spacing * CGFloat(count - 1)
        return (proposal.width ?? needed) >= needed
    }

    /// Each card's size in a column, as a `VStack` in a scroll view sizes it.
    private func stacked(_ proposal: ProposedViewSize, subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
    }

    private func columnWidth(_ width: CGFloat, count: Int) -> CGFloat {
        max(0, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let count = subviews.count
        guard isSideBySide(proposal, count: count) else {
            let sizes = stacked(proposal, subviews: subviews)
            let height = sizes.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, count - 1))
            return CGSize(width: proposal.width ?? sizes.map(\.width).max() ?? 0, height: height)
        }
        let width = proposal.width ?? (minimumWidth * CGFloat(count) + spacing * CGFloat(count - 1))
        let column = columnWidth(width, count: count)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let proposal = ProposedViewSize(width: proposal.width ?? bounds.width, height: proposal.height)
        let count = subviews.count
        guard isSideBySide(proposal, count: count) else {
            var y = bounds.minY
            for (subview, size) in zip(subviews, stacked(proposal, subviews: subviews)) {
                subview.place(at: CGPoint(x: bounds.midX, y: y), anchor: .top, proposal: ProposedViewSize(width: bounds.width, height: size.height))
                y += size.height + spacing
            }
            return
        }
        let column = columnWidth(bounds.width, count: count)
        var x = bounds.minX
        for subview in subviews {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: column, height: bounds.height))
            x += column + spacing
        }
    }
}
