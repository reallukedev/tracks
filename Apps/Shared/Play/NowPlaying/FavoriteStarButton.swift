import SwiftUI
import MusicKit
import TracksCore

/// The playing song's star, beside the player's controls: a click or tap favorites it, as
/// Music's does, and holding it offers your playlists to add it to. With a song of yours,
/// which Apple Music can't star, it's Add to Playlist alone.
///
/// Each platform draws the glyph its own way; `icon` gets the symbol and whether it's on.
struct FavoriteStarButton<Icon: View>: View {
    let track: PlayerTrack
    @ViewBuilder let icon: (_ systemImage: String, _ isOn: Bool) -> Icon
    @Environment(PlayerModel.self) private var player
    @State private var playlists: [Playlist]?
    @State private var isNaming = false
    @State private var newName = ""

    var body: some View {
        if let song = track.song {
            let isFavorite = player.isFavorite(song)
            Menu {
                appleMusicItems(song)
            } label: {
                icon(isFavorite ? "star.fill" : "star", isFavorite)
                    .contentTransition(.symbolEffect(.replace))
            } primaryAction: {
                player.setFavorite(song, !isFavorite)
            }
            .accessibilityLabel(isFavorite ? "Undo Favorite" : "Favorite")
            .accessibilityHint("Touch and hold to add to a playlist.")
            #if os(macOS)
            .help(isFavorite ? "Undo Favorite. Hold for Add to Playlist." : "Favorite. Hold for Add to Playlist.")
            .contextMenu { appleMusicItems(song) }
            #endif
            .sensoryFeedback(.impact(weight: .light), trigger: isFavorite)
            .task(id: song.id) { player.lookUpFavorite(song) }
            .task { await loadPlaylists() }
            .alert("New Playlist", isPresented: $isNaming) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { player.add(song, toPlaylist: nil, named: newName) }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            } message: {
                Text("“\(song.title)” will be its first song.")
            }
        } else if let local = track.local {
            Menu {
                AddToPlaylistMenu(tracks: [local])
            } label: {
                icon("text.badge.plus", false)
            }
            .accessibilityLabel("Add to Playlist")
            #if os(macOS)
            .help("Add to Playlist")
            #endif
        } else {
            // A song known by name alone, as in the demo: nothing to star.
            Button {} label: { icon("star", false) }
                .disabled(true)
                .accessibilityLabel("Favorite")
        }
    }

    @ViewBuilder
    private func appleMusicItems(_ song: Song) -> some View {
        Section("Add to Playlist") {
            Button("New Playlist…", systemImage: "plus") {
                newName = ""
                isNaming = true
            }
            if let playlists {
                ForEach(playlists) { playlist in
                    Button(playlist.name) { player.add(song, toPlaylist: playlist, named: playlist.name) }
                }
            } else {
                Text("Loading Playlists…")
            }
        }
    }

    /// Your own playlists, most recently played first: the ones Apple Music lets you add to.
    private func loadPlaylists() async {
        guard playlists == nil, !player.isDemo else { return }
        var request = MusicLibraryRequest<Playlist>()
        #if os(iOS)
        request.sort(by: \.lastPlayedDate, ascending: false)
        #endif
        let found = (try? await request.response().items).map(Array.init) ?? []
        playlists = found.filter { $0.kind == nil || $0.kind == .userShared }
    }
}
