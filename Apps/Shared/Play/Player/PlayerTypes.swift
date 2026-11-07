import Foundation
import MusicKit
import TracksCore

/// A cover to draw: MusicKit's own artwork where the player or the catalog gave one, or an
/// address from the history, drawn by ``ArtworkView`` with its generated fallback.
nonisolated enum CoverArt: Hashable, Sendable, Codable {
    case artwork(Artwork)
    case url(String?, seed: String)
}

/// A song in the player's queue, as the screens show it.
nonisolated struct PlayerTrack: Identifiable, Equatable, Codable, Sendable {
    /// The queue entry's id, which differs between two copies of one song in a queue.
    let id: String
    let title: String
    let artistName: String
    let albumTitle: String?
    let cover: CoverArt
    /// Nil on a live broadcast, where a song has no length to show. See ``SongLength``.
    let duration: TimeInterval?
    let isExplicit: Bool
    /// The song itself, for Add to Library, Go to Album and Create Station. Nil in the demo,
    /// and for your own music.
    let song: Song?
    /// The song in your own music, when that's where it's playing from.
    var local: LocalTrack? = nil

    /// The key Tracks’ history groups plays by, so a song's count can be found.
    var songIdentity: String { HistoryImport.key(title: title, artistName: artistName) }
}

extension MixSong {
    /// A song in the player, for a live mix to start from: one of yours as the song it is,
    /// anything else by its catalog id.
    init(_ track: PlayerTrack) {
        if let local = track.local {
            self = local.mixSong()
            return
        }
        self.init(
            songIdentity: track.songIdentity,
            songID: track.song?.id.rawValue ?? "",
            title: track.title,
            artistName: track.artistName,
            albumTitle: track.albumTitle,
            artworkURL: nil,
            plays: 0,
            lastHeard: .distantPast,
            genre: track.song?.genreNames.first { $0 != "Music" }
        )
    }
}

/// Where the music is coming from, for "Playing from" and for telling captures apart.
struct PlayContext: Equatable {
    enum Kind: Equatable {
        case station, mix, album, playlist, artist, songs
        /// Tracks Radio, which tops itself up as it plays.
        case endless
    }

    let kind: Kind
    let title: String

    var isStation: Bool { kind == .station }

    static func songs(_ title: String) -> PlayContext { PlayContext(kind: .songs, title: title) }

    static let tracksRadio = PlayContext(kind: .endless, title: String(localized: "Tracks Radio"))
}

// Your other devices name what's playing with TracksCore's own words.
extension PlayContext {
    init?(_ nearby: NearbyContext) {
        let kind: Kind? = switch nearby.kind {
        case .station: .station
        case .mix: .mix
        case .album: .album
        case .playlist: .playlist
        case .artist: .artist
        case .songs: .songs
        case .endless: .endless
        case nil: nil
        }
        guard let kind else { return nil }
        self.init(kind: kind, title: nearby.title)
    }
}

extension NearbyContext {
    init(_ context: PlayContext) {
        let kind: Kind = switch context.kind {
        case .station: .station
        case .mix: .mix
        case .album: .album
        case .playlist: .playlist
        case .artist: .artist
        case .songs: .songs
        case .endless: .endless
        }
        self.init(kind: kind, title: context.title)
    }
}

extension NearbySong {
    init(_ track: PlayerTrack) {
        self.init(title: track.title, artist: track.artistName, album: track.albumTitle, duration: track.duration)
    }
}

/// A song from Tracks’ history, known by id and by name. The demo player plays these by name,
/// since sample songs have no catalog ids.
nonisolated struct HistorySong: Equatable, Sendable {
    let songID: String
    let title: String
    let artistName: String
    let albumTitle: String?
    let artworkURL: String?

    init(songID: String, title: String, artistName: String, albumTitle: String? = nil, artworkURL: String? = nil) {
        self.songID = songID
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.artworkURL = artworkURL
    }

    init(_ song: MixSong) {
        self.init(
            songID: song.songID,
            title: song.title,
            artistName: song.artistName,
            albumTitle: song.albumTitle,
            artworkURL: song.artworkURL
        )
    }

    init(_ track: LocalTrack) {
        self.init(songID: track.id, title: track.title, artistName: track.artist, albumTitle: track.album)
    }

    /// A song in the player: one of yours as the song it is, anything else by its id.
    init(_ track: PlayerTrack) {
        if let local = track.local {
            self.init(local)
        } else {
            self.init(songID: track.id, title: track.title, artistName: track.artistName, albumTitle: track.albumTitle)
        }
    }

    init(_ item: PlaybackItem) {
        self.init(songID: item.songID, title: item.title, artistName: item.artistName)
    }
}

/// Something to hand the player.
enum PlayRequest {
    /// Songs from the history: mixes, charts, a song's page.
    case history([HistorySong], startingAt: Int = 0)
    /// Songs straight from Apple Music: search, an artist's top songs, a list of tracks.
    case songs([Song], startingAt: Int = 0)
    case station(MusicKit.Station)
    case album(Album)
    case playlist(Playlist)
    /// A sample station, in the demo.
    case demoStation(String, isLive: Bool)
    /// Songs from your own music: files, and songs on your servers.
    case local([LocalTrack], startingAt: Int = 0)

