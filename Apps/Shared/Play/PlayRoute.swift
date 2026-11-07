import SwiftUI
import MusicKit
import TracksCore

/// Places the Play tab, and Apple Music results in Search, can push.
enum PlayRoute: Hashable {
    /// A mix, by ``TracksCore/Mix/id``, so it follows the history as it's rebuilt.
    case mix(String)
    case album(Album)
    case playlist(Playlist)
    case artist(Artist)
    case library(LibrarySection)
    case mood(Mood)
    /// Finding a playlist for a party: Party's own page, rather than the mood's.
    case party
    /// A genre's page: its station, its charts, and what you play of it.
    case genre(MusicGenre)
    /// Songs you've never played, through one lens or another.
    case songFinder(SongLens)
    /// Artists you've never played, like the ones you do.
    case artistFinder
    /// Everything new and coming from your artists.
    case newReleases
    /// An album in your own music, by its id in the library.
    case localAlbum(String)
    /// An artist in your own music, by its id in the library.
    case localArtist(String)
    /// An album on one of your servers, found there rather than in the library.
    case serverAlbum(serverID: String, albumID: String)
    /// An artist on one of your servers, found there rather than in the library.
    case serverArtist(ServerArtist)
    /// All your songs, albums or artists, or what's downloaded.
    case yourMusic(YourMusicList)
    /// A playlist you made in Tracks, by its id.
    case tracksPlaylist(UUID)
    /// Lidarr: what it's fetching, wants, has coming and follows.
    case lidarr
    /// An artist Lidarr follows, by its id there.
    case lidarrArtist(Int)
    /// An artist from the history, known by name: found in Apple Music when the page opens.
    case artistNamed(String, identity: String)
    /// One of Tracks’ own pages, for a menu that can only push through ``OpenPlayRouteAction``.
    case stats(Route)
}

/// The parts of the Apple Music library the Play tab lists.
enum LibrarySection: String, CaseIterable, Identifiable, Hashable {
    case playlists, albums, artists, songs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playlists: String(localized: "Playlists")
        case .albums: String(localized: "Albums")
        case .artists: String(localized: "Artists")
        case .songs: String(localized: "Songs")
        }
    }

    var symbol: String {
        switch self {
        case .playlists: "music.note.list"
        case .albums: "square.stack"
        case .artists: "music.microphone"
        case .songs: "music.note"
        }
    }
}

/// Moves the Play tab from elsewhere: Now Playing's Go to Album, a link that opened the app.
@MainActor
@Observable
final class PlayNavigator {
    /// Not typed: the tab pushes Tracks’ own pages too (a song's stats, an artist's).
    var path = NavigationPath()

    func show(_ route: PlayRoute) {
        path.append(route)
    }
}

extension View {
    /// The pages any stack that shows Apple Music content can push.
    func playDestinations() -> some View {
        navigationDestination(for: PlayRoute.self) { route in
            PlayDestination(route: route)
                .pageChrome()
        }
    }
}

/// The page for a route.
private struct PlayDestination: View {
    let route: PlayRoute

    var body: some View {
        switch route {
        case .mix(let id): MixDetailView(mixID: id)
        case .album(let album): AlbumPage(album: album)
        case .playlist(let playlist): PlaylistPage(playlist: playlist)
        case .artist(let artist): ArtistPage(artist: artist)
        case .library(let section): LibraryListView(section: section)
        case .mood(let mood):
            // Your own music's moods ask nothing of Apple Music.
            if MusicSource.current == .yourMusic {
                YourMusicMoodView(mood: mood)
            } else {
                MoodView(mood: mood)
            }
        case .party: PartyView()
        case .genre(let genre): GenreView(genre: genre)
        case .songFinder(let lens): SongFinder(lens: lens)
        case .artistFinder: ArtistFinder()
        case .newReleases: NewReleasesPage()
        case .localAlbum(let id): LocalAlbumPage(albumID: id)
        case .localArtist(let id): LocalArtistPage(artistID: id)
        case .serverAlbum(let serverID, let albumID): ServerAlbumPage(serverID: serverID, albumID: albumID)
        case .serverArtist(let artist): ServerArtistPage(artist: artist)
        case .yourMusic(let list): list.page
        case .tracksPlaylist(let id): TracksPlaylistPage(playlistID: id)
        case .lidarr: LidarrPage()
        case .lidarrArtist(let id): LidarrArtistPage(artistID: id)
        case .artistNamed(let name, let identity): FavoriteArtistPage(name: name, identity: identity)
        case .stats(let route):
            switch route {
            case .artist(let id): ArtistDetailView(artistID: id)
            case .song(let id): SongDetailView(songID: id)
            case .album(let id): AlbumDetailView(albumID: id)
            case .highlights(let range, let offset): HighlightsList(range: range, periodOffset: offset)
            }
        }
    }
}

/// A way of looking for songs in the Song Finder.
enum SongLens: Hashable, Identifiable {
    /// Everything suggested, mixed.
    case forYou
    /// Songs by your own artists you've never played.
    case yourArtists
    /// Songs by artists like yours.
    case likeYourArtists
    /// Songs from your artists' new releases.
    case newReleases
    /// Apple Music's most played.
    case popular
    case mood(Mood)

    var id: String {
        switch self {
        case .forYou: "forYou"
        case .yourArtists: "yourArtists"
        case .likeYourArtists: "likeYourArtists"
        case .newReleases: "newReleases"
        case .popular: "popular"
        case .mood(let mood): "mood.\(mood.rawValue)"
        }
    }

    /// In the order the finder offers them, the moods last.
    static let all: [SongLens] = [.forYou, .yourArtists, .likeYourArtists, .newReleases, .popular] + Mood.allCases.map(SongLens.mood)

    var title: String {
        switch self {
        case .forYou: String(localized: "For You")
        case .yourArtists: String(localized: "Your Artists")
        case .likeYourArtists: String(localized: "Like Your Artists")
        case .newReleases: String(localized: "New Releases")
        case .popular: String(localized: "Popular")
        case .mood(let mood): mood.title
        }
    }

    var symbol: String {
        switch self {
        case .forYou: "sparkles"
        case .yourArtists: "person.crop.circle"
        case .likeYourArtists: "person.2.wave.2"
        case .newReleases: "calendar"
        case .popular: "chart.line.uptrend.xyaxis"
        case .mood(let mood): mood.symbol
        }
    }

    /// One line on what the lens shows.
    var detail: String {
        switch self {
        case .forYou: String(localized: "Songs you've never played, picked from everything you listen to.")
        case .yourArtists: String(localized: "The best songs by artists you play that you haven't heard yet.")
        case .likeYourArtists: String(localized: "Songs by artists you've never played who sound like your favorites.")
        case .newReleases: String(localized: "Songs from what your artists have put out lately.")
        case .popular: String(localized: "What everyone's playing on Apple Music, less what you already know.")
        case .mood(let mood): String(localized: "New songs for \(mood.title), from Apple Music's playlists for it.")
        }
    }
}
