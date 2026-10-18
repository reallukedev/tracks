import SwiftUI
import TracksCore

/// Where the music is and where it can go: a remote for another device's song, then every
/// device with a checkmark on the one playing, as AirPlay lists speakers, then the ones seen
/// lately, as Find My does. Choosing one moves the music there.
///
/// iPhone draws it as a grouped list in a sheet; the Mac as Control Center's modules in a
/// popover, with its settings at the foot.
struct DevicesPanel: View {
    /// Closes the popover or sheet it's in.
    let close: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(PlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    @AppStorage(MacSettingsPane.storageKey) private var settingsPane = MacSettingsPane.general
    #endif
    /// The device the music is on its way to, while it goes.
    @State private var movingTo: String?
    /// A device the song couldn't be found for, said in its row for a moment.
    @State private var notFoundOn: String?
    /// Counts the moves someone made here, for a tap of feedback on each.
    @State private var moves = 0

    private static let here = "this-device"

    var body: some View {
        #if os(macOS)
        macBody
        #else
        phoneBody
        #endif
    }

    // MARK: - iPhone

    #if os(iOS)
    private var phoneBody: some View {
        List {
            if model.nearby.needsLocalNetwork {
                Section {
                    localNetworkNotice
                }
            }
            if let device = featured {
                Section {
                    RemoteDeviceCard(device: device, close: close)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            Section {
                rows
            } header: {
                Text("Play On")
            } footer: {
                Text(footer)
            }
            if !model.nearby.away.isEmpty {
                Section("Recently Seen") {
                    awayRows
                }
            }
            Section {
                NavigationLink {
                    DevicesSettingsPage()
                } label: {
                    Label("Devices Settings", systemImage: "gearshape")
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        // The card sits right under the bar, as Music's AirPlay sheet starts on its song.
        .contentMargins(.top, 8, for: .scrollContent)
        .animation(reduceMotion ? nil : .snappy, value: model.nearby.devices.map(\.id))
        .animation(reduceMotion ? nil : .snappy, value: model.musicLocation)
        .sensoryFeedback(.success, trigger: moves)
    }
    #endif

    // MARK: - Mac

    #if os(macOS)
    private var macBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.nearby.needsLocalNetwork {
                localNetworkNotice
                    .padding(12)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12, style: .continuous))
            }
            if let device = featured {
                RemoteDeviceCard(device: device, close: close)
            }
            module("Play On") {
                rows
            }
            if !model.nearby.away.isEmpty {
                module("Recently Seen") {
                    awayRows
                }
            }
            Text(footer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
            Divider()
                .padding(.horizontal, 6)
            Button {
                settingsPane = .devices
                openSettings()
                close()
            } label: {
                Text("Devices Settings…")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .animation(reduceMotion ? nil : .snappy, value: model.nearby.devices.map(\.id))
        .animation(reduceMotion ? nil : .snappy, value: model.musicLocation)
    }

    /// A titled group, as Control Center's modules have.
    private func module<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
    #endif

    // MARK: - Rows

    @ViewBuilder
    private var rows: some View {
        let location = model.musicLocation
        DeviceRow(
            symbol: NearbyDevices.thisDeviceSymbol,
            name: NearbyDevices.thisDeviceName,
            detail: notFoundOn == Self.here ? String(localized: "This song isn't available here") : hereDetail,
            isPlaying: player.isPlaying,
            trailing: movingTo == Self.here ? .working : location == .here ? .current : .none,
            isProblem: notFoundOn == Self.here,
            hint: Text("Plays the music here")
        ) {
            chooseHere()
        }
        ForEach(model.nearby.devices) { device in
            let state = device.state
            DeviceRow(
                symbol: device.kind.symbol,
                name: device.name,
                detail: detail(state),
                isPlaying: state?.isPlaying == true,
                trailing: movingTo == device.id ? .working : location == .device(device.id) ? .current : .none,
                isEnabled: canChoose(device),
                hint: location == .here ? Text("Plays the music on \(device.name)") : Text("Shows its controls")
            ) {
                choose(device)
            }
            .contextMenu {
                if state?.hasSong == true {
                    Button(state?.isPlaying == true ? "Pause" : "Play", systemImage: state?.isPlaying == true ? "pause" : "play") {
                        model.nearby.send(.playPause, to: device)
                    }
                    Button("Next", systemImage: "forward") {
                        model.nearby.send(.next, to: device)
                    }
                    .disabled(state?.canSkipForward != true)
                }
            }
        }
    }

    private var awayRows: some View {
        ForEach(model.nearby.away) { device in
            DeviceRow(
                symbol: device.deviceKind.symbol,
                name: device.name,
                detail: KnownNearbyDevices.seen(device.lastSeen),
                isAway: true
            )
            .contextMenu {
                Button("Forget This Device", systemImage: "minus.circle", role: .destructive) {
                    model.nearby.forget(device.id)
                }
            }
            #if os(iOS)
            .swipeActions {
                Button("Forget", role: .destructive) {
                    model.nearby.forget(device.id)
                }
            }
            #endif
        }
    }

    private var localNetworkNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local Network Is Off")
                        .font(.headline)
                    Text("Tracks needs it to find your other devices.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Button("Open Settings") {
                if let url = DevicesSettingsLinks.localNetwork { openURL(url) }
            }
            #if os(macOS)
            .controlSize(.small)
            #endif
        }
    }

    // MARK: - What each says

    private var hereDetail: String {
        guard let song = player.current else { return String(localized: "Not Playing") }
        let line = String(localized: "\(song.title) · \(song.artistName)")
        return player.isPlaying ? line : String(localized: "Paused · \(line)")
    }

    private func detail(_ state: NearbyState?) -> String {
        guard let state, state.hasSong else { return String(localized: "Not Playing") }
        let song = [state.title, state.artist].compactMap(\.self).joined(separator: " · ")
        return state.isPlaying ? song : String(localized: "Paused · \(song)")
    }

    private var footer: String {
        if model.nearby.devices.isEmpty {
            String(localized: "Your other devices appear here while Tracks is open on them, on the same Wi‑Fi and iCloud account.")
        } else {
            String(localized: "Choose a device to move the music there. It carries on from the same moment.")
        }
    }

    // MARK: - Choosing

    /// The device whose remote leads: the one the player's showing, or else the first playing,
    /// or the first with a song.
    private var featured: NearbyDevices.Device? {
        model.controlledDevice ?? model.nearby.withSongs.first
    }

    /// Whether choosing a device does anything: the music here goes there, or its own song
    /// shows in the player.
    private func canChoose(_ device: NearbyDevices.Device) -> Bool {
        (model.musicLocation == .here && player.hasQueue) || device.state?.hasSong == true
    }

    /// This device chosen: the song comes here from wherever it's playing.
    private func chooseHere() {
        guard movingTo == nil,
              case .device(let id) = model.musicLocation,
              let device = model.nearby.devices.first(where: { $0.id == id }),
              device.state?.hasSong == true
        else {
            model.control(nil)
            return
        }
        movingTo = Self.here
        Task {
            let moved = await model.playHere(from: device)
            movingTo = nil
            model.control(nil)
            if moved {
                moves += 1
            } else {
                await sayNotFound(on: Self.here)
            }
        }
    }

    /// Another device chosen: the music goes there if it's here; otherwise the player shows
    /// what's playing there, to control from here.
    private func choose(_ device: NearbyDevices.Device) {
        if model.musicLocation == .here, player.hasQueue {
            model.sendMusic(to: device)
            moves += 1
        } else if device.state?.hasSong == true {
            model.control(device)
        }
    }

    private func sayNotFound(on id: String) async {
        notFoundOn = id
        try? await Task.sleep(for: .seconds(4))
        if notFoundOn == id { notFoundOn = nil }
    }
}
