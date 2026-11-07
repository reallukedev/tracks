import Foundation

/// A metadata search used to resolve a track to an Apple Music catalog ID.
///
/// The only way to identify a track on macOS, since `playerInfo` has no catalog ID on
/// macOS 27 (see ``PlayerInfoKey``).
public struct CatalogQuery: Sendable, Equatable, Hashable {
    public let title: String
    public let artistName: String
    /// Narrows the match when known. Usually nil for radio on macOS, where `playerInfo`
    /// omits `Total Time`.
    public let duration: TimeInterval?
    /// Narrows the match. `playerInfo` does include `Album` for a station.
    public let albumTitle: String?

    public init(
        title: String,
        artistName: String,
        duration: TimeInterval? = nil,
        albumTitle: String? = nil
    ) {
        self.title = title
        self.artistName = artistName
        self.duration = duration
        self.albumTitle = albumTitle
    }

    /// The term handed to `MusicCatalogSearchRequest`.
    public var searchTerm: String { "\(title) \(artistName)" }
}

/// Decides whether a catalog search result is the track we actually heard.
///
/// Strict: a wrong match puts the wrong song in the user's library, which is worse than
/// missing a capture, so ambiguous results are rejected.
public enum CatalogMatcher {
    /// Tracks within this many seconds count as the same length. The catalog and Music
    /// often disagree by a second or two.
    public static let durationTolerance: TimeInterval = 3.0

    /// Whether `candidate` is an acceptable match for `query`.
    public static func matches(query: CatalogQuery, candidate: CatalogCandidate) -> Bool {
        guard normalize(candidate.title) == normalize(query.title),
              normalize(candidate.artistName) == normalize(query.artistName)
        else { return false }

        // If either side has no duration, title and artist are enough.
        guard let wanted = query.duration, let got = candidate.duration else { return true }
        return abs(wanted - got) <= durationTolerance
    }

    /// The single best match, or nil if nothing qualifies.
    ///
    /// Album only breaks ties; it never rejects a lone candidate, because Music and the
    /// catalog often name albums differently ("Nostalgia - Single" vs "Nostalgia").
    public static func bestMatch(
        query: CatalogQuery,
        candidates: [CatalogCandidate]
    ) -> CatalogCandidate? {
        let qualifying = candidates.filter { matches(query: query, candidate: $0) }
        guard !qualifying.isEmpty else { return nil }

        if Set(qualifying.map(\.id)).count == 1 { return qualifying.first }

        if let wantedAlbum = query.albumTitle {
            let byAlbum = qualifying.filter {
                guard let album = $0.albumTitle else { return false }
                return normalizeAlbum(album) == normalizeAlbum(wantedAlbum)
            }
            if Set(byAlbum.map(\.id)).count == 1 { return byAlbum.first }
        }

        // Otherwise group by length. One recording on a single, album and EP shares a length;
        // a rework or live cut stands alone. The largest group wins; a tie is ambiguous.
        return largestRecordingGroup(qualifying)?.first
    }

    /// The biggest set of candidates that share a length, or nil when no single group leads.
    static func largestRecordingGroup(_ candidates: [CatalogCandidate]) -> [CatalogCandidate]? {
        // Can't group without every length.
        guard candidates.allSatisfy({ $0.duration != nil }) else { return nil }

        var groups: [[CatalogCandidate]] = []
        for candidate in candidates {
            let index = groups.firstIndex { group in
                guard let a = group.first?.duration, let b = candidate.duration else { return false }
                return abs(a - b) <= durationTolerance
            }
            if let index { groups[index].append(candidate) } else { groups.append([candidate]) }
        }

        let sorted = groups.sorted { $0.count > $1.count }
        guard let best = sorted.first else { return nil }
        // A tie between differently-sized recordings is genuine ambiguity.
        if sorted.count > 1, sorted[1].count == best.count { return nil }
        return best
    }

    /// Also drops the " - Single" and " - EP" suffixes Music adds and the catalog often doesn't.
    static func normalizeAlbum(_ value: String) -> String {
        var normalized = normalize(value)
        for suffix in [" - single", " - ep"] where normalized.lowercased().hasSuffix(suffix) {
            normalized = String(normalized.dropLast(suffix.count))
        }
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Words in a trailing qualifier that mean a different recording. "(Live)" and "(Mixed)"
    /// are kept when comparing; "(Remastered)" and "(feat. …)" are dropped.
    static let versionQualifiers = [
        "live", "remix", "rework", "mixed", "mix", "acoustic", "demo", "instrumental",
        "edit", "version", "reprise", "cover", "karaoke", "sped up", "slowed",
        "extended", "dub", "bootleg", "flip", "session",
    ]

    /// Case-, whitespace- and diacritic-insensitive. Drops a trailing parenthetical unless
    /// it names a different version (see ``versionQualifiers``).
    static func normalize(_ value: String) -> String {
        var result = value
        if let range = result.range(
            of: #"\s*[\(\[][^\)\]]*[\)\]]\s*$"#,
            options: .regularExpression
        ) {
            let qualifier = result[range].lowercased()
            let changesRecording = versionQualifiers.contains { qualifier.contains($0) }
            if !changesRecording { result.removeSubrange(range) }
        }
        return result
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A catalog search result, reduced to the fields the matcher needs.
///
/// Declared here so ``CatalogMatcher`` can be tested without MusicKit.
public struct CatalogCandidate: Sendable, Equatable, Hashable {
    public let id: String
    public let title: String
    public let artistName: String
    public let albumTitle: String?
    public let duration: TimeInterval?
    /// The only source of artwork on macOS.
    public let artworkURL: String?

    public init(
        id: String,
        title: String,
        artistName: String,
        albumTitle: String? = nil,
        duration: TimeInterval? = nil,
        artworkURL: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.duration = duration
        self.artworkURL = artworkURL
    }
}
