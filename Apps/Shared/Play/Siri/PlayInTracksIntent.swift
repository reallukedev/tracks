import AppIntents
import MusicKit
import TracksCore

/// "Play music in Tracks", "Play my mix in Tracks", "Play Discover in Tracks".
///
/// An audio playback intent, so it can start the music without bringing Tracks forward, and
/// returns only once the music has started, or says why it couldn't.
struct PlayInTracksIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play in Tracks"
    static let description = IntentDescription(
        "Plays one of the Tracks mixes, Tracks Radio, Discover or live radio, and keeps every song you hear.",
        categoryName: "Playback"
    )

    @Parameter(title: "Music", default: .station)
    var choice: PlayChoice

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$choice) in Tracks")
    }

    init() {}

    init(choice: PlayChoice) {
        self.choice = choice
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = AppModel.shared
        guard !model.isDemoLaunch else { throw PlayIntentError.sampleData }
        // Siri runs this with no one looking at the phone, so a permission prompt would sit
        // there unanswered. Say what's needed instead.
        guard model.musicSource == .yourMusic || MusicAuthorization.currentStatus == .authorized else {
            throw PlayIntentError.appleMusicAccess
        }
        await model.prepareForPlaying()
        await TracksPlayback.start(choice, model: model)
        if let problem = model.player.problem {
            // Answered here, so it isn't shown again the next time the app opens.
            model.player.problem = nil
            throw PlayIntentError.problem(problem.message)
        }
        return .result()
    }
}

/// Starting a Play choice, for Siri, Shortcuts and CarPlay alike.
@MainActor
enum TracksPlayback {
    static func start(_ choice: PlayChoice, model: AppModel) async {
        let player = model.player
        let feed = model.playFeed

        func mix(_ kind: (MixKind) -> Bool) -> Mix? {
            feed.mixes.all.first { kind($0.kind) }
        }

        func playMix(_ mix: Mix?) async {
            guard let mix else {
                // No mix of that kind yet: the station always has something.
                if PlayPreferences.isTracksRadioOn {
                    await player.startTracksRadio()
                } else {
                    player.problem = .failed(String(localized: "Play a few more songs, and Tracks will have a mix for you."))
                }
                return
            }
            await player.start(.history(player.songs(in: mix)), from: PlayContext(kind: .mix, title: mix.kind.title))
        }

        if let mood = choice.mood {
            await MoodPlayback.start(mood, model: model)
            return
        }

        switch choice {
        case .station where !PlayPreferences.isTracksRadioOn:
            // With Tracks Radio off, "Play music in Tracks" still plays something of yours.
            await playMix(feed.mixes.rightNow ?? feed.mixes.mixes.first)
        case .station:
            await player.startTracksRadio()
        case .forYou:
            await playMix(feed.mixes.rightNow ?? feed.mixes.mixes.first)
        case .onRepeat:
            await playMix(mix { $0 == .onRepeat })
        case .favorites:
            await playMix(mix { $0 == .allTimeFavorites })
        case .deepCuts:
            await playMix(mix { $0 == .deepCuts })
        case .radioFinds:
            await playMix(mix { $0 == .radioFinds })
        case .discover:
            await feed.loadFromYourArtists()
            guard !feed.discover.isEmpty else {
                if PlayPreferences.isTracksRadioOn {
                    await player.startTracksRadio()
                } else {
                    player.problem = .failed(String(localized: "Tracks has nothing new to suggest yet. Play a few more songs, and it will."))
                }
                return
            }
            await player.start(.songs(feed.discover), from: PlayContext(kind: .mix, title: String(localized: "Discover")), shuffled: true)
        case .radio:
            await feed.loadAppleMusic()
            guard let (request, context) = feed.liveStations.first?.stationRequest else {
                player.problem = .failed(String(localized: "Couldn't reach Apple Music's radio."))
                return
            }
            await player.start(request, from: context)
        case .feelGood, .energy, .workout, .focus, .chill, .love, .drive, .party, .sleep, .heartbreak:
            // Handled above, as moods.
            break
        }
    }
}

enum PlayIntentError: Error, CustomLocalizedStringResourceConvertible {
    case sampleData
    case problem(String)

    /// Apple Music access can't be asked for from Siri, with no one looking at the screen:
    /// what to do instead, depending on whether it was ever asked.
    @MainActor static var appleMusicAccess: PlayIntentError {
        MusicAuthorization.currentStatus == .notDetermined
            ? .problem(String(localized: "Open Tracks and allow Apple Music access, then ask again."))
            : .problem(PlayerProblem.accessDenied.message)
    }

    /// The error for a problem playing, from Siri or Shortcuts.
    @MainActor static func playing(_ problem: PlayerProblem) -> PlayIntentError {
        problem == .accessDenied ? appleMusicAccess : .problem(problem.message)
    }

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .sampleData: "Tracks is showing sample data, so it can't play."
        case .problem(let message): "\(message)"
        }
    }
}

extension PlayBackTodayIntent {
    /// The app's one controller: one made for the intent would be freed as it returns, before
    /// it marks anything played back, and on the Mac would fight the app's for Music.
    @MainActor static func playbackController() throws -> PlaybackController {
        let model = AppModel.shared
        guard !model.isDemoLaunch else { throw PlayIntentError.sampleData }
        guard let controller = model.playback else {
            throw PlayIntentError.problem(model.startupError ?? String(localized: "Tracks couldn't open your history."))
        }
        return controller
    }
}
