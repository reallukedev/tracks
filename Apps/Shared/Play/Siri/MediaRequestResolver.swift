import Foundation
import MusicKit
import TracksCore

/// What someone asked to play, as plain values: from Siri's media intent on iPhone, or the
/// Play Music intent on both.
nonisolated struct MediaRequest: Sendable {
    var name: String
    var artist: String = ""
    var kind: MediaKind = .anything
    /// Moods Siri heard: "something chill", "workout music".
    var moods: [String] = []
    /// Genres Siri heard: "play some jazz".
    var genres: [String] = []
    /// A source asked for in so many words, beyond any in the name.
    var source: MusicSource?
}

/// The kinds of thing that can be asked for by name.
nonisolated enum MediaKind: String, Sendable {
    case anything, song, album, artist, playlist, station, genre
}

/// Where what's found goes: played now, or added after the song on or at the end.
nonisolated enum MediaPlacement: Sendable {
    case now, next, later
}

/// What a request resolved to. The identifier carries it from resolving to playing, which
/// Siri does in two steps: "kind:value", with "@source" after the kind for Tracks' own mixes
/// and genres asked for from a particular source.
nonisolated struct ResolvedMedia: Sendable, Equatable {
    let identifier: String
    let title: String
    let kind: MediaKind
    var artist: String?
}

/// Turns what was asked for into something Tracks can play, looking in the music source
/// that's on and then the other one, and plays it, switching source on the way when the
/// match came from the other one. What was playing carries on until the new music starts.
@MainActor
enum MediaRequestResolver {
    static func item(for request: MediaRequest) async -> ResolvedMedia? {
        let model = AppModel.shared
        let (spokenName, spokenSource) = SpokenMedia.source(in: request.name)
        let name = spokenName
        let artist = SpokenMedia.source(in: request.artist).name
        let asked = request.source ?? spokenSource.flatMap { MusicSource(rawValue: $0.rawValue) }
        let suffix = asked.map { "@\($0.rawValue)" } ?? ""

        if name.isEmpty, artist.isEmpty {
            if let genre = request.genres.lazy.compactMap(SpokenMedia.genre(named:)).first {
                return ResolvedMedia(identifier: "genre\(suffix):\(genre.id)", title: genre.title, kind: .genre)
            }
            // "Play something chill": one of Tracks' moods.
            if let mood = request.moods.lazy.compactMap(SpokenMedia.mood(in:)).compactMap(PlayChoice.init(rawValue:)).first {
                return tracksItem(mood, suffix: suffix)
            }
            // "Play music", or "Play Apple Music": Tracks Radio, which always has something,
            // or this hour's mix with it off.
            return tracksItem(PlayPreferences.isTracksRadioOn ? .station : .forYou, suffix: suffix)
        }
        if artist.isEmpty, let choice = SpokenMedia.choice(named: name).flatMap(PlayChoice.init(rawValue:)) {
            return tracksItem(choice, suffix: suffix)
        }
        if artist.isEmpty, request.kind == .genre || request.kind == .anything, let genre = SpokenMedia.genre(named: name) {
            return ResolvedMedia(identifier: "genre\(suffix):\(genre.id)", title: genre.title, kind: .genre)
        }

        let current = SpokenMedia.Source(rawValue: model.musicSource.rawValue) ?? .appleMusic
        let order = SpokenMedia.order(
            current: current,
            asked: asked.flatMap { SpokenMedia.Source(rawValue: $0.rawValue) },
            otherAvailable: canSwitch(model)
        )
        for source in order {
            let found: ResolvedMedia? = switch source {
            case .yourMusic: localItem(name: name, artist: artist, kind: request.kind)
            case .appleMusic: await catalogItem(name: name, artist: artist, kind: request.kind)
            }
            if let found { return found }
        }
        return nil
    }

    /// Whether the other source is there to look in: Apple Music allowed, and music of your
    /// own. Not only with Quick Switch on: asking for something by name is reason enough.
    static func canSwitch(_ model: AppModel) -> Bool {
        let appleMusic = MusicAuthorization.currentStatus == .authorized
        return appleMusic && model.yourMusic.hasMusic
    }

    // MARK: - Playing

    /// Plays what an identifier names. Returns what went wrong, if anything.
    static func play(_ identifier: String, shuffled: Bool = false, placement: MediaPlacement = .now) async -> PlayerProblem? {
        let model = AppModel.shared
        guard !model.isDemoLaunch else { return .nothingToPlay }
        let parts = identifier.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return .nothingToPlay }
        let kindParts = parts[0].split(separator: "@", maxSplits: 1).map(String.init)
        let kind = kindParts[0]
        let value = parts[1]

