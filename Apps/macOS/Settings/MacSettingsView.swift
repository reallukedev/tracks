import SwiftUI
import TracksCore

/// A pane of the Mac's Settings window, stored so Settings reopens where it was left.
enum MacSettingsPane: String {
    case general, play, history, radio, lastFM, iCloud, devices, menuBar
    static let storageKey = "settingsPane"
}

/// The Settings window (⌘,): one pane per feature, each sized to fit it.
struct MacSettingsView: View {
    let model: AppModel

    @AppStorage(MacSettingsPane.storageKey) private var pane = MacSettingsPane.general
    @State private var lastFM = LastFMConnection()
    @State private var cloud: CloudSyncSettings?

    var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: .general) {
                GeneralSettingsPane()
            }
            Tab("Play", systemImage: "play.circle", value: .play) {
                // The Settings scene is its own root, so Play's models go in again here.
                PlaySettingsPane()
                    .environment(model.player)
                    .environment(model.yourMusic)
                    .environment(model.lidarr)
            }
            Tab("History", systemImage: "clock", value: .history) {
                HistorySettingsPage()
            }
            Tab("Radio", systemImage: "dot.radiowaves.left.and.right", value: .radio) {
                RadioSettingsPage()
            }
            Tab("Last.fm", systemImage: "waveform", value: .lastFM) {
                LastFMSettingsPage(connection: lastFM)
            }
            // Demo runs have no real store to sync, so the pane stays out of the window.
            if let cloud {
                Tab("iCloud", systemImage: "icloud", value: .iCloud) {
                    CloudSyncPage(sync: cloud)
                }
            }
            Tab("Devices", systemImage: "laptopcomputer.and.iphone", value: .devices) {
                DevicesSettingsPage()
                    .environment(model.player)
            }
            Tab("Menu Bar", systemImage: "menubar.rectangle", value: .menuBar) {
                MenuBarSettingsPane()
            }
        }
        .environment(model)
        .onAppear {
            if cloud == nil, let store = model.store, !model.isDemoLaunch {
                cloud = CloudSyncSettings(store: store, monitor: model.syncMonitor)
            }
            // A pane that isn't there this run falls back to General.
            if pane == .iCloud, cloud == nil { pane = .general }
        }
    }
}
