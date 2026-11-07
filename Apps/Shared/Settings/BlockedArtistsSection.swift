import SwiftUI
import TracksCore

/// The artists Tracks never plays or suggests, to look over and unblock. Artists are blocked
/// from their page or a song's menu, where you meet them, not typed in here.
///
/// Reads the player's copy of the list, which follows other devices, so a block made on the
/// Mac shows here as it lands.
struct BlockedArtistsSection: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let names = player.signals.blocked.names
        Section {
            if names.isEmpty {
                Text("No Blocked Artists")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(names, id: \.self) { name in
                    row(name)
                }
            }
        } header: {
            Text("Blocked Artists")
        } footer: {
            Text(names.isEmpty
                ? "Block an artist from their page or a song’s menu, and Tracks won’t play or suggest them on any of your devices."
                : "Tracks won’t play or suggest these artists on any of your devices, and skips their songs on stations. Songs you’ve already played stay in your history.")
        }
        .animation(SettingsMotion.row(reduceMotion: reduceMotion), value: names)
    }

    private func row(_ name: String) -> some View {
        HStack {
            Text(name)
                .lineLimit(1)
            Spacer(minLength: 12)
            Button("Unblock") { player.unblock(artist: name) }
                #if os(macOS)
                // A push button, as the pane's other actions are.
                .buttonStyle(.bordered)
                #else
                .buttonStyle(.borderless)
                #endif
                .accessibilityLabel("Unblock \(name)")
        }
        #if os(iOS)
        .swipeActions {
            Button("Unblock") { player.unblock(artist: name) }
                .tint(.accentColor)
        }
        #endif
    }
}
