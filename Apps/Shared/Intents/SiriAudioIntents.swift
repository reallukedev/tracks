import AppIntents
import TracksCore

// Siri's own way to play music in an app, on iPhone and Mac alike: "Play Bad Guy in Tracks",
// "Play the album Blue in Tracks next", "Shuffle Phoebe Bridgers in Tracks", "Play my station
// in Tracks". Siri understands the request and asks Tracks for the song, album, artist,
// playlist or station by name through these entities' queries; ``MediaRequestResolver``
// answers from the source that's on, then the other one, as the iPhone's media intent does.

@AppEntity(schema: .audio.song)
struct SongAudioEntity {
    static let defaultQuery = SongAudioQuery()
    var id: String
    var title: String
    var artistName: String
    var artists: [ArtistAudioEntity]
    var album: AlbumAudioEntity?
    var albumTitle: String?
    var composerName: String?
    var composers: [ArtistAudioEntity]
    var internationalStandardRecordingCode: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(artistName)", image: .init(systemName: "music.note"))
    }

    init(_ found: ResolvedMedia) {
        id = found.identifier
        title = found.title
        artistName = found.artist ?? ""
        artists = []
        composers = []
    }
}

@AppEntity(schema: .audio.album)
struct AlbumAudioEntity {
    static let defaultQuery = AlbumAudioQuery()
    var id: String
    var title: String
    var artistName: String
    var artists: [ArtistAudioEntity]
    var universalProductCode: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(artistName)", image: .init(systemName: "square.stack"))
    }

    init(_ found: ResolvedMedia) {
        id = found.identifier
        title = found.title
        artistName = found.artist ?? ""
        artists = []
    }
}

@AppEntity(schema: .audio.artist)
struct ArtistAudioEntity {
    static let defaultQuery = ArtistAudioQuery()
    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "music.mic"))
    }

    init(_ found: ResolvedMedia) {
        id = found.identifier
        name = found.title
    }
}

@AppEntity(schema: .audio.playlist)
struct PlaylistAudioEntity {
    static let defaultQuery = PlaylistAudioQuery()
    var id: String
    var title: String
    var owner: PlaylistOwner?
    var createdByMe: Bool?
    var curatedForMe: Bool?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", image: .init(systemName: "music.note.list"))
    }

    init(_ found: ResolvedMedia) {
        id = found.identifier
        title = found.title
        owner = found.artist.map(PlaylistOwner.name)
        createdByMe = false
        curatedForMe = false
    }
}

/// Tracks' own mixes and stations, moods and genres: made for you, so Siri hears "my station"
/// and "something chill" as these.
@AppEntity(schema: .audio.algorithmicRadioStation)
struct StationAudioEntity {
    static let defaultQuery = StationAudioQuery()
    var id: String
    var title: String
    var curatedForMe: Bool?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", image: .init(systemName: "dot.radiowaves.left.and.right"))
    }

    init(_ found: ResolvedMedia) {
        id = found.identifier
        title = found.title
        // Apple Music's own stations are anyone's; Tracks' mixes are made from your listening.
        curatedForMe = !found.identifier.hasPrefix("station:")
    }
}

@UnionValue
enum PlaylistOwner {
    case person(IntentPerson)
    case name(String)
}

@UnionValue
enum AudioItem {
    case song(SongAudioEntity)
    case album(AlbumAudioEntity)
    case artist(ArtistAudioEntity)
    case playlist(PlaylistAudioEntity)
    case station(StationAudioEntity)

    var identifier: String {
        switch self {
        case .song(let entity): entity.id
        case .album(let entity): entity.id
        case .artist(let entity): entity.id
        case .playlist(let entity): entity.id
        case .station(let entity): entity.id
        }
    }
}

@AppEnum(schema: .audio.queueInsertionLocation)
enum AudioQueueLocation: String, AppEnum {
    case now, next, tail

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .now: "Now",
        .next: "Next",
        .tail: "Last",
    ]
}

@AppEnum(schema: .audio.playbackAttributes)
enum AudioPlaybackAttribute: String, AppEnum {
    case shuffle, `repeat`

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .shuffle: "Shuffle",
        .repeat: "Repeat",
    ]
}

/// Siri may ask an app to get a queue ready before it's played. Tracks starts fast enough
/// without, so this only carries Siri's reference along.
@AppEntity(schema: .audio.warmupAudioQueueResult)
struct WarmupAudioQueueResult: TransientAppEntity {
    var id = UUID().uuidString

