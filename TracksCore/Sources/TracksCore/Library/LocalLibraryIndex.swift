import Foundation

/// An album of your own music: its songs in disc and track order.
public struct LocalAlbum: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let artist: String
    public let tracks: [LocalTrack]

    public init(id: String, title: String, artist: String, tracks: [LocalTrack]) {
        self.id = id
        self.title = title
        self.artist = artist
        self.tracks = tracks
    }

    public var year: Int? { tracks.compactMap(\.year).max() }
    public var genre: String? { tracks.lazy.compactMap(\.genre).first }
    public var artwork: LocalTrack.Artwork? { tracks.lazy.compactMap(\.artwork).first }
    public var addedAt: Date { tracks.map(\.addedAt).max() ?? .distantPast }
    public var duration: TimeInterval { tracks.compactMap(\.duration).reduce(0, +) }

    /// The best format on the album, for its badge: hi-res if any song is.
    public var format: AudioFormat? {
        let formats = tracks.compactMap(\.format)
        return formats.first(where: \.isHiRes) ?? formats.first(where: \.isLossless) ?? formats.first
    }

    /// The album's discs, in order, each with its songs, when there's more than one disc.
    /// A one-disc album is a single entry, numbered 1.
    public var discs: [(number: Int, tracks: [LocalTrack])] {
        var discs: [(number: Int, tracks: [LocalTrack])] = []
        for track in tracks {
            let number = track.discNumber ?? 1
            if discs.last?.number == number {
                discs[discs.count - 1].tracks.append(track)
            } else {
                discs.append((number, [track]))
            }
        }
        return discs
    }

    /// Whether it's an album, an EP or a single: said by its title where it says so ("Tides - EP"),
    /// otherwise judged as stores do, by how many songs it has and how long it runs. A
    /// single is up to three songs under half an hour; an EP four to six under half an hour.
    public var kind: Kind {
        if let (kind, _) = Self.taggedKind(of: title) { return kind }
        let known = tracks.compactMap(\.duration)
        // Without lengths there's no telling a short album from an EP.
        guard known.count == tracks.count, duration < 30 * 60 else { return .album }
        switch tracks.count {
        case 1...3: return .single
        case 4...6: return .ep
        default: return .album
        }
    }

    /// The title without " - EP" or " - Single" on the end, which the page says another way.
    public var displayTitle: String {
        Self.taggedKind(of: title)?.title ?? title
    }

    public enum Kind: Sendable, Hashable {
        case album, ep, single
    }

    private static func taggedKind(of title: String) -> (kind: Kind, title: String)? {
        for (suffix, kind) in [(" - EP", Kind.ep), (" - Single", .single), (" (EP)", .ep), (" (Single)", .single)]
        where title.count > suffix.count && title.lowercased().hasSuffix(suffix.lowercased()) {
            return (kind, String(title.dropLast(suffix.count)))
        }
        return nil
    }

    /// The songs, first disc first, each disc in track order, untagged ones by title.
    static func ordered(_ tracks: [LocalTrack]) -> [LocalTrack] {
        tracks.sorted { lhs, rhs in
            let (leftDisc, rightDisc) = (lhs.discNumber ?? 1, rhs.discNumber ?? 1)
            if leftDisc != rightDisc { return leftDisc < rightDisc }
            switch (lhs.trackNumber, rhs.trackNumber) {
            case let (left?, right?) where left != right: return left < right
            case (nil, _?): return false
            case (_?, nil): return true
            default: return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
    }
}

/// An artist in your own music, with their albums newest first.
public struct LocalArtist: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let albums: [LocalAlbum]

    public var tracks: [LocalTrack] { albums.flatMap(\.tracks) }
    public var artwork: LocalTrack.Artwork? { albums.lazy.compactMap(\.artwork).first }
}