    /// A live broadcast, such as Apple Music 1, rather than a station of on-demand songs.
    var isLiveBroadcast: Bool {
        switch self {
        case .station(let station): station.isLive
        case .demoStation(_, let isLive): isLive
        default: false
        }
    }
}

enum PlayerStatus: Equatable {
    case stopped, playing, paused
    /// Asked to play, not started yet: a catalog lookup or buffering.
    case loading
}

enum PlayerRepeat: CaseIterable {
    case off, all, one

    var next: PlayerRepeat {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

/// When to stop.
enum SleepTimer: Equatable {
    case at(Date)
    case endOfSong

    static let durations: [Duration] = [.seconds(15 * 60), .seconds(30 * 60), .seconds(45 * 60), .seconds(60 * 60)]
}

/// Why something couldn't play, in words for the person.
enum PlayerProblem: Error, Equatable {
    /// Apple Music access is off. Settings can turn it on.
    case accessDenied
    /// No subscription that can play the catalog. Apple's own offer can fix that.
    case needsSubscription(canSubscribe: Bool)
    /// Nothing in the request could be found in Apple Music.
    case nothingToPlay
    /// Every song in the request is explicit, and explicit songs are off.
    case onlyExplicit
    /// The song asked for is explicit, and explicit songs are off.
    case explicitSong
    /// None of it is in your own music, or none of it can be reached right now.
    case notInYourMusic
    /// Apple Music items asked for while Your Music is the source.
    case needsAppleMusic
    /// The songs left to play are all by an artist the person blocked, named.
    case blockedArtist(String)
    /// What went wrong, and a title when it wasn't playing that failed: adding to the
    /// library, say.
    case failed(String, title: String? = nil)

    var title: String {
        switch self {
        case .accessDenied: String(localized: "Apple Music Access Is Off")
        case .needsSubscription: String(localized: "Playing Needs Apple Music")
        case .nothingToPlay: String(localized: "Couldn't Find These Songs")
        case .onlyExplicit: String(localized: "Only Explicit Versions")
        case .explicitSong: String(localized: "Explicit Song")
        case .notInYourMusic: String(localized: "Not in Your Music")
        case .needsAppleMusic: String(localized: "This Is Apple Music")
        case .blockedArtist(let name): String(localized: "You Blocked \(name)")
        case .failed(_, let title): title ?? String(localized: "Couldn't Play")
        }
    }

    var message: String {
        switch self {
        case .accessDenied:
            String(localized: "Turn on Media & Apple Music for Tracks in Settings to play music here.")
        case .needsSubscription(let canSubscribe):
            canSubscribe
                ? String(localized: "Tracks plays songs from Apple Music, which needs a subscription.")
                : String(localized: "This Apple Account can't play Apple Music songs right now.")
        case .nothingToPlay:
            String(localized: "They may no longer be available in Apple Music.")
        case .onlyExplicit:
            String(localized: "Every song here is explicit. Turn on Explicit Songs in Settings to play them.")
        case .explicitSong:
            String(localized: "Turn on Explicit Songs in Settings to play it.")
        case .notInYourMusic:
            String(localized: "These songs aren't in your music, or their server can't be reached. Download songs to play them anywhere.")
        case .needsAppleMusic:
            String(localized: "Tracks is playing your own music. Switch Music Source to Apple Music in Settings to play this.")
        case .blockedArtist:
            String(localized: "Tracks doesn't play or suggest artists you've blocked. Unblock them to play this.")
        case .failed(let detail, _):
            detail
        }
    }
}

extension PlayerProblem {
    /// An error from something other than playing, titled for what failed. Problems with
    /// their own title, such as access being off, keep it; the rest never talk about playing.
    init(_ error: any Error, couldnt title: String) {
        let problem = PlayerProblem(error)
        guard case .failed(let detail, nil) = problem else {
            self = problem
            return
        }
        // Playback's words for a vague failure are about starting to play.
        let isOwnWords = error is PlayerProblem || error is MusicTokenRequestError || PlaybackFailure(error) == .offline
        self = .failed(isOwnWords ? detail : String(localized: "Try again in a moment."), title: title)
    }

    /// Any error, said plainly: what went wrong and what to do, never the raw domain and code
    /// MusicKit or the network gave.
    init(_ error: any Error) {
        if let problem = error as? PlayerProblem {
            self = problem
            return
        }
        if let tokenError = error as? MusicTokenRequestError {
            switch tokenError {
            case .permissionDenied:
                self = .accessDenied
            case .userNotSignedIn:
                self = .failed(String(localized: "Sign in to Apple Music in Settings, then try again."))
            case .privacyAcknowledgementRequired:
                self = .failed(String(localized: "Open the Music app once to accept Apple Music’s terms, then try again."))
            default:
                self = .failed(String(localized: "Apple Music couldn’t confirm your account just now. Try again in a moment."))
            }
            return
        }
        switch PlaybackFailure(error) {
        case .accessDenied:
            self = .accessDenied
        case .noSubscription:
            self = .needsSubscription(canSubscribe: false)
        case .unavailable:
            self = .nothingToPlay
        case .offline:
            self = .failed(String(localized: "Tracks couldn’t connect. Check your internet connection, then try again."))
        case .timedOut:
            self = .failed(String(localized: "It took too long to start. Try again in a moment."))
        case .superseded, .interrupted, .other:
            self = .failed(String(localized: "Something stopped it from starting. Try again in a moment."))
        }
    }
}
