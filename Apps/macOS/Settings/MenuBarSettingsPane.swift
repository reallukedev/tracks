import SwiftUI
import TracksCore

/// Whether Tracks sits in the menu bar, and what it shows there. `@AppStorage` throughout, so
/// the status item redraws the moment anything here changes.
struct MenuBarSettingsPane: View {
    @Environment(MacAppBehaviour.self) private var behaviour
    @AppStorage("showMenuBarExtra") private var showsMenuBarExtra = true
    @AppStorage(CaptureSettings.menuBarLabelStyleKey, store: CaptureSettings.sharedDefaults)
    private var styleRaw = MenuBarLabelStyle.default.rawValue
    @AppStorage(CaptureSettings.menuBarLabelFormatKey, store: CaptureSettings.sharedDefaults)
    private var format = MenuBarLabelFormat.default
    @AppStorage(CaptureSettings.animatesMenuBarKey, store: CaptureSettings.sharedDefaults)
    private var animates = true
    @AppStorage(CaptureSettings.showsMenuBarProgressKey, store: CaptureSettings.sharedDefaults)
    private var showsProgress = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var style: MenuBarLabelStyle {
        MenuBarLabelStyle(stored: styleRaw)
    }

    var body: some View {
        Form {
            SettingsHero(
                "Menu Bar",
                subtitle: Text(statusLine),
                systemImage: "menubar.rectangle",
                tint: .purple
            ) {
                Toggle("Show in Menu Bar", isOn: $showsMenuBarExtra)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    // With the Dock icon hidden too there'd be no way back into Tracks.
                    .disabled(showsMenuBarExtra && !behaviour.showsDockIcon)
                    .help(showsMenuBarExtra && !behaviour.showsDockIcon
                        ? Text("Show Tracks in the Dock first, so there’s a way back in.")
                        : Text("Show in Menu Bar"))
            }

            if showsMenuBarExtra {
                Section {
                    Picker("Show", selection: $styleRaw) {
                        ForEach(MenuBarLabelStyle.allCases) { style in
                            Text(style.name).tag(style.rawValue)
                        }
                    }
                    if style == .custom {
                        TextField("Format", text: $format, prompt: Text(MenuBarLabelFormat.default))
                            .font(.body.monospaced())
                        LabeledContent("Preview") {
                            // The function the status item uses, so an empty result looks empty
                            // here too.
                            Text(preview.isEmpty ? String(localized: "Nothing") : preview)
                                .foregroundStyle(preview.isEmpty ? .tertiary : .secondary)
                                .lineLimit(1)
                        }
                    }
                    SettingsSwitch(
                        "Animate Song Changes",
                        detail: animates
                            ? Text("The new song fades in. Reduce Motion turns this off.")
                            : Text("The new song replaces the old one at once."),
                        isOn: $animates
                    )
                    SettingsSwitch(
                        "Show Song Progress",
                        detail: showsProgress
                            ? Text("The menu bar window shows how far into the song you are. Click or drag it to move.")
                            : Text("The menu bar window shows the song and its controls only."),
                        isOn: $showsProgress
                    )
                } header: {
                    Text("While Music Plays")
                } footer: {
                    if style == .custom {
                        Text("Use \(MenuBarLabelFormat.tokens.joined(separator: ", ")). Long labels are shortened so they can’t push other apps off the menu bar.")
                    }
                }
            }
        }
        .animation(SettingsMotion.row(reduceMotion: reduceMotion), value: showsMenuBarExtra)
        .animation(SettingsMotion.row(reduceMotion: reduceMotion), value: style)
        .settingsPane()
    }

    private var statusLine: String {
        guard showsMenuBarExtra else {
            return String(localized: "Hidden. Open Tracks from the Dock.")
        }
        return String(localized: "Shows \(style.phrase) while music plays")
    }

    private var preview: String {
        MenuBarLabelFormat.render(
            format,
            title: "Saltwater",
            artist: "Mara Solis",
            album: "Tides",
            station: "Chill Station"
        )
    }
}
