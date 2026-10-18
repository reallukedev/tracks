import Foundation

/// What Apple Music knows about a song beyond its title: its genre and when it came out.
public struct SongMetadata: Sendable, Equatable, Codable {
    /// The song's main genre, like "Hip-Hop/Rap". Never Apple's catch-all "Music".
    public let genre: String?
    public let releaseYear: Int?
    /// The names of the song's artists in Apple Music, which settle who a collaboration
    /// credits (see ``ArtistCredits``). Empty when the catalog listed none; nil for songs
    /// looked up before Tracks asked, which a song that may credit several is asked about again.
    public let artists: [String]?

    public init(genre: String?, releaseYear: Int?, artists: [String]? = nil) {
        self.genre = genre
        self.releaseYear = releaseYear
        self.artists = artists
    }

    /// A song that was looked up and had nothing to say.
    public static let unknown = SongMetadata(genre: nil, releaseYear: nil, artists: [])

    /// Genre and release year, which is all a page shows.
    public var isEmpty: Bool { genre == nil && releaseYear == nil }

    /// The same, now that its artists have been asked about.
    func askedAboutArtists() -> SongMetadata {
        artists == nil ? SongMetadata(genre: genre, releaseYear: releaseYear, artists: []) : self
    }

    /// The song's genre, rolled up to one of Apple's top-level genres so a chart doesn't
    /// split one taste across "Hip-Hop/Rap", "Rap" and "Underground Rap".
    ///
    /// Apple lists the song's own genre first, which can be a subgenre, then the root
    /// "Music", then a mix of parents and subgenres: "Rap, Music, Hip-Hop/Rap". `topLevel` is
    /// the catalog's own word on which of those are top-level (the genres whose parent is the
    /// root), so the rule holds in any storefront's language. Without it, the first name that
    /// isn't the root.
    public static func primaryGenre(from names: [String], topLevel: Set<String> = []) -> String? {
        let cleaned = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return cleaned.first(where: topLevel.contains)
            ?? cleaned.first { $0.caseInsensitiveCompare("Music") != .orderedSame }
    }

    /// The year of a catalog release date. Read in UTC: the catalog gives a bare date, so
    /// 1 January in a time zone west of Greenwich would otherwise land in the year before.
    public static func releaseYear(from date: Date?) -> Int? {
        guard let date else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let year = calendar.component(.year, from: date)
        // The catalog has placeholder dates on a few very old or unreleased recordings.
        return (1900...2100).contains(year) ? year : nil
    }
}

/// Genres and release years by ``CaptureStat/songIdentity``, in a file on this device.
///
/// Like ``ArtistArtworkCache``, derived from the catalog and kept out of the synced store:
/// every device can look it up again, and a new synced field would need the CloudKit schema
/// deployed again. A file rather than defaults, because it runs to thousands of songs and the
/// widgets, which load the shared defaults, never need it.
public struct SongMetadataCache: Sendable {
    private let url: URL?

    /// Application Support by default. Nil keeps nothing, for previews and tests.
    public init(url: URL? = Self.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL? {
        URL.applicationSupportDirectory.appending(path: "SongMetadata.json")
    }

    /// Every lookup so far. ``SongMetadata/unknown`` means the song was asked about and the
    /// catalog had nothing, so it isn't asked about again.
    public func load() -> [String: SongMetadata] {
        guard let url, let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: SongMetadata].self, from: data)) ?? [:]
    }

    /// Saves one round of lookups on top of `existing`, and returns the result. Every song in
    /// `asked` missing from `found` is remembered as unknown, or keeps what an earlier round
    /// found, so asking again about its artists never loses its genre.
    @discardableResult
    public func record(
        found: [String: SongMetadata],
        asked: some Sequence<String>,
        into existing: [String: SongMetadata]
    ) -> [String: SongMetadata] {
        var updated = existing
        for identity in asked {
            updated[identity] = found[identity] ?? existing[identity]?.askedAboutArtists() ?? .unknown
        }
        if let url {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let data = try? JSONEncoder().encode(updated) {
                try? data.write(to: url, options: .atomic)
            }
        }
        return updated
    }
}

/// Which songs to look up a genre and release year for.
public enum SongMetadataLookup {
    public struct Request: Sendable, Equatable {
        public let songIdentity: String
        /// A catalog id, a library id ("i.…"), or empty, in which case the song is found by
        /// searching for its title and artist.
        public let songID: String
        public let title: String
        public let artistName: String
        public let albumTitle: String?

        public init(songIdentity: String, songID: String, title: String, artistName: String, albumTitle: String? = nil) {
            self.songIdentity = songIdentity
            self.songID = songID
            self.title = title
            self.artistName = artistName
            self.albumTitle = albumTitle
        }

        public var hasCatalogID: Bool { MusicItemIdentity.isCatalogID(songID) }
        public var hasLibraryID: Bool { MusicItemIdentity.isLibraryID(songID) }
        /// Whether it takes a search, one request per song, rather than a batched lookup.
        public var needsSearch: Bool { !hasCatalogID && !hasLibraryID }
    }

    /// Songs not yet in `lookedUp`, most played first. Up to `limit` that can be fetched by
    /// id in a batch, plus up to `searchLimit` that need a search each, so a round never
    /// turns into hundreds of searches.
    public static func pending(
        in history: ListeningHistory,
        lookedUp: Set<String>,
        limit: Int,
        searchLimit: Int
    ) -> [Request] {
        pending(in: history, limit: limit, searchLimit: searchLimit) { lookedUp.contains($0.songIdentity) }
    }

    /// The same, from what's known so far: a song looked up before Tracks asked for its
    /// artists is asked again when its credit may name several.
    public static func pending(
        in history: ListeningHistory,
        known: [String: SongMetadata],
        limit: Int,
        searchLimit: Int
    ) -> [Request] {
        pending(in: history, limit: limit, searchLimit: searchLimit) { capture in
            guard let metadata = known[capture.songIdentity] else { return false }
            return metadata.artists != nil || !capture.mayCreditSeveral
        }
    }

    private static func pending(
        in history: ListeningHistory,
        limit: Int,
        searchLimit: Int,
        isLookedUp: (CaptureStat) -> Bool
    ) -> [Request] {
        var plays: [String: Int] = [:]
        var requests: [String: Request] = [:]
        for capture in history.captures where !isLookedUp(capture) {
            plays[capture.songIdentity, default: 0] += 1
            let request = Request(
                songIdentity: capture.songIdentity,
                songID: capture.songID,
                title: capture.title,
                artistName: capture.artistName,
                albumTitle: capture.albumTitle
            )
            // A catalog id beats a library id, which beats a search. Otherwise the most
            // recent row wins, since history is oldest first.
            if rank(request) >= requests[capture.songIdentity].map(rank) ?? 0 {
                requests[capture.songIdentity] = request
            }
        }

        var batched = 0
        var searched = 0
        var result: [Request] = []
        let ordered = requests.values.sorted {
            (plays[$0.songIdentity] ?? 0, $1.songIdentity) > (plays[$1.songIdentity] ?? 0, $0.songIdentity)
        }
        for request in ordered where !request.title.isEmpty && !request.artistName.isEmpty {
            if request.needsSearch {
                guard searched < searchLimit else { continue }
                searched += 1
            } else {
                guard batched < limit else { continue }
                batched += 1
            }
            result.append(request)
            if batched >= limit, searched >= searchLimit { break }
        }
        return result
    }

    private static func rank(_ request: Request) -> Int {
        request.hasCatalogID ? 3 : (request.hasLibraryID ? 2 : 1)
    }
}
