import SwiftUI
import UIKit

extension Notification.Name {
    /// iPhone was shaken, with no text being edited, where a shake means Undo.
    static let tracksDidShake = Notification.Name("TracksDidShake")
}

extension UIWindow {
    /// Shakes reach the window when nothing closer takes them, as a text field does for Undo.
    /// Only the app's own key window counts, never CarPlay's or the keyboard's.
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        guard motion == .motionShake, isKeyWindow,
              windowScene?.session.role == .windowApplication
        else { return }
        NotificationCenter.default.post(name: .tracksDidShake, object: nil)
    }
}

extension View {
    /// Shake to Play: a shake plays a song Tracks thinks you'd like, then Tracks Radio on from it,
    /// whichever music is the source. Once every few seconds, so one long shake is one song.
    /// - Parameter onPlay: once the song is playing, to show it: the app opens Now Playing.
    func shakeToPlay(_ player: PlayerModel, onPlay: @escaping () -> Void) -> some View {
        modifier(ShakeToPlay(player: player, onPlay: onPlay))
    }
}

private struct ShakeToPlay: ViewModifier {
    let player: PlayerModel
    let onPlay: () -> Void
    @State private var lastShake = Date.distantPast
    @State private var shakes = 0

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .tracksDidShake)) { _ in
                guard PlayPreferences.shakeToPlay, Date.now.timeIntervalSince(lastShake) > 3 else { return }
                lastShake = .now
                shakes += 1
                Task {
                    if await player.playSomethingNew() { onPlay() }
                }
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: shakes)
    }
}
