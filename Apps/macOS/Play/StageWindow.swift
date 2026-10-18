import SwiftUI
import AppKit

/// Stage on the Mac: a window of its own that goes full screen as it opens, for a second
/// display or a TV. Esc, or its Close button, puts it away.
struct StageWindow: Scene {
    static let id = "stage"
    let model: AppModel

    var body: some Scene {
        Window("Stage", id: Self.id) {
            // Everything Stage's controls and menus read, as the main window has it: without
            // one, opening Stage stops the app.
            StageWindowContent()
                .opensSongInfo(model)
                .tracksOnScreen()
                .environment(model)
                .environment(model.player)
                .environment(model.playFeed)
                .environment(model.discovery)
                .environment(model.yourMusic)
                .environment(model.lidarr)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .restorationBehavior(.disabled)
    }
}

private struct StageWindowContent: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var window: NSWindow?
    @State private var chrome = StageWindowChrome()

    var body: some View {
        StageView { close() }
            .environment(chrome)
            .frame(minWidth: 640, minHeight: 400)
            .background { WindowReader(window: $window) }
            .onChange(of: window, initial: true) { _, window in
                guard let window else { return }
                chrome.attach(window)
                guard !window.styleMask.contains(.fullScreen) else { return }
                window.collectionBehavior.insert(.fullScreenPrimary)
                window.toggleFullScreen(nil)
            }
    }

    /// Leaves full screen first, so the space it made goes with it.
    private func close() {
        if let window, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                dismissWindow(id: StageWindow.id)
            }
        } else {
            dismissWindow(id: StageWindow.id)
        }
    }
}

/// The window a view is in, once it's in one.
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = ArrivalView()
        view.onArrival = { window in
            Task { @MainActor in self.window = window }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if window !== view.window, let arrived = view.window {
            Task { @MainActor in window = arrived }
        }
    }

    /// Says when the view lands in a window, which a SwiftUI update may not follow, and hides
    /// the system's window buttons then, before the window's first frame.
    private final class ArrivalView: NSView {
        var onArrival: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            StageWindowChrome.hideSystemButtons(of: window)
            onArrival?(window)
        }
    }
}
