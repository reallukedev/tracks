import Foundation

/// All captures, sorted once, with the per-row facts that need the full history to work out
/// (first hearings and listening estimates). Build one when the store changes and pass it to
/// every calculation instead of re-sorting each time.
public struct ListeningHistory: Sendable {
    /// Oldest first.
    public let captures: [CaptureStat]
    public let seconds: [TimeInterval]
    /// Artist pictures by artist identity, from ``ArtistArtworkCache``.
    public let artistArtwork: [String: String]
    /// Genres and release years by song identity, from ``SongMetadataCache``. Songs not
    /// looked up yet are missing.
    public let songMetadata: [String: SongMetadata]
    let isFirstHearing: [Bool]
    /// The artists heard for the first time at each play, by identity. Usually empty; a
    /// collaboration can introduce several at once.
    let newArtists: [[String]]
    /// Whether any play came from Your Music, so the statistics can offer to show it apart.
    /// Stays true for a history scoped to Apple Music, which still has Your Music to switch to.
    public let hasYourMusic: Bool

    public init(
        _ captures: [CaptureStat],
        artistArtwork: [String: String] = [:],
        songMetadata: [String: SongMetadata] = [:]
    ) {
        self.artistArtwork = artistArtwork
        self.songMetadata = songMetadata
        let sorted = captures.sorted {
            ($0.capturedAt, $0.songIdentity) < ($1.capturedAt, $1.songIdentity)
        }
        let ordered = Self.credited(sorted, songMetadata: songMetadata) ?? sorted
        self.captures = ordered
        self.seconds = ListeningEstimate.seconds(for: ordered)

        var songs = Set<String>()
        var firstSong = [Bool](repeating: false, count: ordered.count)
        for (index, capture) in ordered.enumerated() {
            firstSong[index] = songs.insert(capture.songIdentity).inserted
        }
        self.isFirstHearing = firstSong
        self.newArtists = Self.newArtists(in: ordered)
        self.hasYourMusic = ordered.contains { $0.source == .yourMusic }
    }

    public var isEmpty: Bool { captures.isEmpty }

    public var first: CaptureStat? { captures.first }

    /// The same captures with new lookups attached. Skips the sort and the estimates.
    public func with(artistArtwork: [String: String], songMetadata: [String: SongMetadata]) -> ListeningHistory {
        ListeningHistory(copying: self, artistArtwork: artistArtwork, songMetadata: songMetadata)
    }

    private init(copying other: ListeningHistory, artistArtwork: [String: String], songMetadata: [String: SongMetadata]) {
        seconds = other.seconds
        isFirstHearing = other.isFirstHearing
        hasYourMusic = other.hasYourMusic
        self.artistArtwork = artistArtwork
        self.songMetadata = songMetadata
        if let credited = Self.credited(other.captures, songMetadata: songMetadata) {
            captures = credited
            newArtists = Self.newArtists(in: credited)
        } else {
            captures = other.captures
            newArtists = other.newArtists
        }
    }

    /// The captures credited from Apple Music's lists of their songs' artists, or nil when
    /// none of those lists changes anyone's credit.
    private static func credited(_ captures: [CaptureStat], songMetadata: [String: SongMetadata]) -> [CaptureStat]? {
        guard songMetadata.values.contains(where: { $0.artists?.isEmpty == false }) else { return nil }
        var updated = captures
        var changed = false
        // Each spelling of a song is parsed once, however often it was played.
        var parsed: [String: [ArtistCredit]] = [:]
        for index in captures.indices where captures[index].mayCreditSeveral {
            let capture = captures[index]
            guard let artists = songMetadata[capture.songIdentity]?.artists, !artists.isEmpty else { continue }
            let key = capture.artistName + "\u{1F}" + capture.title
            let credits = parsed[key] ?? ArtistCredits.parse(artist: capture.artistName, title: capture.title, catalogArtists: artists)
            parsed[key] = credits
            guard !credits.isEmpty, credits != capture.credits else { continue }
            updated[index] = capture.with(credits: credits)
            changed = true
        }
        return changed ? updated : nil
    }

    private static func newArtists(in ordered: [CaptureStat]) -> [[String]] {
        var heard = Set<String>()
        return ordered.map { capture in
            capture.credits.compactMap { heard.insert($0.identity).inserted ? $0.identity : nil }
        }
    }

    /// Only the plays from where `scope` says, or this history itself for everything.
    ///
    /// Each play keeps the facts worked out from the whole history: how long it was heard
    /// comes from the song after it, whichever source that was, and a song heard first on
    /// Apple Music isn't new the first time Your Music plays it.
    public func scoped(to scope: SourceScope) -> ListeningHistory {
        guard scope != .all else { return self }
        let kept = captures.indices.filter { scope.includes(captures[$0].source) }
        return ListeningHistory(subset: kept, of: self)
    }

    private init(subset indices: [Int], of other: ListeningHistory) {
        captures = indices.map { other.captures[$0] }
        seconds = indices.map { other.seconds[$0] }
        isFirstHearing = indices.map { other.isFirstHearing[$0] }
        newArtists = indices.map { other.newArtists[$0] }
        hasYourMusic = other.hasYourMusic
        artistArtwork = other.artistArtwork
        songMetadata = other.songMetadata
    }

    /// The genre and release year of the capture at `index`, if they're known.
    func metadata(at index: Int) -> SongMetadata? {
        songMetadata[captures[index].songIdentity]
    }

    /// Indices of captures in `interval`, treated as half-open so a song at midnight belongs
    /// to one day only. `nil` means everything.
    public func indices(in interval: DateInterval?) -> Range<Int> {
        guard let interval else { return captures.indices }
        let lower = firstIndex { $0.capturedAt >= interval.start }
        let upper = firstIndex { $0.capturedAt >= interval.end }
        return lower..<max(lower, upper)
    }

    /// Binary search for the first capture matching a predicate that flips once.
    private func firstIndex(where predicate: (CaptureStat) -> Bool) -> Int {
        var low = 0
        var high = captures.count
        while low < high {
            let mid = (low + high) / 2
            if predicate(captures[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}
