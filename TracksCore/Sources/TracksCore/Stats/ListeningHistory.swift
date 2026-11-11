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
    /// Every song and every artist heard, for telling whether a play added at the end is the
    /// first of its song or introduces an artist, without walking the history again.
    let heardSongs: Set<String>
    let heardArtists: Set<String>

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
        self.heardSongs = songs
        var artists = Set<String>()
        self.newArtists = Self.newArtists(in: ordered, heard: &artists)
        self.heardArtists = artists
        self.hasYourMusic = ordered.contains { $0.source == .yourMusic }
    }

    /// This history with plays added after its last one, the same as building it again from
    /// every play with the same lookups, without sorting or walking the plays already here.
    ///
    /// Each new song used to cost a whole rebuild: in a long history, a sort of a hundred
    /// thousand plays or more after every one.
    ///
    /// - Returns: nil when a play doesn't come after every play here (one synced in late, say),
    ///   so it has to be built again from everything.
    public func appending(_ newer: [CaptureStat]) -> ListeningHistory? {
        guard !newer.isEmpty else { return self }
        let added = newer.sorted {
            ($0.capturedAt, $0.songIdentity) < ($1.capturedAt, $1.songIdentity)
        }
        if let last = captures.last, let first = added.first,
           !((last.capturedAt, last.songIdentity) < (first.capturedAt, first.songIdentity)) {
            return nil
        }
        return ListeningHistory(appending: Self.credited(added, songMetadata: songMetadata) ?? added, to: self)
    }

    /// This history brought up to date by the reader's steps, or nil when one of them can't
    /// be taken without building it again from everything.
    public func applying(_ steps: [ListeningHistoryReader.Step]) -> ListeningHistory? {
        var history = self
        for step in steps {
            // A step's changes are all to plays from before it.
            guard let next = history.replacing(step.changed)?.appending(step.added) else { return nil }
            history = next
        }
        return history
    }

    /// This history with plays that changed in place: a cover or catalog id found, an album
    /// filled in, a station renamed. The same as building it again from every play.
    ///
    /// - Returns: nil when a change moves a play, or could change what's worked out from the
    ///   plays around it (its time, kind, source or artists), or when the play can't be told
    ///   apart from another; then it has to be built again from everything.
    public func replacing(_ changes: [(old: CaptureStat, new: CaptureStat)]) -> ListeningHistory? {
        guard !changes.isEmpty else { return self }
        var updated = captures
        for (old, new) in changes {
            guard old.capturedAt == new.capturedAt, old.songIdentity == new.songIdentity,
                  old.kind == new.kind, old.source == new.source
            else { return nil }
            let lower = firstIndex { ($0.capturedAt, $0.songIdentity) >= (new.capturedAt, new.songIdentity) }
            guard lower < updated.count,
                  (updated[lower].capturedAt, updated[lower].songIdentity) == (new.capturedAt, new.songIdentity),
                  lower + 1 == updated.count
                    || (updated[lower + 1].capturedAt, updated[lower + 1].songIdentity) != (new.capturedAt, new.songIdentity)
            else { return nil }
            let credited = Self.credited([new], songMetadata: songMetadata)?.first ?? new
            guard credited.creditIdentities == updated[lower].creditIdentities else { return nil }
            updated[lower] = credited
        }
        return ListeningHistory(replacing: updated, in: self)
    }

    private init(replacing updated: [CaptureStat], in other: ListeningHistory) {
        captures = updated
        seconds = other.seconds
        isFirstHearing = other.isFirstHearing
        newArtists = other.newArtists
        heardSongs = other.heardSongs
        heardArtists = other.heardArtists
        hasYourMusic = other.hasYourMusic
        artistArtwork = other.artistArtwork
        songMetadata = other.songMetadata
    }

    private init(appending added: [CaptureStat], to other: ListeningHistory) {
        artistArtwork = other.artistArtwork
        songMetadata = other.songMetadata
        captures = other.captures + added
        // Only the last play whose time is known is measured by what comes next; the plays
        // before it keep what they had.
        let measured = other.captures.lastIndex { $0.kind.timeIsKnown } ?? other.captures.count
        seconds = Array(other.seconds[..<measured])
            + ListeningEstimate.seconds(for: Array(other.captures[measured...]) + added)

        var songs = other.heardSongs
        isFirstHearing = other.isFirstHearing + added.map { songs.insert($0.songIdentity).inserted }
        heardSongs = songs
        var artists = other.heardArtists
        newArtists = other.newArtists + Self.newArtists(in: added, heard: &artists)
        heardArtists = artists
        hasYourMusic = other.hasYourMusic || added.contains { $0.source == .yourMusic }
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
        heardSongs = other.heardSongs
        hasYourMusic = other.hasYourMusic
        self.artistArtwork = artistArtwork
        self.songMetadata = songMetadata
        if let credited = Self.credited(other.captures, songMetadata: songMetadata) {
            captures = credited
            var artists = Set<String>()
            newArtists = Self.newArtists(in: credited, heard: &artists)
            heardArtists = artists
        } else {
            captures = other.captures
            newArtists = other.newArtists
            heardArtists = other.heardArtists
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
        // And each song credited anew once, shared by its plays as before.
        var recredited: [ObjectIdentifier: CaptureStat.Song] = [:]
        for index in captures.indices where captures[index].mayCreditSeveral {
            let capture = captures[index]
            guard let artists = songMetadata[capture.songIdentity]?.artists, !artists.isEmpty else { continue }
            let key = capture.artistName + "\u{1F}" + capture.title
            let credits = parsed[key] ?? ArtistCredits.parse(artist: capture.artistName, title: capture.title, catalogArtists: artists)
            parsed[key] = credits
            guard !credits.isEmpty, credits != capture.credits else { continue }
            let song = recredited[ObjectIdentifier(capture.song)] ?? CaptureStat.Song(copying: capture.song, credits: credits)
            recredited[ObjectIdentifier(capture.song)] = song
            updated[index] = capture.with(song: song)
            changed = true
        }
        return changed ? updated : nil
    }

    private static func newArtists(in ordered: [CaptureStat], heard: inout Set<String>) -> [[String]] {
        ordered.map { capture in
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
        // A part of the history is never added to, so what the whole has heard will do.
        heardSongs = other.heardSongs
        heardArtists = other.heardArtists
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
