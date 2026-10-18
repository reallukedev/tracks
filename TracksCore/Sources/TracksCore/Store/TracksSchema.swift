import Foundation
import SwiftData

/// The store's first versioned schema, frozen as it shipped.
///
/// Every build before it opened the store with a bare `Schema`, so there is no earlier
/// version to name. SwiftData treats an unversioned store as whatever version its model
/// hashes match and infers a lightweight migration to this one, which covered what it added
/// over the last unversioned build: `Session.deviceID` and the indexes.
///
/// These are copies of the models as they were, attribute for attribute, so a store written
/// by a build with this version still matches it and can be migrated forward. Never change
/// them. CloudKit only accepts additive changes (new optional or defaulted attributes, new
/// models) once the schema is in Production, so a custom stage is for local clean-up, never
/// for renaming or removing a synced field.
public enum TracksSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [Capture.self, Station.self, Session.self, StatsSnapshot.self]
    }

    @Model
    public final class Capture {
        #Index<Capture>(
            [\.capturedAt],
            [\.songKey, \.kindRawValue],
            [\.songID, \.kindRawValue],
            [\.kindRawValue, \.capturedAt],
            [\.capturedByDeviceID, \.needsPlaylistWrite],
            [\.capturedByDeviceID, \.scrobbledAt]
        )

        public var songID: String = ""
        public var songKey: String = ""
        public var catalogLookupAttempts: Int = 0
        public var title: String = ""
        public var artistName: String = ""
        public var albumTitle: String?
        public var artworkURL: String?
        public var kindRawValue: String = CaptureKind.radio.rawValue
        public var capturedAt: Date = Date.distantPast
        public var platformRawValue: String = CapturePlatform.iOS.rawValue
        public var needsPlaylistWrite: Bool = true
        public var addedToPlaylistAt: Date?
        public var playlistWriteAttempts: Int = 0
        public var lastPlaylistWriteError: String?
        public var playedBackAt: Date?
        public var scrobbledAt: Date?
        public var scrobbleAttempts: Int = 0
        public var lastScrobbleError: String?
        public var capturedByDeviceID: String = ""

        @Relationship(inverse: \Session.captures)
        public var session: Session?

        /// For tests that write a store as this version wrote it.
        public init(songID: String, title: String, artistName: String, capturedAt: Date) {
            self.songID = songID
            self.songKey = songID
            self.title = title
            self.artistName = artistName
            self.capturedAt = capturedAt
        }
    }

    @Model
    public final class Session {
        #Index<Session>([\.endedAt], [\.startedAt], [\.deviceID, \.endedAt])

        public var startedAt: Date = Date.distantPast
        public var endedAt: Date?
        public var lastActivityAt: Date = Date.distantPast
        public var deviceID: String?

        @Relationship(inverse: \Station.sessions)
        public var station: Station?

        @Relationship(deleteRule: .nullify)
        public var captures: [Capture]? = []

        public init() {}
    }

    @Model
    public final class Station {
        public var name: String = ""
        public var catalogID: String?
        public var artworkURL: String?
        public var firstSeenAt: Date = Date.distantPast
        public var lastSeenAt: Date = Date.distantPast

        @Relationship(deleteRule: .nullify)
        public var sessions: [Session]? = []

        public init() {}
    }

    @Model
    public final class StatsSnapshot {
        public var rangeRawValue: String = StatsRange.allTime.rawValue
        public var computedAt: Date = Date.distantPast
        public var captureCount: Int = 0
        public var uniqueSongCount: Int = 0
        public var uniqueArtistCount: Int = 0
        public var sessionCount: Int = 0
        public var totalListeningSeconds: Double = 0
        public var discoveryRate: Double = 0

        public init() {}
    }
}

/// The current schema: the live model classes.
///
/// Adds `Capture.sourceRawValue`, which says whether a play was Apple Music or Your Music.
/// When the models next change, freeze these as nested copies inside this enum the way
/// ``TracksSchemaV1`` is, add `TracksSchemaV3` with the live classes, and give
/// ``TracksMigrationPlan`` a stage between them.
public enum TracksSchemaV2: VersionedSchema {
    public static let versionIdentifier = Schema.Version(2, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [TracksCore.Capture.self, TracksCore.Station.self, TracksCore.Session.self, TracksCore.StatsSnapshot.self]
    }
}

/// How an existing store reaches the current schema. Every container is opened with it,
/// including the widget's read-only one, so they all agree on what version the file is.
public enum TracksMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [TracksSchemaV1.self, TracksSchemaV2.self]
    }

    public static var stages: [MigrationStage] {
        [
            // A new optional attribute, which every existing play leaves empty: Apple Music.
            .lightweight(fromVersion: TracksSchemaV1.self, toVersion: TracksSchemaV2.self),
        ]
    }
}