        // Where it plays from: a match says so itself; a mix or genre asked for from a
        // source, that one; otherwise whichever is on.
        let source: MusicSource = switch kind {
        case "local-track", "local-album", "local-artist": .yourMusic
        case "song", "album", "artist", "playlist", "station": .appleMusic
        default: kindParts.count == 2 ? MusicSource(rawValue: kindParts[1]) ?? model.musicSource : model.musicSource
        }
        // No prompt from the background, where no one would see it. Your own music needs none.
        guard source == .yourMusic || MusicAuthorization.currentStatus == .authorized else { return .accessDenied }
        // Your own music's match has to still be there before anything changes.
        if kind.hasPrefix("local-") {
            let index = model.yourMusic.index
            let exists = switch kind {
            case "local-track": index.track(id: value) != nil
            case "local-album": index.album(id: value) != nil
            default: index.artist(id: value) != nil
            }
            guard exists else { return .nothingToPlay }
        }
        if source != model.musicSource {
            // Live, as Quick Switch does: what's playing carries on until this starts.
            model.switchSource(to: source)
        }
        await model.prepareForPlaying()
        let player = model.player
        let id = MusicItemID(value)
        defer { player.problem = nil }

        func start(_ request: PlayRequest, _ context: PlayContext, shuffled: Bool = false) async {
            switch placement {
            case .now: await player.start(request, from: context, shuffled: shuffled)
            case .next, .later: player.enqueue(request, next: placement == .next, title: context.title)
            }
        }

