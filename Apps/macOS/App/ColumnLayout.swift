import SwiftUI

/// A page of the main window, filling what it's given, that says how small it can go without
/// measuring itself to find out.
///
/// AppKit asks each page's hosting view in the split view for its minimum size after every
/// SwiftUI update in the window. Answered by the page, that's a second full layout of it each
/// time: on Summary, about a third of the cost of every frame of an animation.
struct ColumnLayout: Layout {
    var minimum: CGSize = .zero

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(
            width: max(minimum.width, proposal.width ?? minimum.width),
            height: max(minimum.height, proposal.height ?? minimum.height)
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }

    // The defaults place the page to find its guides, which is the measuring this avoids.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        nil
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        nil
    }
}
