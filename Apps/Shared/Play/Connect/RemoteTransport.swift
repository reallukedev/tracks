import SwiftUI
import TracksCore

/// Back, play or pause, and next, for another device.
struct RemoteTransport: View {
    enum Size { case compact, large }

    let device: NearbyDevices.Device
    let state: NearbyState
    var size = Size.compact
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: size == .large ? 26 : 8) {
            button("Previous", "backward.fill", .previous, diameter: small)
                .disabled(!state.canSkipBack)
            button(state.isPlaying ? "Pause" : "Play", state.isPlaying ? "pause.fill" : "play.fill", .playPause, diameter: big)
            button("Next", "forward.fill", .next, diameter: small)
                .disabled(!state.canSkipForward)
        }
    }

    private var small: CGFloat { size == .large ? 36 : 30 }
    private var big: CGFloat { size == .large ? 46 : 36 }

    /// Each button answers a touch across a full fingertip, around the smaller glyph.
    private var hitSide: CGFloat {
        #if os(iOS)
        44
        #else
        0
        #endif
    }

    private func button(_ title: LocalizedStringKey, _ symbol: String, _ command: TransportCommand, diameter: CGFloat) -> some View {
        Button {
            model.nearby.send(command, to: device)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.42, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: diameter, height: diameter)
                .frame(minWidth: hitSide, minHeight: hitSide)
                .contentShape(.rect)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(Text(title))
        .help(Text(title))
    }
}
