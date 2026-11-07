import Intents
import MusicKit
import TracksCore

/// Siri's "Play Phoebe Bridgers in Tracks", "Play Blue from my music", "Play my Workout
/// playlist on Tracks", "Play some jazz", "Play Motion Sickness next", "Play more like this",
/// and plain "Play music" once Siri has learned Tracks is where you listen.
///
/// Siri parses the request; ``MediaRequestResolver`` finds what it names in Tracks' own mixes,
/// then the music source that's on, then the other one, and plays it in Tracks so every song
/// is kept, switching source on the way when that's where it was found. Handled in the app,
/// which is launched in the background to do it.
nonisolated final class PlayMediaIntentHandler: NSObject, INPlayMediaIntentHandling {
    func resolveMediaItems(for intent: INPlayMediaIntent) async -> [INPlayMediaMediaItemResolutionResult] {
        let search = intent.mediaSearch
        // "Play more like this": nothing to look up.
        if search?.reference == .currentlyPlaying {
            let item = INMediaItem(identifier: Self.moreLikeThis, title: String(localized: "More Like This"), type: .music, artwork: nil)
            return INPlayMediaMediaItemResolutionResult.successes(with: [item])
        }
        // "Resume" and "Play" with nothing named, while something is paused: carry on.
        if intent.resumePlayback == true, search?.mediaName == nil, search?.artistName == nil, await Self.hasSomethingToResume() {
            let item = INMediaItem(identifier: Self.resume, title: String(localized: "Resume"), type: .music, artwork: nil)
            return INPlayMediaMediaItemResolutionResult.successes(with: [item])
        }
        let request = MediaRequest(
            name: search?.mediaName ?? "",
            artist: search?.artistName ?? "",
            kind: MediaKind(search?.mediaType ?? .unknown),
            moods: search?.moodNames ?? [],
            genres: search?.genreNames ?? []
        )
        guard let found = await MediaRequestResolver.item(for: request) else {
            return [.unsupported(forReason: .unsupportedMediaType)]
        }
        let item = INMediaItem(identifier: found.identifier, title: found.title, type: found.kind.mediaType, artwork: nil, artist: found.artist)
        return INPlayMediaMediaItemResolutionResult.successes(with: [item])
    }

    func handle(intent: INPlayMediaIntent) async -> INPlayMediaIntentResponse {
        guard let identifier = intent.mediaItems?.first?.identifier else {
            return INPlayMediaIntentResponse(code: .failure, userActivity: nil)
        }
        let problem: PlayerProblem?
        switch identifier {
        case Self.moreLikeThis:
            problem = await MediaRequestResolver.playMoreLikeThis()
        case Self.resume:
            await Self.resumePlaying()
            problem = nil
        default:
            let placement: MediaPlacement = switch intent.playbackQueueLocation {
            case .next: .next
            case .later: .later
            default: .now
            }
            problem = await MediaRequestResolver.play(identifier, shuffled: intent.playShuffled == true, placement: placement)
            if problem == nil {
                let search = intent.mediaSearch
                await MediaRequestResolver.remember([search?.mediaName, search?.artistName])
            }
        }
        return INPlayMediaIntentResponse(code: Self.code(for: problem), userActivity: nil)
    }

    private static let moreLikeThis = "special:more-like-this"
    private static let resume = "special:resume"

    @MainActor
    private static func hasSomethingToResume() -> Bool {
        let player = AppModel.shared.player
        return player.current != nil && player.status == .paused
    }

    @MainActor
    private static func resumePlaying() {
        let player = AppModel.shared.player
        if player.status != .playing { player.togglePlayPause() }
    }

    private static func code(for problem: PlayerProblem?) -> INPlayMediaIntentResponseCode {
        switch problem {
        case nil: .success
        // Something to sort out in Tracks itself.
        case .needsSubscription, .accessDenied: .failureRequiringAppLaunch
        case .onlyExplicit, .explicitSong, .blockedArtist: .failureRestrictedContent
        case .nothingToPlay, .notInYourMusic, .needsAppleMusic: .failureUnknownMediaType
        case .failed: .failure
        }
    }
}

