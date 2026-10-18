import SwiftUI
import AppKit

/// Stage's window, for its own Close and Full Screen buttons. The system's buttons stay hidden:
/// they live in the title bar, apart from Stage's controls, and faded with them before they
/// could be clicked.
@Observable
final class StageWindowChrome {
    private(set) var isFullScreen = false
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func attach(_ window: NSWindow) {
        guard window !== self.window else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        self.window = window
        isFullScreen = window.styleMask.contains(.fullScreen)
        hideSystemButtons()

        // The symbol turns as the change begins, not once the space has finished sliding.
        let changes: [(Notification.Name, Bool?)] = [
            (NSWindow.willEnterFullScreenNotification, true),
            (NSWindow.willExitFullScreenNotification, false),
            (NSWindow.didEnterFullScreenNotification, nil),
            (NSWindow.didExitFullScreenNotification, nil),
        ]
        observers = changes.map { name, isFullScreen in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let window else { return }
                    // Once it's done, from the window itself, in case the change didn't happen.
                    self.isFullScreen = isFullScreen ?? window.styleMask.contains(.fullScreen)
                    // AppKit lays the title bar out afresh on the way in and out.
                    self.hideSystemButtons()
                }
            }
        }
    }

    /// The window the click came from, if Stage's own was never picked up: the button then
    /// still works rather than doing nothing.
    func toggleFullScreen() {
        guard let target = window ?? NSApp.currentEvent?.window ?? NSApp.keyWindow else { return }
        if target !== window { attach(target) }
        target.collectionBehavior.insert(.fullScreenPrimary)
        target.toggleFullScreen(nil)
    }

    /// Whether the pointer is still over the window, for a hover that ends over something
    /// AppKit puts on top of the content, such as the title bar.
    var containsPointer: Bool {
        guard let window else { return false }
        return window.frame.contains(NSEvent.mouseLocation)
    }

    private func hideSystemButtons() {
        Self.hideSystemButtons(of: window)
    }

    static func hideSystemButtons(of window: NSWindow?) {
        // Hidden, not removed: Close and Enter Full Screen in the menus still work through them.
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(type)?.isHidden = true
        }
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

/// Close and Full Screen, in the corner where the window's own buttons would be.
struct StageWindowButtons: View {
    let onClose: () -> Void
    @Environment(StageWindowChrome.self) private var chrome: StageWindowChrome?

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.stageGlassCircle)
            .help("Close Stage")
            .accessibilityLabel("Close Stage")

            if let chrome {
                let label: LocalizedStringKey = chrome.isFullScreen ? "Exit Full Screen" : "Enter Full Screen"
                Button(action: chrome.toggleFullScreen) {
                    Image(systemName: chrome.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.stageGlassCircle)
                .help(label)
                .accessibilityLabel(label)
            }
        }
    }
}

/// Stage's round glass buttons on the Mac: brighter under the pointer, pressed in on a click.
struct StageGlassCircleStyle: ButtonStyle {
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white.opacity(isHovering || configuration.isPressed ? 1 : 0.88))
            .frame(width: 44, height: 44)
            .contentShape(.circle)
            .glassEffect(.regular.tint(.white.opacity(configuration.isPressed ? 0.2 : isHovering ? 0.12 : 0)).interactive(), in: .circle)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .onHover { isHovering = $0 }
            .animation(PlayMotion.hover, value: isHovering)
            .animation(PlayMotion.press, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == StageGlassCircleStyle {
    static var stageGlassCircle: StageGlassCircleStyle { StageGlassCircleStyle() }
}
