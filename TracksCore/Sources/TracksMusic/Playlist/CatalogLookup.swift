import Foundation
import MusicKit
import TracksCore

/// One station, with the fields that tell whether it's one of Apple's.
public struct StationDescription: Sendable, Equatable {
    public let id: String
    public let name: String
    public let providerName: String?
    public let isLive: Bool

    public init(id: String, name: String, providerName: String?, isLive: Bool) {
        self.id = id
        self.name = name
        self.providerName = providerName
        self.isLive = isLive
    }
}

/// Resolves track metadata to an Apple Music catalog ID.
///
/// The only identity path on macOS, where `playerInfo` has no catalog id. The strictness
/// lives in ``CatalogMatcher``: writing the wrong song into someone's library is worse than
/// missing a capture.
public struct CatalogLookup: CatalogResolving {
    public init() {}

    public func artworkURLs(forSongIDs ids: [String]) async throws -> [String: String] {
        // Rows imported from Recently Played have library ids ("i.aJGY3G9fEGApOQP"). Sent to
        // the catalog, they fail the whole request with 400 / 40003 "No id(s) supplied on
        // the request", so split them out.
        let catalogIDs = ids.filter(MusicItemIdentity.isCatalogID)
        let libraryIDs = ids.filter(MusicItemIdentity.isLibraryID)

        var result: [String: String] = [:]
        if !catalogIDs.isEmpty {
            let request = MusicCatalogResourceRequest<Song>(
                matching: \.id,
                memberOf: catalogIDs.map { MusicItemID($0) }
            )
            result.merge(artwork(from: try await request.response().items)) { first, _ in first }
        }
        // Library items need a library request, or imported songs keep a placeholder forever.
        if !libraryIDs.isEmpty {
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.id, memberOf: libraryIDs.map { MusicItemID($0) })
            let songs = try await request.response().items
            result.merge(artwork(from: songs)) { first, _ in first }

            // A library song's cover is usually a `musicKit://` address, which never loads, so
            // the library request alone left songs from the user's library without a cover on
            // the iPhone. Find the same song in the catalog the way a Mac capture is found.
            for song in songs where result[song.id.rawValue] == nil {
                let match = try await resolve(CatalogQuery(
                    title: song.title,
                    artistName: song.artistName,
                    duration: song.duration,
                    albumTitle: song.albumTitle
                ))
                if let url = ArtworkURL.loadable(match?.artworkURL) {
                    result[song.id.rawValue] = url
                }
            }
        }
        return result
    }

    /// The credited artist's picture for each request, by artist identity. Artists with no
    /// picture, or whose song the catalog can't confidently identify, are left out.
    public func artistArtworkURLs(
        for requests: [ArtistArtworkLookup.Request]
    ) async throws -> [String: String] {
        // A song without a catalog id is found the way a macOS capture is: by title and
        // artist, through the same strict matcher, so a guess never picks the artist.
        var songIDs: [String: String] = [:]
        for request in requests {
            if request.hasCatalogID {
                songIDs[request.artistIdentity] = request.songID
            } else if let match = try await resolve(CatalogQuery(
                title: request.title,
                artistName: request.artistName,
                duration: nil,
                albumTitle: request.albumTitle
            )) {
                songIDs[request.artistIdentity] = match.id
            }
        }
        guard !songIDs.isEmpty else { return [:] }

        var request = MusicCatalogResourceRequest<Song>(
            matching: \.id,
            memberOf: Set(songIDs.values).map { MusicItemID($0) }
        )
        request.properties = [.artists]
        let songs = Dictionary(
            try await request.response().items.map { ($0.id.rawValue, $0) }
        ) { first, _ in first }

        var result: [String: String] = [:]
        for credit in requests {
            guard let song = songIDs[credit.artistIdentity].flatMap({ songs[$0] }),
                  let artists = song.artists.map(Array.init),
                  let index = ArtistArtworkLookup.creditedArtist(
                      named: credit.artistName,
                      among: artists.map(\.name),
                      fallsBackToFirst: credit.isLead
                  ),
                  // Big enough for the artist page, which shows it at 150 points.
                  let url = ArtworkURL.loadable(
                      artists[index].artwork?.url(width: 600, height: 600)?.absoluteString
                  )
            else { continue }
            result[credit.artistIdentity] = url
        }
        return result
    }

    /// Genre and release year for each request, by song identity. Songs the catalog doesn't
    /// have, can't confidently identify, or knows nothing about are left out.
    public func songMetadata(for requests: [SongMetadataLookup.Request]) async throws -> [String: SongMetadata] {
        // Several identities can land on one id, e.g. a song and its "(Remastered)" spelling.
        var catalogIDs: [String: [String]] = [:]
        var libraryIDs: [String: [String]] = [:]
        for request in requests {
            if request.hasCatalogID {
                catalogIDs[request.songID, default: []].append(request.songIdentity)
            } else if request.hasLibraryID {
                libraryIDs[request.songID, default: []].append(request.songIdentity)
            } else if let match = try await resolve(CatalogQuery(
                // Found the way a macOS capture is: through the strict matcher, so a guess
                // never gives a song someone else's genre.
                title: request.title,
                artistName: request.artistName,
                duration: nil,
                albumTitle: request.albumTitle
            )) {
                catalogIDs[match.id, default: []].append(request.songIdentity)
            }
        }

        var result: [String: SongMetadata] = [:]
        func record(_ songs: some Sequence<Song>, from ids: [String: [String]]) {
            for song in songs {
                let metadata = SongMetadata(
                    genre: SongMetadata.primaryGenre(from: song.genreNames, topLevel: Self.topLevelGenres(of: song)),
                    releaseYear: SongMetadata.releaseYear(from: song.releaseDate),
                    // Library songs carry no artists, so they're asked about once, as empty.
                    artists: song.artists.map { $0.map(\.name) } ?? []
                )
                guard !metadata.isEmpty || metadata.artists?.isEmpty == false else { continue }
                for identity in ids[song.id.rawValue] ?? [] { result[identity] = metadata }
            }
        }

        // A hundred ids a request keeps each response small; the catalog takes a few hundred.
        let catalog = Array(catalogIDs.keys)
        for start in stride(from: 0, to: catalog.count, by: 100) {
            let chunk = catalog[start..<min(start + 100, catalog.count)]
            var request = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: chunk.map { MusicItemID($0) })
            // Only the top-level genres come back as relationships, each with its parent,
            // which is how a subgenre like "Rap" is rolled up to "Hip-Hop/Rap".
            // Artists too: their names settle who a collaboration credits.
            request.properties = [.genres, .artists]
            record(try await request.response().items, from: catalogIDs)
        }
        // Library ids fail a catalog request outright (see `artworkURLs(forSongIDs:)`).
        if !libraryIDs.isEmpty {
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.id, memberOf: libraryIDs.keys.map { MusicItemID($0) })
            record(try await request.response().items, from: libraryIDs)
        }
        return result
    }

    /// The song's genres whose parent is the root ("Music"). On a real account the catalog
    /// gave `[Music, Hip-Hop/Rap]` for a song listed as "Rap, Music, Hip-Hop/Rap", the root
    /// being the one with no parent. Empty for library songs, which carry names only.
    private static func topLevelGenres(of song: Song) -> Set<String> {
        guard let genres = song.genres.map(Array.init), !genres.isEmpty else { return [] }
        let root = genres.first { $0.parent == nil }?.id
        return Set(genres.filter { genre in
            guard let parent = genre.parent else { return false }
            return root == nil || parent.id == root
        }.map(\.name))
    }

    private func artwork(from songs: some Sequence<Song>) -> [String: String] {
        songs.reduce(into: [:]) { result, song in
            // Only loadable URLs; see ``ArtworkURL``.
            guard let url = ArtworkURL.loadable(
                song.artwork?.url(width: 300, height: 300)?.absoluteString
            ) else { return }
            result[song.id.rawValue] = url
        }
    }

    public func mostRecentStationName() async throws -> String? {
        // The only way to learn what station was on without having seen the tune-in.
        var request = MusicRecentlyPlayedRequest<MusicKit.Station>()
        request.limit = 1
        return try await request.response().items.first?.name
    }

    /// Every station Apple Music remembers, with what the probe needs to tell them apart.
    ///
    /// On a real account, Apple Music Chill, Apple Music 1, Hits, Country, Club and Música
    /// Uno report `stationProviderName` "Apple Music" and `isLive`. Personal stations
    /// ("Kendrick Lamar", "Focus", "Pop Station") have no provider.
    public func recentStations(limit: Int = 25) async throws -> [StationDescription] {
        var request = MusicRecentlyPlayedRequest<MusicKit.Station>()
        request.limit = limit
        return try await request.response().items.map {
            StationDescription(
                id: $0.id.rawValue,
                name: $0.name,
                providerName: $0.stationProviderName,
                isLive: $0.isLive
            )
        }
    }

    /// Raw search results before matching. The probe uses this to inspect the catalog.
    public func candidates(for term: String, limit: Int = 10) async throws -> [CatalogCandidate] {
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
        request.limit = limit
        let response = try await request.response()
        return response.songs.map { song in
            CatalogCandidate(
                id: song.id.rawValue,
                title: song.title,
                artistName: song.artistName,
                albumTitle: song.albumTitle,
                duration: song.duration,
                // Rows and widgets render small, so don't fetch the full-size image.
                artworkURL: song.artwork?.url(width: 300, height: 300)?.absoluteString
            )
        }
    }

    /// Returns the best confident match, or nil. A separate overload because a default
    /// argument doesn't satisfy the protocol requirement.
    public func resolve(_ query: CatalogQuery) async throws -> CatalogCandidate? {
        try await resolve(query, limit: 10)
    }

    public func resolve(_ query: CatalogQuery, limit: Int) async throws -> CatalogCandidate? {
        let found = try await candidates(for: query.searchTerm, limit: limit)
        return CatalogMatcher.bestMatch(query: query, candidates: found)
    }
}
