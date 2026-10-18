import SwiftUI
import MusicKit
import TracksCore

/// The playing song's star: a tap favorites it, as Music's does, and holding it offers your
/// playlists to add it to. With a song of yours, which Apple Music can't star, it's Add to
/// Playlist alone.
struct NowPlayingFavoriteButton: View {
    let track: PlayerTrack
    @Environment(PlayerModel.self) private var player
    @Environment(YourMusic.self) private var music
    @State private var playlists: [Playlist]?
    @State private var isNaming = false
    @State private var newName = ""

    var body: some View {
        Group {
            if let song = track.song {
                Menu {
                    appleMusicItems(song)
                } label: {
                    star(isFavorite: player.isFavorite(song))
                } primaryAction: {
                    player.setFavorite(song, !player.isFavorite(song))
                }
                .accessibilityLabel(player.isFavorite(song) ? "Undo Favorite" : "Favorite")
                .accessibilityHint("Touch and hold to add to a playlist.")
                .sensoryFeedback(.impact(weight: .light), trigger: player.isFavorite(song))
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
                    icon("text.badge.plus", isOn: false)
                }
                .accessibilityLabel("Add to Playlist")
            } else {
                // A song known by name alone, as in the demo: nothing to star.
                star(isFavorite: false)
                    .opacity(0.5)
                    .accessibilityLabel("Favorite")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityRemoveTraits(.isImage)
            }
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

    private func star(isFavorite: Bool) -> some View {
        icon(isFavorite ? "star.fill" : "star", isOn: isFavorite)
            .contentTransition(.symbolEffect(.replace))
    }

    private func icon(_ systemImage: String, isOn: Bool) -> some View {
        Image(systemName: systemImage)
            .font(.title3)
            .foregroundStyle(.white.opacity(isOn ? 1 : 0.7))
            .frame(width: 44, height: 44)
            .contentShape(.rect)
    }

    /// Your own playlists, most recently played first: the ones Apple Music lets you add to.
    private func loadPlaylists() async {
        guard playlists == nil, !player.isDemo else { return }
        var request = MusicLibraryRequest<Playlist>()
        request.sort(by: \.lastPlayedDate, ascending: false)
        let found = (try? await request.response().items).map(Array.init) ?? []
        playlists = found.filter { $0.kind == nil || $0.kind == .userShared }
    }
}
