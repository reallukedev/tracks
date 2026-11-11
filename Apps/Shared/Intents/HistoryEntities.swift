import AppIntents
import CoreSpotlight
import TracksCore

// The songs, artists and albums in your history, for Spotlight, Siri and Shortcuts. Each one
// opens its page in Tracks. They come from the history on this device; nothing is looked up.

// MARK: - Catalog

/// The history's search index, built once per revision of the history and kept for the next
/// query. Siri asks several queries in a row, and building it means tallying every play.
@MainActor
enum HistoryCatalog {
    private static var cached: (revision: Int, index: SearchIndex)?

    /// The history once it has loaded, or nil if it hasn't within ten seconds.
    static func history() async -> ListeningHistory? {
        let library = AppModel.shared.library
        // A cold launch from Spotlight or Siri starts the first read; give it time.
        for _ in 0..<100 where !library.isLoaded {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return library.isLoaded ? library.history : nil
    }

    /// Nil when the history isn't readable, or hasn't loaded within a few seconds.
    static func index() async -> SearchIndex? {
        let library = AppModel.shared.library
        guard await history() != nil else { return nil }
        if let cached, cached.revision == library.revision { return cached.index }
        let (history, revision) = (library.history, library.revision)
        let index = await OffMainActor.run { SearchIndex(history: history) }
        cached = (revision, index)
        // Let it go once Siri's run of queries is over: it's as big as the history.
        Task {
            try? await Task.sleep(for: .seconds(60))
            if cached?.revision == revision { cached = nil }
        }
        return index
    }

    /// Opens a page, over whatever the window shows.
    static func open(_ route: Route) async {
        AppModel.shared.pendingRoute = route
        await AppWindow.bringForward()
    }
}

// MARK: - Artists

struct ListenedArtistEntity: IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Artist",
        numericFormat: "\(placeholder: .int) artists"
    )
    static let defaultQuery = ListenedArtistQuery()

    /// A `Route.artist` identity.
    let id: String
    @Property(title: "Name")
    var name: String

    init(_ tally: ArtistTally) {
        id = tally.id
        name = tally.name
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "music.mic"))
    }
}

struct ListenedArtistQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [ListenedArtistEntity] {
        guard let index = await HistoryCatalog.index() else { return [] }
        return identifiers.compactMap { index.artist(id: $0) }.map(ListenedArtistEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [ListenedArtistEntity] {
        await HistoryCatalog.index()?.search(string, limit: 10).artists.map(ListenedArtistEntity.init) ?? []
    }

    @MainActor
    func suggestedEntities() async throws -> [ListenedArtistEntity] {
        await HistoryCatalog.index()?.topArtists(limit: 10).map(ListenedArtistEntity.init) ?? []
    }
}

struct OpenArtistIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Artist"
    static let description = IntentDescription("Opens an artist you've listened to in Tracks.", categoryName: "Your History")

    @Parameter(title: "Artist")
    var target: ListenedArtistEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        await HistoryCatalog.open(.artist(target.id))
        return .result()
    }
}

// MARK: - Songs

struct ListenedSongEntity: IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Song",
        numericFormat: "\(placeholder: .int) songs"
    )
    static let defaultQuery = ListenedSongQuery()

    /// A `Route.song` identity.
    let id: String
    @Property(title: "Title")
    var title: String
    @Property(title: "Artist")
    var artistName: String
    @Property(title: "Album")
    var albumTitle: String?

    init(_ tally: SongTally) {
        id = tally.id
        title = tally.title
        artistName = tally.artistName
        albumTitle = tally.albumTitle
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(artistName)", image: .init(systemName: "music.note"))
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.artist = artistName
        attributes.album = albumTitle
        return attributes
    }
}

struct ListenedSongQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [ListenedSongEntity] {
        guard let index = await HistoryCatalog.index() else { return [] }
        return identifiers.compactMap { index.song(id: $0) }.map(ListenedSongEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [ListenedSongEntity] {
        await HistoryCatalog.index()?.search(string, limit: 10).songs.map(ListenedSongEntity.init) ?? []
    }

    @MainActor
    func suggestedEntities() async throws -> [ListenedSongEntity] {
        await HistoryCatalog.index()?.topSongs(limit: 10).map(ListenedSongEntity.init) ?? []
    }
}

struct OpenSongIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Song"
    static let description = IntentDescription("Opens a song you've listened to in Tracks.", categoryName: "Your History")

    @Parameter(title: "Song")
    var target: ListenedSongEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        await HistoryCatalog.open(.song(target.id))
        return .result()
    }
}

// MARK: - Albums

struct ListenedAlbumEntity: IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Album",
        numericFormat: "\(placeholder: .int) albums"
    )
    static let defaultQuery = ListenedAlbumQuery()

    /// A `Route.album` identity.
    let id: String
    @Property(title: "Title")
    var title: String
    @Property(title: "Artist")
    var artistName: String

    init(_ tally: AlbumTally) {
        id = tally.id
        title = tally.title
        artistName = tally.artistName
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(artistName)", image: .init(systemName: "square.stack"))
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.artist = artistName
        return attributes
    }
}

struct ListenedAlbumQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [ListenedAlbumEntity] {
        guard let index = await HistoryCatalog.index() else { return [] }
        return identifiers.compactMap { index.album(id: $0) }.map(ListenedAlbumEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [ListenedAlbumEntity] {
        await HistoryCatalog.index()?.search(string, limit: 10).albums.map(ListenedAlbumEntity.init) ?? []
    }

    @MainActor
    func suggestedEntities() async throws -> [ListenedAlbumEntity] {
        await HistoryCatalog.index()?.topAlbums(limit: 10).map(ListenedAlbumEntity.init) ?? []
    }
}

struct OpenAlbumIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Album"
    static let description = IntentDescription("Opens an album you've listened to in Tracks.", categoryName: "Your History")

    @Parameter(title: "Album")
    var target: ListenedAlbumEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        await HistoryCatalog.open(.album(target.id))
        return .result()
    }
}
