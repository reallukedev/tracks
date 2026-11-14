import SwiftUI
import AppKit

extension View {
    /// Gives the `Table` this is attached to rows of one height. SwiftUI's tables size every
    /// row by laying it out: each page of rows that arrived as you scrolled was measured one by
    /// one, stalling the scroll, and rows not yet measured sat shorter and grew as they came
    /// into view, so the list jumped under the pointer.
    func fixedTableRowHeight(_ height: CGFloat) -> some View {
        background(TableRowHeightSetter(height: height))
    }
}

private struct TableRowHeightSetter: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> FinderView {
        FinderView(height: height)
    }

    func updateNSView(_ view: FinderView, context: Context) {
        view.height = height
        view.apply()
    }

    final class FinderView: NSView {
        var height: CGFloat
        private var observation: NSKeyValueObservation?

        init(height: CGFloat) {
            self.height = height
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        /// The table once found, so each layout pass only checks it.
        private weak var table: NSTableView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // The table is made alongside this view, and may not be in the window yet.
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        /// Laid out with the table, before it first draws: an empty table still loading drew
        /// its stripes at SwiftUI's own height, then the rows arrived taller and everything moved.
        override func layout() {
            super.layout()
            apply()
        }

        func apply() {
            guard let table = table ?? nearestTable() else { return }
            if table !== self.table {
                self.table = table
                observation = nil
            }
            if table.usesAutomaticRowHeights { table.usesAutomaticRowHeights = false }
            if table.rowHeight != height { table.rowHeight = height }
            // SwiftUI sets its own height again as it updates the table.
            if observation == nil {
                observation = table.observe(\.rowHeight) { [weak self] table, _ in
                    MainActor.assumeIsolated {
                        guard let self, table.rowHeight != self.height else { return }
                        table.rowHeight = self.height
                    }
                }
            }
        }

        /// The table this view sits behind: the one whose scroll view covers its middle, so the
        /// sidebar's list, a table too, is never the one changed.
        private func nearestTable() -> NSTableView? {
            guard window != nil else { return nil }
            let place = convert(bounds, to: nil)
            var ancestor = superview
            for _ in 0..<8 {
                guard let view = ancestor else { return nil }
                if let table = Self.table(in: view, at: place) { return table }
                ancestor = view.superview
            }
            return nil
        }

        private static func table(in view: NSView, at place: NSRect) -> NSTableView? {
            if let table = view as? NSTableView, let scroll = table.enclosingScrollView {
                let frame = scroll.convert(scroll.bounds, to: nil)
                if frame.contains(NSPoint(x: place.midX, y: place.midY)) { return table }
            }
            for subview in view.subviews {
                if let table = table(in: subview, at: place) { return table }
            }
            return nil
        }
    }
}
