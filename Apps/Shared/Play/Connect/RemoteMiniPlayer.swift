import SwiftUI
import TracksCore

#if os(iOS)
/// The mini player while it's another device's song on show: the song, where it's playing,
/// and its play button. Tapping it opens Your Devices.
struct RemoteMiniPlayer: View {
    let device: NearbyDevices.Device
    @Environment(AppModel.self) private var model
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @State private var isShowingPanel = false

    var body: some View {
        let state = device.state ?? NearbyState()
        HStack(spacing: 10) {
            Button {
                isShowingPanel = true
            } label: {
                HStack(spacing: 10) {
                    CoverImage(cover: .url(state.artworkURL, seed: state.album ?? state.title ?? device.name), size: placement == .inline ? 26 : 32)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(state.title ?? "")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if placement != .inline {
                            Label(device.name, systemImage: device.kind.symbol)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tint)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("\(state.title ?? ""), playing on \(device.name)"))
            .accessibilityHint("Shows Your Devices")
            RemoteTransport(device: device, state: state)
        }
        .padding(.horizontal, 12)
        .sheet(isPresented: $isShowingPanel) {
            DevicesSheet { isShowingPanel = false }
        }
    }
}
#endif
