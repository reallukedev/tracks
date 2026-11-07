import AppIntents
import MusicKit
import TracksCore

/// "Play a song in Tracks", and the Play Music action in Shortcuts and Spotlight on iPhone and
/// Mac: a song, album, artist, playlist or genre by name, from whichever source has it.
///
/// On iPhone, Siri's own "Play Bad Guy in Tracks" arrives as a media intent instead (see
/// `PlayMediaIntentHandler`); both end in ``MediaRequestResolver``, so they find the same
/// things and switch source the same way.
struct PlayMusicIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Music"
    static let description = IntentDescription(
        "Finds a song, album, artist, playlist or genre by name and plays it in Tracks, from the music source that's on or the other one, whichever has it.",
        categoryName: "Playback",
        searchKeywords: ["song", "album", "artist", "playlist", "genre", "queue", "play next"]
    )

    @Parameter(title: "Name", requestValueDialog: "What would you like to play?")
    var name: String

    @Parameter(title: "Kind", default: .anything)
    var kind: MediaKindOption

    @Parameter(title: "From", default: .automatic)
    var source: SourceOption

    @Parameter(title: "When", default: .now)
    var placement: PlacementOption

    @Parameter(title: "Shuffle", default: false)
    var shuffled: Bool

    static var parameterSummary: some ParameterSummary {
        When(\.$placement, .equalTo, .now) {
            Summary("Play \(\.$kind) \(\.$name) from \(\.$source)") {
                \.$placement
                \.$shuffled
            }
        } otherwise: {
            Summary("Play \(\.$kind) \(\.$name) from \(\.$source) \(\.$placement)") {
                \.$shuffled
            }
        }
    }

    init() {}

    init(name: String, kind: MediaKindOption = .anything, source: SourceOption = .automatic) {
        self.name = name
        self.kind = kind
        self.source = source
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        guard !model.isDemoLaunch else { throw PlayIntentError.sampleData }
        let request = MediaRequest(name: name, kind: kind.kind, source: source.source)
        guard let found = await MediaRequestResolver.item(for: request) else {
            throw PlayIntentError.problem(String(localized: "Couldn't find “\(name)” in Apple Music or your music."))
        }
        if let problem = await MediaRequestResolver.play(found.identifier, shuffled: shuffled, placement: placement.placement) {
            throw PlayIntentError.playing(problem)
        }
        MediaRequestResolver.remember([name])
        let title = [found.title, found.artist].compactMap(\.self).joined(separator: " · ")
        let dialog: IntentDialog = switch placement {
        case .now: "Playing \(title)."
        case .next: "\(title) will play next."
        case .later: "Added \(title) to the queue."
        }
        return .result(dialog: dialog)
    }
}

extension PlayMusicIntent {
    enum MediaKindOption: String, AppEnum {
        case anything, song, album, artist, playlist, station, genre

        static let typeDisplayRepresentation: TypeDisplayRepresentation = "Kind"
        static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
            .anything: "music",
            .song: "the song",
            .album: "the album",
            .artist: "the artist",
            .playlist: "the playlist",
            .station: "the station",
            .genre: "the genre",
        ]

        var kind: MediaKind { MediaKind(rawValue: rawValue) ?? .anything }
    }

    enum SourceOption: String, AppEnum {
        case automatic, appleMusic, yourMusic

        static let typeDisplayRepresentation: TypeDisplayRepresentation = "Source"
        static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
            .automatic: DisplayRepresentation(title: "Anywhere", subtitle: "The source that's on, then the other"),
            .appleMusic: "Apple Music",
            .yourMusic: "Your Music",
        ]

        var source: MusicSource? { MusicSource(rawValue: rawValue) }
    }

    enum PlacementOption: String, AppEnum {
        case now, next, later

        static let typeDisplayRepresentation: TypeDisplayRepresentation = "When"
        static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
            .now: "Now",
            .next: "Next",
            .later: "Last",
        ]

        var placement: MediaPlacement {
            switch self {
            case .now: .now
            case .next: .next
            case .later: .later
            }
        }
    }
}
