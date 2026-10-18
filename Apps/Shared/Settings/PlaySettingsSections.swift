import SwiftUI
import MusicKit
import TracksCore

extension PlaySettingsWords.Standing {
    /// Where Play stands right now. `offlineSongs` is iPhone's Offline Mode, nil when it's off.
    init(model: AppModel, music: YourMusic, offlineSongs: Int? = nil) {
        let servers = music.servers
        let troubled = servers.servers.lazy.compactMap { server -> PlaySettingsWords.TroubledServer? in
            switch servers.status[server.id] {
            case .wrongPassword: PlaySettingsWords.TroubledServer(name: server.name, needsPassword: true)
            case .offline, .failed: PlaySettingsWords.TroubledServer(name: server.name, needsPassword: false)
            case .online, .connecting, nil: nil
            }
        }.first
        self.init(
            source: model.musicSource,
            opening: OpeningTab.current,
            // Sample data plays without Apple Music.
            allowsAppleMusic: model.musicAuthorization == .authorized || model.isDemoLaunch,
            offlineSongs: offlineSongs,
            songs: music.index.tracks.count,
            servers: servers.servers.count,
            troubledServer: troubled
        )
    }
}

extension PlaySettingsWords.QuickSwitchState {
    @MainActor
    init(music: YourMusic, isOn: Bool) {
        self = QuickSwitch.isAvailable(music) ? (isOn ? .on : .off) : .unavailable
    }
}

/// Merging your Tracks playlists with your Apple Music ones: off until you turn it on, since it
/// asks for Apple Music.
struct PlaySettingsPlaylistMerge: View {
    @Environment(YourMusic.self) private var music
    @AppStorage(PlaylistMerge.storageKey) private var isOn = false
    @State private var isTurningOn = false

    var body: some View {
        let merge = music.playlistMerge
        Section {
            SettingsSwitch(
                "Merge with Apple Music",
                detail: isOn
                    ? Text("Playlists with the same name in Tracks and Apple Music are one.")
                    : Text("Keep your playlists and Apple Music’s apart."),
                isOn: Binding(get: { isOn }, set: toggle)
            )
            .disabled(isTurningOn)
            if isOn {
                #if os(macOS)
                SettingsDetailRow(title: Text("Merge Now"), detail: lastMerged(merge)) {
                    if merge.isMerging {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 80)
                    } else {
                        Button("Merge Now") { Task { await merge.merge() } }
                    }
                }
                #else
                Button {
                    Task { await merge.merge() }
                } label: {
                    HStack {
                        Text(merge.isMerging ? "Merging…" : "Merge Now")
                        Spacer()
                        if merge.isMerging { ProgressView() }
                    }
                }
                .disabled(merge.isMerging)
                #endif
            }
        } header: {
            Text("Playlists")
        } footer: {
            footer(merge)
                .contentTransition(.opacity)
        }
    }

    private func toggle(_ on: Bool) {
        if on {
            isTurningOn = true
            Task {
                _ = await music.playlistMerge.turnOn()
                isTurningOn = false
            }
        } else {
            music.playlistMerge.turnOff()
        }
    }

    private func lastMerged(_ merge: PlaylistMerge) -> Text {
        if merge.isMerging { return Text("Merging…") }
        guard let last = merge.lastMerged else { return Text("Not merged yet. Tracks merges each time it opens.") }
        return Text("Merged \(last.formatted(.relative(presentation: .named))). Tracks merges each time it opens.")
    }

    private func footer(_ merge: PlaylistMerge) -> Text {
        if let problem = merge.problem {
            return Text(problem).foregroundStyle(.ink(.red))
        }
        guard isOn else {
            return Text("Playlists with the same name in Tracks and Apple Music become one, and each gets the other’s songs. Songs added in Apple Music are found on your server and downloaded; songs added in Tracks are added in Apple Music.")
        }
        var lines: [String] = []
        #if os(iOS)
        if let last = merge.lastMerged {
            lines.append(String(localized: "Merged \(last.formatted(.relative(presentation: .named)))."))
        }
        #endif
        if merge.leftToFind > 0 {
            lines.append(PlaySettingsWords.plain(AttributedString(localized: "^[\(merge.leftToFind) song](inflect: true) from Apple Music still to find on your server, a few each time Tracks opens.")))
        }
        lines.append(String(localized: "Apple Music doesn’t let apps take songs out of playlists, so songs taken out in Tracks stay in Apple Music. Songs taken out in Apple Music come out here too."))
        return Text(lines.joined(separator: " "))
    }
}

/// Resetting what the mixes remember, with a confirmation that says what comes back.
struct PlaySettingsMixes: View {
    @Environment(PlayerModel.self) private var player
    @State private var confirmsReset = false

    var body: some View {
        let memory = PlaySettingsWords.MixMemory(player.signals)
        Section {
            #if os(macOS)
            SettingsDetailRow(title: Text("Mix Suggestions"), detail: Text(PlaySettingsWords.mixDetail(memory))) {
                if !memory.isEmpty {
                    Button("Reset…") { confirmsReset = true }
                        .modifier(ResetConfirmation(isPresented: $confirmsReset, memory: memory))
                }
            }
            #else
            if memory.isEmpty {
                LabeledContent("Mix Suggestions", value: String(localized: "Nothing Skipped Yet"))
            } else {
                LabeledContent("Songs Left Out") {
                    Text(memory.leftOut, format: .number)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(memory.leftOut)))
                }
                Button("Reset Mix Suggestions…") { confirmsReset = true }
                    .modifier(ResetConfirmation(isPresented: $confirmsReset, memory: memory))
            }
            #endif
        } header: {
            Text("Mixes")
        } footer: {
            Text(PlaySettingsWords.mixesFooter)
        }
    }
}

/// Asks before the mixes forget, saying what comes back. Attached to the button that asks.
private struct ResetConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    let memory: PlaySettingsWords.MixMemory
    @Environment(PlayerModel.self) private var player

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Reset Mix Suggestions?", isPresented: $isPresented, titleVisibility: .visible) {
                Button(PlaySettingsWords.resetButton(memory), role: .destructive) { player.resetSignals() }
            } message: {
                Text(PlaySettingsWords.resetMessage(memory))
            }
    }
}
