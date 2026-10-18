import SwiftUI
import TracksCore

/// The button for your devices: the Mac's title bar, and Play's on iPhone. While another
/// device has the music it takes that device's shape, in the accent, as Music's AirPlay
/// button lights up when it plays elsewhere.
struct DevicesButton: View {
    /// Opens with `-TracksDevices YES`. Only one button on a screen may, or two sheets try to
    /// open at once.
    var opensAtLaunch = false
    @Environment(AppModel.self) private var model
    @State private var isShowingPanel = false

    var body: some View {
        let elsewhere: NearbyDevices.Device? = {
            guard case .device(let id) = model.musicLocation else { return nil }
            return model.nearby.devices.first { $0.id == id }
        }()
        Button {
            isShowingPanel = true
        } label: {
            // An image rather than a label: a toolbar draws a label's icon in its own colour.
            Image(systemName: elsewhere?.kind.symbol ?? "laptopcomputer.and.iphone")
                .foregroundStyle(elsewhere == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                .contentTransition(.symbolEffect(.replace))
        }
        .help(elsewhere.map { "Playing on \($0.name)" } ?? "Your Devices")
        .accessibilityLabel(elsewhere.map { Text("Your Devices, playing on \($0.name)") } ?? Text("Your Devices"))
        .onAppear {
            if opensAtLaunch, LaunchScene.opensDevices { isShowingPanel = true }
        }
        #if os(macOS)
        .popover(isPresented: $isShowingPanel, arrowEdge: .bottom) {
            DevicesPanel { isShowingPanel = false }
                .frame(width: 340)
        }
        #else
        .sheet(isPresented: $isShowingPanel) {
            DevicesSheet { isShowingPanel = false }
        }
        #endif
    }
}
