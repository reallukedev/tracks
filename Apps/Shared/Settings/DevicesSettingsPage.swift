import SwiftUI
import TracksCore

/// Your Devices in Settings: whether Tracks finds your other devices, which are here and which
/// were lately, and Handoff. An iPhone page, from Settings and from the Devices sheet, and the
/// Mac's Devices pane.
struct DevicesSettingsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @AppStorage(NearbyDevices.storageKey) private var isOn = true
    @AppStorage(NowPlayingHandoff.storageKey) private var offersHandoff = true
    @AppStorage(NearbyDevices.bringsQueueKey) private var bringsQueue = true

    private var status: NearbyDevicesStatus {
        let playingOn: String? = {
            guard case .device(let id) = model.musicLocation else { return nil }
            return model.nearby.devices.first { $0.id == id }?.name
        }()
        return NearbyDevicesStatus(
            isOn: isOn,
            needsLocalNetwork: model.nearby.needsLocalNetwork,
            connected: model.nearby.devices.count,
            playingOn: playingOn
        )
    }

    var body: some View {
        Form {
            SettingsHero(
                "Your Devices",
                subtitle: (status.needsAttention ? SettingsTone.attention : .plain).apply(to: Text(status.line)),
                systemImage: "laptopcomputer.and.iphone",
                tint: .blue
            ) {
                #if os(macOS)
                Toggle("Find Your Devices", isOn: $isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                #endif
            }

            #if os(iOS)
            Section {
                Toggle("Find Your Devices", isOn: $isOn)
            } footer: {
                Text(aboutFooter)
            }
            #endif

            if isOn {
                if model.nearby.needsLocalNetwork {
                    localNetworkSection
                }
                nearbySection
                if !model.nearby.away.isEmpty {
                    awaySection
                }
                bringsQueueSection
                handoffSection
            }

            #if os(macOS)
            Section {
            } footer: {
                Text(aboutFooter)
            }
            #endif
        }
        .animation(SettingsMotion.row(reduceMotion: reduceMotion), value: isOn)
        .animation(SettingsMotion.row(reduceMotion: reduceMotion), value: model.nearby.devices.map(\.id))
        .animation(SettingsMotion.row(reduceMotion: reduceMotion), value: model.nearby.away.map(\.id))
        .onChange(of: isOn) { _, on in
            // Sample data never reaches the real network, as at launch.
            guard !model.isDemoLaunch else { return }
            if on { model.nearby.start() } else { model.nearby.stop() }
        }
        .onChange(of: offersHandoff) { model.updateHandoff() }
        #if os(macOS)
        .settingsPane()
        #else
        .settingsPage("Your Devices")
        #endif
    }

    // MARK: - Sections

    private var localNetworkSection: some View {
        Section {
            #if os(macOS)
            SettingsDetailRow(title: Text("Local Network"), detail: Text("Off for Tracks, so it can't find your devices.")) {
                Button("Open Privacy Settings…") { open(DevicesSettingsLinks.localNetwork) }
            }
            #else
            Button("Turn On Local Network") { open(DevicesSettingsLinks.localNetwork) }
            #endif
        } footer: {
            #if os(iOS)
            Text(PlaySettingsWords.localNetworkOff)
            #endif
        }
    }

    private var nearbySection: some View {
        Section {
            DeviceRow(
                symbol: NearbyDevices.thisDeviceSymbol,
                name: NearbyDevices.thisDeviceName,
                detail: model.player.current.map { String(localized: "\($0.title) · \($0.artistName)") } ?? String(localized: "Not Playing"),
                isPlaying: model.player.isPlaying
            )
            ForEach(model.nearby.devices) { device in
                DeviceRow(
                    symbol: device.kind.symbol,
                    name: device.name,
                    detail: nearbyDetail(device.state),
                    isPlaying: device.state?.isPlaying == true
                )
            }
        } header: {
            Text("Nearby")
        } footer: {
            if model.nearby.devices.isEmpty {
                Text("Open Tracks on your other devices, on the same Wi‑Fi and iCloud account, and they appear here.")
            }
        }
    }

    private var awaySection: some View {
        Section {
            ForEach(model.nearby.away) { device in
                HStack {
                    DeviceRow(
                        symbol: device.deviceKind.symbol,
                        name: device.name,
                        detail: awayDetail(device),
                        isAway: true
                    )
                    #if os(macOS)
                    Menu {
                        forgetButton(device)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More")
                    .accessibilityLabel(Text("More for \(device.name)"))
                    #endif
                }
                .contextMenu { forgetButton(device) }
                #if os(iOS)
                .swipeActions {
                    Button("Forget", role: .destructive) { model.nearby.forget(device.id) }
                }
                #endif
            }
        } header: {
            Text("Recently Seen")
        } footer: {
            Text(awayFooter)
        }
    }

    private var bringsQueueSection: some View {
        Section {
            SettingsSwitch("Bring Up Next", detail: Text(bringsQueueFooter), isOn: $bringsQueue)
        } footer: {
            #if os(iOS)
            Text(bringsQueueFooter)
            #endif
        }
    }

    private var handoffSection: some View {
        Section {
            SettingsSwitch(
                "Handoff",
                detail: Text(offersHandoff ? handoffFooter : String(localized: "Your other devices don't offer the song playing here.")),
                isOn: $offersHandoff
            )
        } footer: {
            #if os(iOS)
            Text(offersHandoff ? handoffFooter : String(localized: "Your other devices don't offer the song playing here."))
            #endif
        }
    }

    private func forgetButton(_ device: KnownNearbyDevice) -> some View {
        Button("Forget This Device", systemImage: "minus.circle", role: .destructive) {
            model.nearby.forget(device.id)
        }
    }

    // MARK: - Words

    private func nearbyDetail(_ state: NearbyState?) -> String {
        guard let state, state.hasSong else { return String(localized: "Not Playing") }
        let song = [state.title, state.artist].compactMap(\.self).joined(separator: " · ")
        return state.isPlaying ? song : String(localized: "Paused · \(song)")
    }

    /// When it was here, and what it last played.
    private func awayDetail(_ device: KnownNearbyDevice) -> String {
        let seen = KnownNearbyDevices.seen(device.lastSeen)
        guard let song = device.song else { return seen }
        return String(localized: "\(seen) · \(song)")
    }

    private var aboutFooter: String {
        String(localized: "Tracks on your iPhone, iPad and Mac find each other on the same Wi‑Fi, to show what each is playing and move the music between them. Only your own devices, signed in to your iCloud, can connect, and everything between them is encrypted.")
    }

    private var awayFooter: String {
        switch NearbyDevices.thisKind {
        case .iPhone: String(localized: "Devices stay here for 30 days after they were last nearby. This list is kept on this iPhone only.")
        case .iPad: String(localized: "Devices stay here for 30 days after they were last nearby. This list is kept on this iPad only.")
        default: String(localized: "Devices stay here for 30 days after they were last nearby. This list is kept on this Mac only.")
        }
    }

    private var bringsQueueFooter: String {
        switch (NearbyDevices.thisKind, bringsQueue) {
        case (.iPhone, true): String(localized: "Music moved to this iPhone brings the album, playlist or mix it's playing from, and what's up next.")
        case (.iPad, true): String(localized: "Music moved to this iPad brings the album, playlist or mix it's playing from, and what's up next.")
        case (_, true): String(localized: "Music moved to this Mac brings the album, playlist or mix it's playing from, and what's up next.")
        case (.iPhone, false): String(localized: "Music moved to this iPhone brings just the song.")
        case (.iPad, false): String(localized: "Music moved to this iPad brings just the song.")
        case (_, false): String(localized: "Music moved to this Mac brings just the song.")
        }
    }

    private var handoffFooter: String {
        switch NearbyDevices.thisKind {
        case .iPhone: String(localized: "Your Mac and iPad offer to pick up the song playing here, from the same moment: in the Dock on a Mac, and in the app switcher on iPad.")
        case .iPad: String(localized: "Your Mac and iPhone offer to pick up the song playing here, from the same moment: in the Dock on a Mac, and in the app switcher on iPhone.")
        default: String(localized: "Your iPhone and iPad offer to pick up the song playing here, from the same moment, in their app switcher.")
        }
    }

    private func open(_ url: URL?) {
        if let url { openURL(url) }
    }
}
