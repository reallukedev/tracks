import SwiftUI
import ServiceManagement
import TracksCore

/// Opening at login, the Dock, Apple Music access, and About.
struct GeneralSettingsPane: View {
    @Environment(MacAppBehaviour.self) private var behaviour
    @Environment(UnexpectedQuitMonitor.self) private var quitMonitor
    @AppStorage("showMenuBarExtra") private var showsMenuBarExtra = true
    @State private var launchesAtLogin = false

    var body: some View {
        @Bindable var behaviour = behaviour
        @Bindable var quitMonitor = quitMonitor

        Form {
            SettingsHero(
                "General",
                subtitle: statusTone.apply(to: Text(statusLine)),
                systemImage: "gearshape.fill",
                tint: .gray
            )

            Section {
                SettingsDetailRow(title: Text("Open at Login"), detail: loginDetail) {
                    if behaviour.launchAtLoginNeedsApproval {
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    Toggle("Open at Login", isOn: $launchesAtLogin)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                SettingsSwitch(
                    "Show in Dock",
                    detail: dockDetail,
                    isOn: $behaviour.showsDockIcon
                )
                // With the menu bar extra hidden too there'd be no way back into Tracks.
                .disabled(behaviour.showsDockIcon && !showsMenuBarExtra)
                SettingsSwitch(
                    "Reopen Tracks If It Quits Unexpectedly",
                    detail: reopenDetail,
                    isOn: $quitMonitor.reopensAutomatically
                )
            } header: {
                Text("Startup")
            }

            AppleMusicAccessSection()
            AboutSection()
        }
        .settingsPane()
        .onAppear {
            // Reads the status only. Registering happens when the switch is flipped.
            behaviour.refreshLoginItemStatus()
            launchesAtLogin = behaviour.launchesAtLogin
        }
        .onChange(of: launchesAtLogin) { _, wanted in
            // Only a change the person made. Showing the current status, on appear or after
            // a failure, writes the value it already has.
            guard wanted != behaviour.launchesAtLogin else { return }
            behaviour.setLaunchesAtLogin(wanted)
            // What actually happened, so a failed attempt puts the switch back.
            launchesAtLogin = behaviour.launchesAtLogin
        }
    }

    private var statusLine: String {
        if behaviour.launchAtLoginNeedsApproval {
            return String(localized: "Allow Tracks under Login Items to finish turning on Open at Login.")
        }
        return behaviour.launchesAtLogin
            ? String(localized: "Opens when you log in, so nothing you play gets missed.")
            : String(localized: "Tracks only notices what’s playing while it’s open.")
    }

    private var statusTone: SettingsTone {
        behaviour.launchAtLoginNeedsApproval ? .attention : .plain
    }

    private var loginDetail: Text {
        if let error = behaviour.launchAtLoginError {
            return Text(error).foregroundStyle(.ink(.red))
        }
        if behaviour.launchAtLoginNeedsApproval {
            return Text("Waiting for you to allow it in System Settings ▸ General ▸ Login Items.")
        }
        return behaviour.launchesAtLogin
            ? Text("Tracks starts in the background when you log in.")
            : Text("Open Tracks yourself. It fills in what it missed from Recently Played.")
    }

    private var reopenDetail: Text {
        quitMonitor.reopensAutomatically
            ? Text("If macOS closes Tracks, it opens again. Quit and Force Quit leave it closed.")
            : Text("If macOS closes Tracks, it stays closed until you open it.")
    }

    private var dockDetail: Text {
        if behaviour.showsDockIcon && !showsMenuBarExtra {
            return Text("Needed while Tracks is hidden from the menu bar, so there’s a way back in.")
        }
        return behaviour.showsDockIcon
            ? Text("Tracks shows in the Dock and the app switcher.")
            : Text("Tracks lives in the menu bar only.")
    }
}

#if DEBUG
/// A model on sample data. The flag goes in a volatile domain, so it never reaches the real
/// app's defaults, and a preview never opens the real store.
@MainActor
private let previewModel: AppModel = {
    UserDefaults.standard.setVolatileDomain(["TracksDemoData": true], forName: UserDefaults.argumentDomain)
    return AppModel()
}()

private struct PanePreview<Pane: View>: View {
    @ViewBuilder var pane: Pane

    var body: some View {
        pane
            .environment(previewModel)
            .environment(MacAppBehaviour())
            .environment(UnexpectedQuitMonitor())
    }
}

#Preview("General") { PanePreview { GeneralSettingsPane() } }
#Preview("History") { PanePreview { HistorySettingsPage() } }
#Preview("Radio") { PanePreview { RadioSettingsPage() } }
#Preview("Menu Bar") { PanePreview { MenuBarSettingsPane() } }
#endif
