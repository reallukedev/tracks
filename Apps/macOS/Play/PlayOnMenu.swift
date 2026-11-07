import SwiftUI
import TracksCore

/// Controls › Play On: this Mac and every device nearby, the one with the music checked, as
/// the AirPlay menu lists speakers. Choosing one moves the music there.
struct PlayOnMenu: View {
    let model: AppModel
    @AppStorage(NearbyDevices.storageKey) private var isOn = true

    var body: some View {
        let location = model.musicLocation
        Menu {
            Toggle(isOn: Binding(get: { location == .here }, set: { _ in playHere() })) {
                Label(NearbyDevices.thisDeviceName, systemImage: NearbyDevices.thisDeviceSymbol)
            }
            if !model.nearby.devices.isEmpty {
                Divider()
            }
            ForEach(model.nearby.devices) { device in
                Toggle(isOn: Binding(get: { location == .device(device.id) }, set: { _ in choose(device) })) {
                    Label(device.name, systemImage: device.kind.symbol)
                }
                .disabled(!canChoose(device))
            }
        } label: {
            Label("Play On", systemImage: "laptopcomputer.and.iphone")
        }
        .disabled(!isOn || model.nearby.devices.isEmpty)
    }

    private func canChoose(_ device: NearbyDevices.Device) -> Bool {
        (location == .here && model.player.hasQueue) || device.state?.hasSong == true
    }

    private var location: MusicLocation { model.musicLocation }

    private func playHere() {
        guard case .device(let id) = location, let device = model.nearby.devices.first(where: { $0.id == id }) else { return }
        Task { _ = await model.playHere(from: device) }
    }

    private func choose(_ device: NearbyDevices.Device) {
        if location == .here, model.player.hasQueue {
            model.sendMusic(to: device)
        } else if device.state?.hasSong == true {
            model.control(device)
        }
    }
}