/// Siri's "I like this song" and "I don't like this song": a favorite in Apple Music, and
/// either way the live mix hears about it, as the star and the skip tell it.
nonisolated final class UpdateMediaAffinityIntentHandler: NSObject, INUpdateMediaAffinityIntentHandling {
    func resolveMediaItems(for intent: INUpdateMediaAffinityIntent) async -> [INUpdateMediaAffinityMediaItemResolutionResult] {
        guard let current = await Self.current() else { return [.unsupported()] }
        let item = INMediaItem(identifier: current.id, title: current.title, type: .song, artwork: nil, artist: current.artist)
        return INUpdateMediaAffinityMediaItemResolutionResult.successes(with: [item])
    }

    func resolveAffinityType(for intent: INUpdateMediaAffinityIntent) async -> INMediaAffinityTypeResolutionResult {
        intent.affinityType == .unknown ? .needsValue() : .success(with: intent.affinityType)
    }

    func handle(intent: INUpdateMediaAffinityIntent) async -> INUpdateMediaAffinityIntentResponse {
        let liked = intent.affinityType == .like
        let done = await Self.update(liked: liked)
        return INUpdateMediaAffinityIntentResponse(code: done ? .success : .failure, userActivity: nil)
    }

    @MainActor
    private static func current() -> (id: String, title: String, artist: String)? {
        guard let track = AppModel.shared.player.current else { return nil }
        return (track.id, track.title, track.artistName)
    }

    @MainActor
    private static func update(liked: Bool) -> Bool {
        let player = AppModel.shared.player
        guard let track = player.current else { return false }
        if liked {
            if let song = track.song {
                player.setFavorite(song, true)
            } else if player.canAskForMoreLikeThis {
                player.playMoreLikeThis()
            }
        } else {
            if let song = track.song, player.isFavorite(song) { player.setFavorite(song, false) }
            player.skipToNext()
        }
        return true
    }
}

/// Siri's "Add this song to my library": the song on, into your Apple Music library.
nonisolated final class AddMediaIntentHandler: NSObject, INAddMediaIntentHandling {
    func resolveMediaItems(for intent: INAddMediaIntent) async -> [INAddMediaMediaItemResolutionResult] {
        guard let current = await Self.current() else {
            return [INAddMediaMediaItemResolutionResult(mediaItemResolutionResult: .unsupported())]
        }
        let item = INMediaItem(identifier: current.id, title: current.title, type: .song, artwork: nil, artist: current.artist)
        return INAddMediaMediaItemResolutionResult.successes(with: [item])
    }

    func handle(intent: INAddMediaIntent) async -> INAddMediaIntentResponse {
        let done = await Self.add()
        return INAddMediaIntentResponse(code: done ? .success : .failure, userActivity: nil)
    }

    @MainActor
    private static func current() -> (id: String, title: String, artist: String)? {
        guard let track = AppModel.shared.player.current, track.song != nil else { return nil }
        return (track.id, track.title, track.artistName)
    }

    @MainActor
    private static func add() -> Bool {
        let player = AppModel.shared.player
        guard let song = player.current?.song else { return false }
        player.addToLibrary(song)
        return true
    }
}

private extension MediaKind {
    nonisolated init(_ type: INMediaItemType) {
        self = switch type {
        case .song: .song
        case .album: .album
        case .artist: .artist
        case .playlist: .playlist
        case .radioStation, .station: .station
        case .genre: .genre
        default: .anything
        }
    }

    nonisolated var mediaType: INMediaItemType {
        switch self {
        case .song: .song
        case .album: .album
        case .artist: .artist
        case .playlist: .playlist
        case .station: .radioStation
        case .genre: .genre
        case .anything: .music
        }
    }
}
