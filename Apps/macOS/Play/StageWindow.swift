import SwiftUI
import AppKit

/// Stage on the Mac: a window of its own that goes full screen as it opens, for a second
/// display or a TV. Esc, or its close button, puts it away.
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
    @State private var controlsShown = true

    var body: some View {
        StageView { close() }
            .frame(minWidth: 640, minHeight: 400)
            .background { WindowReader(window: $window) }
            .onChange(of: window) { _, window in
                showButtons(controlsShown, animated: false)
                guard let window, !window.styleMask.contains(.fullScreen) else { return }
                window.collectionBehavior.insert(.fullScreenPrimary)
                window.toggleFullScreen(nil)
            }
            .onPreferenceChange(StageControlsShownKey.self) { isShown in
                controlsShown = isShown
                showButtons(isShown, animated: true)
            }
    }

    /// Close, minimize and zoom come and go with Stage's controls, as the pointer arrives
    /// and leaves, so nothing sits over the song in a window left showing it.
    private func showButtons(_ isShown: Bool, animated: Bool) {
        guard let window else { return }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap(window.standardWindowButton)
        if isShown { buttons.forEach { $0.isHidden = false } }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.3 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            buttons.forEach { $0.animator().alphaValue = isShown ? 1 : 0 }
        } completionHandler: {
            // Faded out, they stop taking clicks too, unless they've been brought back since.
            MainActor.assumeIsolated {
                guard !controlsShown else { return }
                buttons.forEach { $0.isHidden = true }
            }
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
        let view = NSView()
        Task { @MainActor in window = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if window !== view.window {
            Task { @MainActor in window = view.window }
        }
    }
}