    var displayRepresentation: DisplayRepresentation { "Queue" }

    init() {}
}

@AppIntent(schema: .audio.playAudio)
struct PlayAudioIntent: AudioPlaybackIntent {
    var audioEntity: AudioItem
    var queueLocation: AudioQueueLocation?
    var playbackAttributes: Set<AudioPlaybackAttribute>
    var warmupAudioQueueResult: WarmupAudioQueueResult?

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = AppModel.shared
        guard !model.isDemoLaunch else { throw PlayIntentError.sampleData }
        let placement: MediaPlacement = switch queueLocation {
        case .next: .next
        case .tail: .later
        case .now, nil: .now
        }
        let identifier = audioEntity.identifier
        if let problem = await MediaRequestResolver.play(identifier, shuffled: playbackAttributes.contains(.shuffle), placement: placement) {
            throw PlayIntentError.playing(problem)
        }
        if playbackAttributes.contains(.repeat), placement == .now {
            model.player.setRepeat(.all)
        }
        return .result()
    }
}

// MARK: - Queries

/// Finds what Siri names, one kind at a time, and rebuilds what it was given before.
@MainActor
private enum AudioLookup {
    static func find(_ name: String, kind: MediaKind) async -> [ResolvedMedia] {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !AppModel.shared.isDemoLaunch else { return [] }
        guard let found = await MediaRequestResolver.item(for: MediaRequest(name: name, kind: kind)) else { return [] }
        return [found]
    }

    static func describe(_ identifiers: [String]) async -> [ResolvedMedia] {
        var found: [ResolvedMedia] = []
        for identifier in identifiers {
            if let item = await MediaRequestResolver.describe(identifier) { found.append(item) }
        }
        return found
    }
}

struct SongAudioQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SongAudioEntity] {
        await AudioLookup.describe(identifiers).map(SongAudioEntity.init)
    }

    func entities(matching string: String) async throws -> [SongAudioEntity] {
        await AudioLookup.find(string, kind: .song).filter { $0.kind == .song }.map(SongAudioEntity.init)
    }
}

struct AlbumAudioQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AlbumAudioEntity] {
        await AudioLookup.describe(identifiers).map(AlbumAudioEntity.init)
    }

    func entities(matching string: String) async throws -> [AlbumAudioEntity] {
        await AudioLookup.find(string, kind: .album).filter { $0.kind == .album }.map(AlbumAudioEntity.init)
    }
}

struct ArtistAudioQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ArtistAudioEntity] {
        await AudioLookup.describe(identifiers).map(ArtistAudioEntity.init)
    }

    func entities(matching string: String) async throws -> [ArtistAudioEntity] {
        await AudioLookup.find(string, kind: .artist).filter { $0.kind == .artist }.map(ArtistAudioEntity.init)
    }
}

struct PlaylistAudioQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [PlaylistAudioEntity] {
        await AudioLookup.describe(identifiers).map(PlaylistAudioEntity.init)
    }

    func entities(matching string: String) async throws -> [PlaylistAudioEntity] {
        await AudioLookup.find(string, kind: .playlist).filter { $0.kind == .playlist }.map(PlaylistAudioEntity.init)
    }
}

struct StationAudioQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [StationAudioEntity] {
        await AudioLookup.describe(identifiers).map(StationAudioEntity.init)
    }

    /// Tracks' mixes, moods and genres by name first, then Apple Music's stations.
    func entities(matching string: String) async throws -> [StationAudioEntity] {
        let mixes = await AudioLookup.find(string, kind: .anything).filter { $0.identifier.hasPrefix("tracks") || $0.identifier.hasPrefix("genre") }
        if !mixes.isEmpty { return mixes.map(StationAudioEntity.init) }
        return await AudioLookup.find(string, kind: .station).filter { $0.kind == .station }.map(StationAudioEntity.init)
    }

    /// Tracks' own, for Shortcuts' picker and Siri's suggestions.
    func suggestedEntities() async throws -> [StationAudioEntity] {
        PlayChoice.allCases.compactMap { choice in
            guard let title = PlayChoice.caseDisplayRepresentations[choice]?.title else { return nil }
            return StationAudioEntity(ResolvedMedia(identifier: "tracks:\(choice.rawValue)", title: String(localized: title), kind: .station))
        }
    }
}
