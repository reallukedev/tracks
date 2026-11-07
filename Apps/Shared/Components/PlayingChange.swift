import SwiftUI

extension View {
    /// Runs `action` when the song or whether it's playing changes. The player is read in a
    /// modifier of its own, so a root view using this doesn't redraw on every play, pause or skip.
    func onPlayingChange(of player: PlayerModel, _ action: @escaping () -> Void) -> some View {
        modifier(PlayingChange(player: player, action: action))
    }
}

private struct PlayingChange: ViewModifier {
    let player: PlayerModel
    let action: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: "\(player.current?.id ?? "").\(player.isPlaying)") { action() }
    }
}
