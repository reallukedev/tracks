import Foundation

/// Who made a recording and what it borrows, as MusicBrainz records them: the people in
/// Apple Music's credit groups, the songs it samples or that sample it, and the facts a song
/// heard on the radio may come without.
public struct SongCredits: Codable, Sendable, Equatable {
    public var sections: [CreditSection]
    /// Songs this one takes from.
    public var samples: [RecordingLink]
    /// Songs that take from this one.
    public var sampledBy: [RecordingLink]
    /// Mashups built partly from this one.
    public var mashups: [RecordingLink]
    /// Remixes of this recording, which belong with its other versions.
    public var remixes: [RecordingLink]
    /// The compositions it performs, for its other versions and covers.
    public var workIDs: [String]
    /// MusicBrainz's genres for it, most agreed first.
    public var genres: [String]
    public var firstReleaseYear: Int?
    /// The recording on MusicBrainz, for a link to it.
    public var recordingID: String

    public init(
        sections: [CreditSection] = [],
        samples: [RecordingLink] = [],
        sampledBy: [RecordingLink] = [],
        mashups: [RecordingLink] = [],
        remixes: [RecordingLink] = [],
        workIDs: [String] = [],
        genres: [String] = [],
        firstReleaseYear: Int? = nil,
        recordingID: String
    ) {
        self.sections = sections
        self.samples = samples
        self.sampledBy = sampledBy
        self.mashups = mashups
        self.remixes = remixes
        self.workIDs = workIDs
        self.genres = genres
        self.firstReleaseYear = firstReleaseYear
        self.recordingID = recordingID
    }

    /// Nothing to show and nowhere to look for versions.
    public var isEmpty: Bool {
        sections.isEmpty && !hasSamples && remixes.isEmpty && workIDs.isEmpty && genres.isEmpty && firstReleaseYear == nil
    }

    public var hasSamples: Bool { !samples.isEmpty || !sampledBy.isEmpty || !mashups.isEmpty }

    public var pageURL: URL? { URL(string: "https://musicbrainz.org/recording/\(recordingID)") }
}

/// Other recordings of the same composition: the artist's own live takes, remixes and
/// instrumentals, and other artists' covers.
public struct SongVersions: Codable, Sendable, Equatable {
    public var versions: [RecordingLink]
    public var covers: [RecordingLink]
    /// "C♯ minor", where the composition records one.
    public var key: String?

    public init(versions: [RecordingLink] = [], covers: [RecordingLink] = [], key: String? = nil) {
        self.versions = versions
        self.covers = covers
        self.key = key
    }

    public var isEmpty: Bool { versions.isEmpty && covers.isEmpty && key == nil }
}

/// One of Apple Music's credit groups.
public struct CreditSection: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: Int, Codable, Sendable, CaseIterable {
        case performers, composition, production
    }

    public let kind: Kind
    /// Each person once, in the order MusicBrainz lists them.
    public var credits: [Credit]

    public var id: Kind { kind }

    public init(kind: Kind, credits: [Credit]) {
        self.kind = kind
        self.credits = credits
    }
}

/// A person and what they did, in Apple Music's words: "Producer", "Assistant Engineer".
public struct Credit: Codable, Sendable, Equatable, Identifiable {
    public let name: String
    public var roles: [CreditRole]

    public var id: String { name }

    public init(name: String, roles: [CreditRole]) {
        self.name = name
        self.roles = roles
    }
}

/// A role, kept as MusicBrainz's relationship and attributes so the app words it.
public struct CreditRole: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case featured, performer, vocals, instrument, orchestra, conductor
        case songwriter, composer, lyricist, arranger
        case producer, mixing, engineer, recording, mastering, programming
    }

    public let kind: Kind
    /// "assistant", "co", "executive", or an instrument's name.
    public let detail: String?

    public init(_ kind: Kind, detail: String? = nil) {
        self.kind = kind
        self.detail = detail
    }
}

/// Another recording a song's info points to: a sample, a remix, a cover.
public struct RecordingLink: Codable, Sendable, Hashable, Identifiable {
    public let title: String
    public let artistName: String
    public let year: Int?
    /// MusicBrainz's own note on which recording it is: "live, 2005-09-21: Abbey Road
    /// Studios", or "Instrumental" where it gives no note.
    public let detail: String?
    public let recordingID: String

    public var id: String { recordingID }

    public init(title: String, artistName: String, year: Int? = nil, detail: String? = nil, recordingID: String) {
        self.title = title
        self.artistName = artistName
        self.year = year
        self.detail = detail
        self.recordingID = recordingID
    }
}
