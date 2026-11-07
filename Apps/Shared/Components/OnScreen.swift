import SwiftUI

extension EnvironmentValues {
    /// False while nothing here can be seen: its window minimized, hidden or covered, or the
    /// full player over the page. Anything that ticks, a progress line or a moving backdrop,
    /// pauses on it. On the Mac every tick lays the whole window out again, so a clock left
    /// running under a closed lid or behind another app costs as much as one on screen.
    @Entry var isOnScreen = true
}

extension View {
    /// Keeps ``EnvironmentValues/isOnScreen`` true only while this view's window is visible.
    /// For the root of each window.
    func tracksOnScreen() -> some View {
        #if os(macOS)
        modifier(OnScreenTracker())
        #else
        modifier(ScenePhaseTracker())
        #endif
    }
}

#if os(iOS)
/// An iPhone playing music keeps Tracks running once it's left, and what ticks would go on
/// updating a screen nobody sees. iOS then waits on those updates to snapshot the app, and a
/// hot, busy phone gives up on them after ten seconds and ends it.
private struct ScenePhaseTracker: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.environment(\.isOnScreen, scenePhase != .background)
    }
}
#endif

#if os(macOS)
import AppKit

private struct OnScreenTracker: ViewModifier {
    @State private var isVisible = true

    func body(content: Content) -> some View {
        content
            .environment(\.isOnScreen, isVisible)
            .background { OcclusionReader { isVisible = $0 } }
    }
}

private struct OcclusionReader: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> ReaderView {
        ReaderView(onChange: onChange)
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: @MainActor (Bool) -> Void

        init(onChange: @escaping @MainActor (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        private static let changes: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ]

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // Selector-based, so the registrations go away with the view.
            for name in Self.changes {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: window)
            }
            // Not asked now: a window arriving isn't on screen yet, and says so when it is.
            // Until something says otherwise, it counts as seen.
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let window {
                for name in Self.changes {
                    NotificationCenter.default.removeObserver(self, name: name, object: window)
                }
            }
            super.viewWillMove(toWindow: newWindow)
        }

        @objc private func windowChanged(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            report(window)
        }

        private func report(_ window: NSWindow) {
            let isVisible = Self.isOffscreenStage
                ? !window.isMiniaturized
                : window.occlusionState.contains(.visible)
            onChange(isVisible)
        }

        /// Backstage draws windows off screen to capture them, where they always count as
        /// covered: there only minimizing one takes it off screen.
        private static let isOffscreenStage: Bool = {
            #if DEBUG
            ProcessInfo.processInfo.environment["BACKSTAGE_STAGE"] != nil
            #else
            false
            #endif
        }()
    }
}
#endif
