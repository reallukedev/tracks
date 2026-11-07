import Foundation

/// A playlist made in Tracks: songs you put in it, in your order, or a smart playlist whose
/// songs are whichever of yours match its rules, worked out afresh as your music changes.
public struct TracksPlaylist: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// The songs you put in it, in order. A smart playlist has none of its own.
    public var entries: [Entry]
    /// What a smart playlist's songs have to be; `nil` for one you fill yourself.
    public var rules: SmartRules?
    /// The Apple Music playlist it's merged with, where it is: songs added to either join the other.
    public var appleMusic: AppleMusicLink?
    public var createdAt: Date
    public var updatedAt: Date

    public var isSmart: Bool { rules != nil }

    public init(id: UUID = UUID(), name: String, entries: [Entry] = [], rules: SmartRules? = nil, now: Date = .now) {
        self.id = id
        self.name = name
        self.entries = entries
        self.rules = rules
        self.createdAt = now
        self.updatedAt = now
    }

    /// A song in a playlist, as it was when it was added: enough to find it again in your
    /// music after a sync, or to play it from its server if that's where it still is.
    public struct Entry: Codable, Sendable, Hashable, Identifiable {
        /// Its own, so the same song can be in a playlist twice and each moved on its own.
        public var id: UUID
        public var track: LocalTrack
        public var addedAt: Date

        public init(id: UUID = UUID(), track: LocalTrack, addedAt: Date = .now) {
            self.id = id
            self.track = track
            self.addedAt = addedAt
        }
    }

    /// An Apple Music playlist merged with this one.
    public struct AppleMusicLink: Codable, Sendable, Hashable {
        /// The playlist's id in the Apple Music library.
        public var playlistID: String
        public var name: String
        /// The songs, by identity, the Apple Music playlist had at the last merge: one gone from
        /// it since was taken out there, and goes from this playlist too.
        public var seen: [String]
        /// Songs, by identity, that couldn't be found for this playlist, so a merge doesn't look
        /// for them every time Tracks opens.
        public var notFound: [String]
        /// Songs here, by identity, that Apple Music knows by another name, with that name.
        /// `nil` on a link merged before these were kept, whose `seen` has both names mixed.
        public var matched: [String: String]?
        public var mergedAt: Date?

        public init(
            playlistID: String,
            name: String,
            seen: [String] = [],
            notFound: [String] = [],
            matched: [String: String]? = [:],
            mergedAt: Date? = nil
        ) {
            self.playlistID = playlistID
            self.name = name
            self.seen = seen
            self.notFound = notFound
            self.matched = matched
            self.mergedAt = mergedAt
        }
    }

    /// The songs' identities, each once.
    public var identities: Set<String> { Set(entries.map(\.track.identity)) }

    /// Adds songs at the end.
    public mutating func add(_ tracks: [LocalTrack], now: Date = .now) {
        guard !tracks.isEmpty else { return }
        entries += tracks.map { Entry(track: $0, addedAt: now) }
        updatedAt = now
    }

    public mutating func remove(_ ids: Set<UUID>, now: Date = .now) {
        entries.removeAll { ids.contains($0.id) }
        updatedAt = now
    }

    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int, now: Date = .now) {
        // IndexSet's own move lives in SwiftUI; this is the same, for the model.
        let moving = source.map { entries[$0] }
        var rest = entries.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let before = source.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: min(destination - before, rest.count))
        entries = rest
        updatedAt = now
    }
}
