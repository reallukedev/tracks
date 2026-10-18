import SwiftUI
import TracksCore

/// Your other devices, beside AirPlay in Now Playing, while any are nearby. Its own view, so
/// what they say to each other every few seconds redraws only this, not the player.
struct NowPlayingDevicesButton: View {
    let action: () -> Void
    @Environment(AppModel.self) private var model
    @AppStorage(NearbyDevices.storageKey) private var findsDevices = true

    var body: some View {
        if findsDevices, !model.nearby.devices.isEmpty {
            Button(action: action) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Your Devices")
            .transition(.opacity)
            Spacer()
        }
    }
}