        switch kind {
        case "local-track":
            let index = model.yourMusic.index
            guard let track = index.track(id: value) else { return .nothingToPlay }
            if placement != .now {
                await start(.local([track]), .songs(track.title))
                break
            }
            // The song, then the rest of its artist's, so the music doesn't stop after one.
            let more = index.artist(id: track.artistKey)?.tracks.filter { $0.id != track.id }.shuffled() ?? []
            await start(.local([track] + more), .songs(track.title))
        case "local-album":
            guard let album = model.yourMusic.index.album(id: value) else { return .nothingToPlay }
            await start(.local(album.tracks), PlayContext(kind: .album, title: album.title), shuffled: shuffled)
        case "local-artist":
            guard let artist = model.yourMusic.index.artist(id: value) else { return .nothingToPlay }
            await start(.local(artist.tracks), PlayContext(kind: .artist, title: artist.name), shuffled: true)
        case "tracks":
            guard let choice = PlayChoice(rawValue: value) else { return .nothingToPlay }
            await TracksPlayback.start(choice, model: model)
        case "genre":
            guard let genre = MusicGenre.all.first(where: { $0.id == value }) else { return .nothingToPlay }
            await GenrePlayback.start(genre, model: model)
        case "song":
            guard let song = await song(id) else { return .nothingToPlay }
            if placement != .now {
                await start(.songs([song]), .songs(song.title))
                break
            }
            // The song, then more by the same artist, so the music doesn't stop after one.
            await start(.songs(await songAndMore(song)), .songs(song.title))
        case "album":
            guard let album = await album(id) else { return .nothingToPlay }
            await start(.album(album), PlayContext(kind: .album, title: album.title), shuffled: shuffled)
        case "playlist":
            guard let playlist = await libraryOrCatalogPlaylist(id) else { return .nothingToPlay }
            await start(.playlist(playlist), PlayContext(kind: .playlist, title: playlist.name), shuffled: shuffled)
        case "artist":
            guard let artist = await artist(id),
                  let top = try? await artist.with([.topSongs]).topSongs, !top.isEmpty
            else { return .nothingToPlay }
            let songs = PlayPreferences.versions(of: Array(top))
            await start(.songs(songs), PlayContext(kind: .artist, title: artist.name), shuffled: shuffled)
        case "station":
            guard let station = await station(id) else { return .nothingToPlay }
            await start(.station(station), PlayContext(kind: .station, title: station.name))
        default:
            return .nothingToPlay
        }
        // Answered to whoever asked, so it isn't shown again the next time the app opens: the
        // defer above clears it once this has been read.
        return player.problem
    }

    /// "Play more like this": steers a live mix toward the song on, or starts Tracks Radio
    /// when nothing live is playing.
    static func playMoreLikeThis() async -> PlayerProblem? {
        let model = AppModel.shared
        guard !model.isDemoLaunch else { return .nothingToPlay }
        let player = model.player
        if player.canAskForMoreLikeThis {
            player.playMoreLikeThis()
            return nil
        }
        await model.prepareForPlaying()
        defer { player.problem = nil }
        await player.startTracksRadio()
        return player.problem
    }

    /// What an identifier names, for Siri asking again about something it was given earlier.
    static func describe(_ identifier: String) async -> ResolvedMedia? {
        let parts = identifier.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let kind = parts[0].split(separator: "@", maxSplits: 1).first.map(String.init) ?? parts[0]
        let value = parts[1]
        let index = AppModel.shared.yourMusic.index
        let id = MusicItemID(value)
        switch kind {
        case "local-track":
            return index.track(id: value).map { ResolvedMedia(identifier: identifier, title: $0.title, kind: .song, artist: $0.artist) }
        case "local-album":
            return index.album(id: value).map { ResolvedMedia(identifier: identifier, title: $0.title, kind: .album, artist: $0.artist) }
        case "local-artist":
            return index.artist(id: value).map { ResolvedMedia(identifier: identifier, title: $0.name, kind: .artist) }
        case "tracks":
            return PlayChoice(rawValue: value).map { tracksItem($0, suffix: "") }.map {
                ResolvedMedia(identifier: identifier, title: $0.title, kind: .station)
            }
        case "genre":
            return MusicGenre.all.first { $0.id == value }.map { ResolvedMedia(identifier: identifier, title: $0.title, kind: .genre) }
        case "song":
            return await song(id).map { ResolvedMedia(identifier: identifier, title: $0.title, kind: .song, artist: $0.artistName) }
        case "album":
            return await album(id).map { ResolvedMedia(identifier: identifier, title: $0.title, kind: .album, artist: $0.artistName) }
        case "artist":
            return await artist(id).map { ResolvedMedia(identifier: identifier, title: $0.name, kind: .artist) }
        case "playlist":
            return await libraryOrCatalogPlaylist(id).map { ResolvedMedia(identifier: identifier, title: $0.name, kind: .playlist, artist: $0.curatorName) }
        case "station":
            return await station(id).map { ResolvedMedia(identifier: identifier, title: $0.name, kind: .station) }
        default:
            return nil
        }
    }

    // MARK: - Finding things

    /// Your own music's best match: an artist, album or song, as it was asked for.
    private static func localItem(name: String, artist: String, kind: MediaKind) -> ResolvedMedia? {
        let index = AppModel.shared.yourMusic.index
        guard !index.isEmpty else { return nil }
        let query = [name, artist].filter { !$0.isEmpty }.joined(separator: " ")
        let found = index.search(query, limit: 5)
        func artistItem(_ match: LocalArtist) -> ResolvedMedia {
            ResolvedMedia(identifier: "local-artist:\(match.id)", title: match.name, kind: .artist)
        }
        func albumItem(_ match: LocalAlbum) -> ResolvedMedia {
            ResolvedMedia(identifier: "local-album:\(match.id)", title: match.title, kind: .album, artist: match.artist)
        }
        switch kind {
        case .artist:
            return index.search(artist.isEmpty ? name : artist, limit: 1).artists.first.map(artistItem)
        case .album:
            return found.albums.first.map(albumItem)
        case .playlist, .station, .genre:
            return nil
        case .song, .anything:
            if let track = found.tracks.first {
                return ResolvedMedia(identifier: "local-track:\(track.id)", title: track.title, kind: .song, artist: track.artist)
            }
            guard kind == .anything else { return nil }
            if let album = found.albums.first { return albumItem(album) }
            return found.artists.first.map(artistItem)
        }
    }

    /// Apple Music's best match: the library first for playlists, then the catalog.
    private static func catalogItem(name: String, artist: String, kind: MediaKind) async -> ResolvedMedia? {
        guard MusicAuthorization.currentStatus == .authorized else { return nil }
        let both = [name, artist].filter { !$0.isEmpty }.joined(separator: " ")
        switch kind {
        case .playlist:
            let inLibrary = await libraryPlaylist(named: name)
            let playlist: Playlist? = if let inLibrary { inLibrary } else { await catalog(Playlist.self, name).first }
            return playlist.map { ResolvedMedia(identifier: "playlist:\($0.id.rawValue)", title: $0.name, kind: .playlist) }
        case .album:
            let album = PlayPreferences.versions(of: await catalog(Album.self, both)).first
            return album.map { ResolvedMedia(identifier: "album:\($0.id.rawValue)", title: $0.title, kind: .album, artist: $0.artistName) }
        case .artist:
            return await artistItem(artist.isEmpty ? name : artist)
        case .station:
            let station = await catalog(MusicKit.Station.self, both).first
            return station.map { ResolvedMedia(identifier: "station:\($0.id.rawValue)", title: $0.name, kind: .station) }
        case .genre:
            return nil
        case .song, .anything:
            // Only an artist named: their songs, not a song with their name in it.
            if name.isEmpty { return await artistItem(artist) }
            // A name alone could be an artist's: both asked for at once rather than in turn.
            async let found = catalog(Song.self, both)
            async let named = kind == .anything && artist.isEmpty ? exactArtist(name) : nil
            let songs = PlayPreferences.versions(of: await found)
            // A name that is an artist's, said with nothing else, is the artist, unless a song
            // is called exactly that too.
            if let named = await named,
               songs.first.map({ StatsCalculator.folded($0.title) != StatsCalculator.folded(name) }) ?? true {
                return named
            }
            if let song = songs.first {
                return ResolvedMedia(identifier: "song:\(song.id.rawValue)", title: song.title, kind: .song, artist: song.artistName)
            }
            return kind == .anything ? await artistItem(both) : nil
        }
    }

    private static func artistItem(_ name: String) async -> ResolvedMedia? {
        let found = await catalog(Artist.self, name).first
        return found.map { ResolvedMedia(identifier: "artist:\($0.id.rawValue)", title: $0.name, kind: .artist) }
    }

    /// An artist whose name is exactly what was said, so "Play Adele" plays Adele rather than
    /// the first song that mentions her.
    private static func exactArtist(_ name: String) async -> ResolvedMedia? {
        let wanted = StatsCalculator.folded(name)
        let found = await catalog(Artist.self, name).first { StatsCalculator.folded($0.name) == wanted }
        return found.map { ResolvedMedia(identifier: "artist:\($0.id.rawValue)", title: $0.name, kind: .artist) }
    }

    private static func tracksItem(_ choice: PlayChoice, suffix: String) -> ResolvedMedia {
        let title = String(localized: PlayChoice.caseDisplayRepresentations[choice]?.title ?? "Tracks Radio")
        return ResolvedMedia(identifier: "tracks\(suffix):\(choice.rawValue)", title: title, kind: .anything)
    }

    private static func catalog<Item: MusicCatalogSearchable>(_ type: Item.Type, _ term: String) async -> [Item] {
        let term = term.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return [] }
        var request = MusicCatalogSearchRequest(term: term, types: [type])
        request.limit = 5
        guard let response = try? await request.response() else { return [] }
        return switch type {
        case is Song.Type: Array(response.songs) as? [Item] ?? []
        case is Album.Type: Array(response.albums) as? [Item] ?? []
        case is Artist.Type: Array(response.artists) as? [Item] ?? []
        case is Playlist.Type: Array(response.playlists) as? [Item] ?? []
        case is MusicKit.Station.Type: Array(response.stations) as? [Item] ?? []
        default: []
        }
    }

    private static func libraryPlaylist(named name: String) async -> Playlist? {
        var request = MusicLibraryRequest<Playlist>()
        request.filter(text: name)
        request.limit = 5
        let playlists = (try? await request.response().items) ?? []
        let wanted = StatsCalculator.folded(name)
        return playlists.first { StatsCalculator.folded($0.name) == wanted } ?? playlists.first
    }

    private static func song(_ id: MusicItemID) async -> Song? {
        try? await MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: id).response().items.first
    }

    private static func album(_ id: MusicItemID) async -> Album? {
        try? await MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: id).response().items.first
    }

    private static func artist(_ id: MusicItemID) async -> Artist? {
        try? await MusicCatalogResourceRequest<Artist>(matching: \.id, equalTo: id).response().items.first
    }

    private static func station(_ id: MusicItemID) async -> MusicKit.Station? {
        try? await MusicCatalogResourceRequest<MusicKit.Station>(matching: \.id, equalTo: id).response().items.first
    }

    private static func libraryOrCatalogPlaylist(_ id: MusicItemID) async -> Playlist? {
        var library = MusicLibraryRequest<Playlist>()
        library.filter(matching: \.id, equalTo: id)
        if let found = try? await library.response().items.first { return found }
        return try? await MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: id).response().items.first
    }

    /// The song asked for, then the artist's other top songs in a fresh order.
    private static func songAndMore(_ song: Song) async -> [Song] {
        guard let artist = try? await song.with([.artists]).artists?.first,
              let top = try? await artist.with([.topSongs]).topSongs
        else { return [song] }
        let others = PlayPreferences.versions(of: Array(top)).filter {
            ExplicitVersions.versionKey(title: $0.title, artist: $0.artistName)
                != ExplicitVersions.versionKey(title: song.title, artist: song.artistName)
        }
        return [song] + others.shuffled()
    }

    // MARK: - Remembering

    /// Keeps what was asked for with recent searches, so Search in the car and on the phone
    /// shows it, as Music does with what you ask Siri for.
    static func remember(_ asked: [String?]) {
        let term = asked
            .compactMap { $0.map { SpokenMedia.source(in: $0).name } }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // "Play music" and "something chill" aren't searches.
        guard !term.isEmpty, SpokenMedia.choice(named: term) == nil, SpokenMedia.genre(named: term) == nil else { return }
        let key = MusicSource.current == .yourMusic ? "recentYourMusicSearches" : "recentMusicSearches"
        let defaults = UserDefaults.standard
        defaults.set(RecentSearches.adding(term, to: defaults.string(forKey: key) ?? ""), forKey: key)
    }
}
