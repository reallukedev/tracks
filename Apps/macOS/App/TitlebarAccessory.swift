import SwiftUI
import AppKit

/// SwiftUI content pinned to the trailing end of a window's titlebar, after every toolbar
/// item any page adds: the one place that stays put however the page's toolbar changes.
///
/// A toolbar item can't promise that: items from the window's outer views come before a
/// page's own. And kept out of the toolbar, it's never part of the toolbar being rebuilt as
/// pages come and go.
struct TitlebarAccessory<Content: View>: NSViewRepresentable {
    var isHidden = false
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Task { attach(from: view, coordinator: context.coordinator) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.hosting?.rootView = content
        context.coordinator.accessory?.isHidden = isHidden
        if context.coordinator.accessory == nil {
            Task { attach(from: view, coordinator: context.coordinator) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var accessory: NSTitlebarAccessoryViewController?
        var hosting: NSHostingView<Content>?
    }

    private func attach(from view: NSView, coordinator: Coordinator) {
        guard coordinator.accessory == nil, let window = view.window else { return }
        let hosting = NSHostingView(rootView: content)
        // Its own size up front, so the titlebar makes room for it rather than drawing it
        // over the toolbar's end.
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = hosting
        accessory.layoutAttribute = .trailing
        accessory.isHidden = isHidden
        window.addTitlebarAccessoryViewController(accessory)
        coordinator.accessory = accessory
        coordinator.hosting = hosting
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.accessory?.removeFromParent()
    }
}
