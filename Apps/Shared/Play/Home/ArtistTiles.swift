import SwiftUI
import MusicKit
import TracksCore

/// One of the artists you play most: their picture in a circle, their name, and how often.
struct FavoriteArtistTile: View {
    let artist: FavoriteArtist
    @Environment(AppModel.self) private var model
    @Environment(PlayerModel.self) private var player
    @Environment(\.openPlayRoute) private var openPlayRoute

    var body: some View {
        NavigationLink(value: PlayRoute.artistNamed(artist.name, identity: artist.id)) {
            ArtistCircleTile(
                name: artist.name,
                picture: .artistPicture(url: artist.artworkURL, name: artist.name),
                detail: PlayCountText.short(artist.plays)
            )
        }
        .buttonStyle(.pressable)
        .contextMenu {
            Button("Play Your Favorites", systemImage: "play") { playFavorites(shuffled: false) }
            Button("Shuffle Your Favorites", systemImage: "shuffle") { playFavorites(shuffled: true) }
            if !player.isDemo {
                Button("Create Station", systemImage: "dot.radiowaves.left.and.right") {
                    Task {
                        if let catalog = await model.playFeed.catalogArtist(named: artist.name) {
                            player.playStation(from: catalog)
                        } else {
                            player.problem = .failed(String(localized: "Couldn't find \(artist.name) in Apple Music."))
                        }
                    }
                }
            }
            Divider()
            Button("Your Stats", systemImage: "chart.bar.xaxis") {
                openPlayRoute(.stats(.artist(artist.id)))
            }
            Divider()
            BlockArtistButton(artist: artist.name, namesArtist: true)
        }
    }

    /// Your most played songs by them, from the history, gathered away from the main actor
    /// since it walks every play.
    private func playFavorites(shuffled: Bool) {
        let (history, identity, player, context) = (model.library.history, artist.id, player, PlayContext(kind: .artist, title: artist.name))
        Task {
            let songs = await OffMainActor.run { PlayFacts.songs(byArtist: identity, in: history) }
                .filter { player.canPlay(songID: $0.songID) }
                .map(HistorySong.init)
            await player.start(.history(songs), from: context, shuffled: shuffled)
        }
    }
}

/// A favourite artist's page, found in Apple Music by name as it opens. Without Apple Music
/// (sample data, offline, no match) it shows Tracks’ own page for them instead.
struct FavoriteArtistPage: View {
    let name: String
    let identity: String
    @Environment(PlayFeed.self) private var feed
    @State private var artist: Artist?
    @State private var hasLooked = false

    private var artworkURL: String? {
        feed.favoriteArtists.first { $0.id == identity }?.artworkURL
    }

    var body: some View {
        Group {
            if let artist {
                ArtistPage(artist: artist)
            } else if hasLooked {
                ArtistDetailView(artistID: identity)
            } else {
                // The artist's page as it will be, their picture and name already in place.
                ArtistScaffold(name: name, picture: .artistPicture(url: artworkURL, name: name), showsYourTopSongs: false) {
                    ArtistLoadingSections()
                }
                .scrollDisabled(true)
            }
        }
        .task {
            artist = await feed.catalogArtist(named: name)
            hasLooked = true
        }
    }
}