/// Your own music, arranged: every song, grouped into albums and artists, searchable, and
/// matched to the history by song.
public struct LocalLibraryIndex: Sendable {
    public let tracks: [LocalTrack]
    public let albums: [LocalAlbum]
    public let artists: [LocalArtist]
    private let byID: [String: LocalTrack]
    private let byIdentity: [String: [LocalTrack]]
    private let albumsByID: [String: LocalAlbum]
    private let artistsByID: [String: LocalArtist]
    /// Each song's title, artist and album, folded for search once rather than on every letter
    /// typed. In the order of `tracks`.
    private let searchText: [SearchText]
    /// Each album's title and artist, and each artist's name, folded, in the order of
    /// `albums` and `artists`.
    private let albumText: [(title: String, artist: String)]
    /// The same, folded as search compares them: see ``SearchFolding``.
    private let albumSearchText: [(title: String, artist: String)]
    private let artistText: [String]

    private struct SearchText: Sendable {
        let title: String
        let artist: String
        let album: String
    }

    public static let empty = LocalLibraryIndex(tracks: [])

    public init(tracks: [LocalTrack]) {
        // One song per id: a file and a download of the same server song stay apart, but
        // the same file indexed twice doesn't.
        var seen = Set<String>()
        let unique = tracks.filter { seen.insert($0.id).inserted }
        self.tracks = unique.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        self.byID = Dictionary(uniqueKeysWithValues: unique.map { ($0.id, $0) })
        self.byIdentity = Dictionary(grouping: unique, by: \.identity)

        let albums = Dictionary(grouping: unique, by: \.albumKey).map { key, tracks in
            let ordered = LocalAlbum.ordered(tracks)
            let first = ordered[0]
            return LocalAlbum(id: key, title: first.album ?? first.title, artist: first.albumArtistName, tracks: ordered)
        }
        self.albums = albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        self.albumsByID = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        self.artists = Dictionary(grouping: albums, by: { StatsCalculator.folded($0.artist) })
            .map { key, albums in
                LocalArtist(
                    id: key,
                    name: albums[0].artist,
                    albums: albums.sorted { ($0.year ?? 0, $0.title) > ($1.year ?? 0, $1.title) }
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.artistsByID = Dictionary(self.artists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.searchText = self.tracks.map {
            SearchText(title: SearchFolding.fold($0.title), artist: SearchFolding.fold($0.artist), album: SearchFolding.fold($0.album ?? ""))
        }
        self.albumText = self.albums.map { (Self.fold($0.title), Self.fold($0.artist)) }
        self.albumSearchText = self.albums.map { (SearchFolding.fold($0.title), SearchFolding.fold($0.artist)) }
        self.artistText = self.artists.map { SearchFolding.fold($0.name) }
    }

    public var isEmpty: Bool { tracks.isEmpty }

    public func track(id: String) -> LocalTrack? { byID[id] }

    public func album(id: String) -> LocalAlbum? { albumsByID[id] }

    public func artist(id: String) -> LocalArtist? { artistsByID[id] }

    /// The song in your own music a history song stands for: by its id when it was played from
    /// here, otherwise by title and artist, a file before a server's copy.
    public func track(forSongID songID: String, identity: String) -> LocalTrack? {
        if let exact = byID[songID] { return exact }
        let matches = byIdentity[identity] ?? []
        return matches.first { !$0.isFromServer } ?? matches.first
    }

    /// Every copy of a song, by its ``LocalTrack/identity``: a file, a server's, a download.
    public func tracks(withIdentity identity: String) -> [LocalTrack] {
        byIdentity[identity] ?? []
    }

    /// Songs from elsewhere, a server's search say, that aren't in this library by id or by
    /// title and artist. Each song once, in the order given.
    public func notIncluded(_ tracks: [LocalTrack]) -> [LocalTrack] {
        var seen = Set<String>()
        return tracks.filter { track in
            byID[track.id] == nil && byIdentity[track.identity] == nil && seen.insert(track.identity).inserted
        }
    }

    /// Albums by someone else with a song crediting this artist on it: a compilation, or a
    /// song they're featured on. By their folded name, as ``LocalArtist/id``.
    public func albums(appearingOn artistID: String) -> [LocalAlbum] {
        zip(albums, albumText).compactMap { album, text in
            guard text.artist != artistID,
                  album.tracks.contains(where: { LocalTrack.creditedArtists(of: $0.artist).contains(artistID) })
            else { return nil }
            return album
        }
    }

    /// Albums added most recently first.
    public var recentlyAdded: [LocalAlbum] {
        albums.sorted { $0.addedAt > $1.addedAt }
    }

    /// Songs, albums and artists whose names hold every word searched for, ignoring case and
    /// accents, best matches first: a name that is what was typed, then one that starts with
    /// it, then one with a word that does, then the rest, each in the library's order.
    /// Every typed word in a song's, album's or artist's names, case, accents and punctuation
    /// aside, the closest matches first: the whole name, then its start, then one of its
    /// words'. With nothing found, a word a letter off counts too, so a typo still finds it.
    public func search(_ query: String, limit: Int = 50) -> (tracks: [LocalTrack], albums: [LocalAlbum], artists: [LocalArtist]) {
        let words = SearchFolding.fold(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return ([], [], []) }
        let exact = search(words, limit: limit) { haystack, word in haystack.contains(word) }
        guard exact.tracks.isEmpty, exact.albums.isEmpty, exact.artists.isEmpty,
              words.contains(where: { $0.count >= 4 })
        else { return exact }
        return search(words, limit: limit) { haystack, word in
            haystack.contains(word) || haystack.split(separator: " ").contains { SearchFolding.isNear(word, $0) }
        }
    }

    private func search(
        _ words: [String],
        limit: Int,
        matching: (String, String) -> Bool
    ) -> (tracks: [LocalTrack], albums: [LocalAlbum], artists: [LocalArtist]) {
        let term = words.joined(separator: " ")
        func matches(_ haystack: String) -> Bool {
            words.allSatisfy { matching(haystack, $0) }
        }
        var tracks: [(rank: Int, item: LocalTrack)] = []
        for (position, text) in searchText.enumerated() where matches(text.title + " " + text.artist + " " + text.album) {
            // A song's own name counts most; its artist's or album's next.
            let rank = min(Self.rank(of: text.title, for: term), 4 + Self.rank(of: text.artist, for: term), 4 + Self.rank(of: text.album, for: term))
            tracks.append((rank, self.tracks[position]))
        }
        let albums = zip(self.albums, albumSearchText).compactMap { album, text -> (rank: Int, item: LocalAlbum)? in
            guard matches(text.title + " " + text.artist) else { return nil }
            return (min(Self.rank(of: text.title, for: term), 4 + Self.rank(of: text.artist, for: term)), album)
        }
        let artists = zip(self.artists, artistText).compactMap { artist, name -> (rank: Int, item: LocalArtist)? in
            guard matches(name) else { return nil }
            return (Self.rank(of: name, for: term), artist)
        }
        return (
            Self.best(tracks, limit: limit).map(\.item),
            Self.best(albums, limit: limit).map(\.item),
            Self.best(artists, limit: limit).map(\.item)
        )
    }

    /// Songs from elsewhere, a server's search say, closest to what was typed first, as this
    /// library's own are: a song of that very name before one that only has it in its album's.
    /// Equal ones stay in the order they came.
    public static func ranked(_ tracks: [LocalTrack], for query: String) -> [LocalTrack] {
        let term = SearchFolding.fold(query)
        guard !term.isEmpty else { return tracks }
        let ranked = tracks.map { track in
            let rank = min(
                rank(of: SearchFolding.fold(track.title), for: term),
                4 + rank(of: SearchFolding.fold(track.artist), for: term),
                4 + rank(of: SearchFolding.fold(track.album ?? ""), for: term)
            )
            return (rank: rank, item: track)
        }
        return best(ranked, limit: .max).map(\.item)
    }

    /// The best ranked first, equal ones in the order they came.
    private static func best<Item>(_ ranked: [(rank: Int, item: Item)], limit: Int) -> [(rank: Int, item: Item)] {
        ranked.enumerated()
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .prefix(limit)
            .map(\.element)
    }

    /// How well a name matches what was typed: 0 when it's the same, 1 when it starts with it,
    /// 2 when one of its words does, 3 otherwise.
    private static func rank(of name: String, for term: String) -> Int {
        if name == term { return 0 }
        if name.hasPrefix(term) { return 1 }
        if name.contains(" " + term) || name.contains("(" + term) { return 2 }
        return 3
    }

    private static func fold(_ text: String) -> String {
        StatsCalculator.folded(text)
    }
}
