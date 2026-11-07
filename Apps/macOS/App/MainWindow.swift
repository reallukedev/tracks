import SwiftUI
import AppKit

/// The windows showing ``MacRootView``, and bringing one of them forward.
///
/// Found by the view they host rather than by `canBecomeMain`, which the hidden Settings
/// window answers too, or by the identifier SwiftUI happens to give its windows, which isn't
/// public and could change.
@MainActor
enum MainWindow {
    private static let windows = NSHashTable<NSWindow>.weakObjects()

    /// A main window that is open, or minimised to the Dock. A closed one can linger before
    /// AppKit releases it, and ordering that front would show an empty frame.
    static var open: NSWindow? {
        windows.allObjects.first { $0.isVisible || $0.isMiniaturized }
    }

    static func isMain(_ window: NSWindow) -> Bool {
        windows.contains(window)
    }

    fileprivate static func register(_ window: NSWindow) {
        windows.add(window)
    }

    fileprivate static func forget(_ window: NSWindow) {
        windows.remove(window)
    }

    /// Puts the main window in front, opening one if there is none, after `route` has been
    /// set on the model so the window shows it.
    ///
    /// The app becomes `.regular` while the window is up, since `NSApp.activate()` doesn't
    /// bring an accessory app forward on macOS 27; the deprecated form still does, so it's
    /// used on purpose. ``tracksMainWindow(onLastClose:)`` puts the Dock preference back
    /// when the window closes.
    static func bringForward(openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(.regular)
        if let window = open {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension View {
    /// Hands SwiftUI's `openWindow` to ``MacAppDelegate`` as soon as this view appears, so
    /// Search from Siri or Spotlight and the Dock can open the main window while Tracks lives
    /// only in the menu bar.
    func keepsOpenWindow() -> some View {
        modifier(KeepsOpenWindow())
    }

    /// Marks this view's window as a main window, and calls `onLastClose` once the last of
    /// them has closed.
    func tracksMainWindow(onLastClose: @escaping @MainActor () -> Void) -> some View {
        background(MainWindowReader(onLastClose: onLastClose))
    }
}

private struct MainWindowReader: NSViewRepresentable {
    let onLastClose: @MainActor () -> Void

    func makeNSView(context: Context) -> ReaderView {
        ReaderView(onLastClose: onLastClose)
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onLastClose = onLastClose
    }

    final class ReaderView: NSView {
        var onLastClose: @MainActor () -> Void

        init(onLastClose: @escaping @MainActor () -> Void) {
            self.onLastClose = onLastClose
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            MainWindow.register(window)
            // Selector-based, so the registration goes away with the view.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let window {
                NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
            }
            super.viewWillMove(toWindow: newWindow)
        }

        @objc private func windowWillClose(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            // Still visible while it closes, so it has to be taken out before asking.
            MainWindow.forget(window)
            if MainWindow.open == nil { onLastClose() }
        }
    }
}

private struct KeepsOpenWindow: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            if MacAppDelegate.openWindow == nil { MacAppDelegate.openWindow = openWindow }
        }
    }
}
