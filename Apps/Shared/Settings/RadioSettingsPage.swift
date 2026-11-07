import SwiftUI
import WidgetKit
import TracksCore

/// Where radio songs go, which stations count, and Play Back. An iPhone page, and the Mac's
/// Radio pane.
struct RadioSettingsPage: View {
    private let settings = CaptureSettings()

    @AppStorage(CaptureSettings.autoAddKey, store: CaptureSettings.sharedDefaults)
    private var addsSongs = true
    /// Watched so the status follows a rename, including one made on another device.
    @AppStorage(CaptureSettings.playlistNameKey, store: CaptureSettings.sharedDefaults)
    private var storedName = ""
    @AppStorage(CaptureSettings.showsUpNextInWidgetKey, store: CaptureSettings.sharedDefaults)
    private var showsUpNext = true
    #if os(macOS)
    @AppStorage(CaptureSettings.autoPlayBackKey, store: CaptureSettings.sharedDefaults)
    private var playsBack = false
    #endif

    /// Typed here and saved on Return or on leaving, so a half-typed name never names the
    /// playlist Tracks writes to.
    @State private var playlistName = ""
    /// A diagnostic override for the machine it's switched on, so it doesn't mirror.
    @State private var treatsEverythingAsRadio = CaptureSettings().forceCapture

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isNameFocused: Bool

    private var playlist: RadioSettingsWords.Playlist {
        RadioSettingsWords.Playlist(addsSongs: addsSongs, name: storedName)
    }

    var body: some View {
        Form {
            SettingsHero(
                "Radio",
                subtitle: Text(RadioSettingsWords.status(playlist)),
                systemImage: "dot.radiowaves.left.and.right",
                tint: .orange
            )
            playlistSection
            playBackSection
            StationExclusionsSection()
            troubleshootingSection
        }
        .animation(SettingsMotion.row(reduceMotion: reduceMotion), value: addsSongs)
        .onAppear { playlistName = settings.playlistName }
        .onDisappear(perform: saveName)
        .onChange(of: treatsEverythingAsRadio) { _, value in settings.forceCapture = value }
        .onChange(of: storedName) { playlistName = settings.playlistName }
        #if os(macOS)
        .settingsPane()
        #else
        .settingsPage("Radio")
        .scrollDismissesKeyboard(.interactively)
        #endif
    }

    // MARK: - Playlist

    private var playlistSection: some View {
        Section {
            SettingsSwitch(
                "Add Songs to a Playlist",
                detail: addsSongs
                    ? Text("Songs you hear on Apple Music radio go into a playlist in your library.")
                    : Text("Radio songs stay in your Tracks history only."),
                isOn: $addsSongs
            )
            if addsSongs {
                LabeledContent("Name") {
                    TextField("Name", text: $playlistName, prompt: Text(CaptureSettings.defaultPlaylistName))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.done)
                        .focused($isNameFocused)
                        .onSubmit(saveName)
                        #if os(iOS)
                        // Grey like the values around it, until it's being typed in.
                        .foregroundStyle(isNameFocused ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        #endif
                }
            }
        } header: {
            Text("Playlist")
        } footer: {
            playlistFooter
                .contentTransition(.opacity)
        }
    }

    @ViewBuilder
    private var playlistFooter: some View {
        // Said once, where the choice is made: nothing can take a song back out.
        if addsSongs {
            Text("Songs stay in the playlist until you remove them in Apple Music. Tracks can add songs but can’t take them out.")
        } else {
            #if os(iOS)
            Text("Turn this on to collect what you hear on radio in a playlist in your library.")
            #endif
        }
    }

    // MARK: - Play Back

    @ViewBuilder
    private var playBackSection: some View {
        #if os(macOS)
        Section {
            SettingsSwitch(
                "Play Back Automatically",
                detail: playsBack
                    ? Text("A couple of minutes after a station stops, Tracks plays its songs again so Apple Music counts them.")
                    : Text("Radio songs don’t reach your play counts, Replay or recommendations until you play them back."),
                isOn: $playsBack
            )
            SettingsSwitch(
                "Show Up Next in Widgets",
                detail: Text("The Today widget lists the songs Play Back will play next."),
                isOn: widgetUpNext
            )
        } header: {
            Text("Play Back")
        } footer: {
            Text("Play Back only starts when you’re at your Mac, and never over music you chose.")
        }
        #else
        Section {
            Toggle("Show Up Next", isOn: widgetUpNext)
        } header: {
            Text("Widget")
        } footer: {
            Text(showsUpNext
                ? "The Today widget lists the radio songs Play Back will play next."
                : "The Today widget shows what you played, and not what Play Back will play next.")
                .contentTransition(.opacity)
        }
        #endif
    }

    /// Reloads the widget as it changes, rather than leaving it for its next refresh.
    private var widgetUpNext: Binding<Bool> {
        Binding(
            get: { showsUpNext },
            set: { value in
                showsUpNext = value
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.today)
            }
        )
    }

    // MARK: - Troubleshooting

    private var troubleshootingSection: some View {
        Section {
            SettingsSwitch(
                "Treat Everything as Radio",
                detail: treatsEverythingAsRadio
                    ? Text("Every song is kept and handled as radio, even ones you chose.")
                    : Text("For when Tracks misses a station. Stays on this Mac."),
                isOn: $treatsEverythingAsRadio
            )
        } header: {
            Text("Troubleshooting")
        } footer: {
            #if os(iOS)
            Text(treatsEverythingAsRadio
                ? "Every song is kept and handled as radio, even ones you chose. This stays on this iPhone."
                : "Turn this on if Tracks ever misses a station. It stays on this iPhone.")
                .contentTransition(.opacity)
            #endif
        }
    }

    private func saveName() {
        // Blank means "use the default"; a single space once got saved and Music could never
        // find a playlist called " ".
        let trimmed = playlistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            playlistName = settings.playlistName
            return
        }
        settings.playlistName = trimmed
    }
}
