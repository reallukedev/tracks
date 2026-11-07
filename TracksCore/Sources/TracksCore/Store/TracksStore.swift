import Foundation
import SwiftData

/// The SwiftData container in the App Group. The app, widgets and Live Activity read it,
/// and CloudKit mirrors it to the user's other devices.
@MainActor
public final class TracksStore {
    public let container: ModelContainer
    /// Where the store actually opened, which may not be where it was asked to.
    public let backing: Backing

    /// Why sync didn't start when it was asked to. Nil when sync is off or working.
    /// Shown in settings, since an unreachable container otherwise looks like an idle device.
    public let syncFailureReason: String?

    public enum Backing: Sendable, Equatable, CustomStringConvertible {
        case appGroup(String, synced: Bool)
        case inMemory(reason: String)

        public var description: String {
            switch self {
            case .appGroup(let id, let synced):
                "App Group container (\(id))\(synced ? ", synced to iCloud" : "")"
            case .inMemory(let reason): "in-memory (\(reason))"
            }
        }

        public var isSynced: Bool {
            if case .appGroup(_, let synced) = self { return synced }
            return false
        }
    }

    /// The one read-write store for this process.
    ///
    /// All writes go through this. A second read-write open of the same file fails and
    /// falls back to an empty in-memory store. App Intents run inside the app's process when
    /// it's open, so an intent with its own store would capture into nothing.
    ///
    /// Read-only callers (the widget) and tests make their own.
    @MainActor
    public static func shared() throws -> TracksStore {
        if let existing = sharedStore { return existing }
        let store = try TracksStore()
        sharedStore = store
        return store
    }

    @MainActor private static var sharedStore: TracksStore?

    /// The current schema. Always open a container through ``makeContainer(_:)`` so the
    /// migration plan comes with it.
    public static let schema = Schema(versionedSchema: TracksSchemaV2.self)

    /// Opens the shared container, falling back to in-memory if that fails.
    ///
    /// An unsigned build, or one without `DEVELOPMENT_TEAM`, gets a plausible identifier and
    /// path that SwiftData can't write to. Trying the open is the only real test, and
    /// ``backing`` records what happened.
    /// - Parameters:
    ///   - readOnly: Opens without write access, for widgets and other second processes.
    ///     A second read-write open fails while the app has the store open.
    ///   - sync: Whether to mirror the store to iCloud. Defaults to the user's preference.
    public init(
        inMemory: Bool = false,
        readOnly: Bool = false,
        sync: Bool = CloudSync.isEnabled
    ) throws {
        var pendingSyncFailure: String?

        if !inMemory, let identifier = AppGroup.identifier, AppGroup.hasCandidateContainer {
            // Read-only openers (the widget) never sync; the app owns the file.
            let cloudIdentifier = (sync && !readOnly) ? CloudSync.containerIdentifier : nil

            if let cloudIdentifier {
                do {
                    container = try Self.open(
                        group: identifier,
                        readOnly: readOnly,
                        cloud: .private(cloudIdentifier)
                    )
                    backing = .appGroup(identifier, synced: true)
                    syncFailureReason = nil
                    if !readOnly { stampLegacyCaptures() }
                    return
                } catch {
                    // Sync can fail for ordinary reasons (no iCloud account, a container
                    // the profile doesn't grant, a schema CloudKit rejects). Open the local
                    // store without sync; falling back to in-memory would hide the history.
                    pendingSyncFailure = CloudSyncMonitor.startFailure(for: error)
                }
            }

            do {
                let container = try Self.open(group: identifier, readOnly: readOnly, cloud: .none)
                self.container = container
                backing = .appGroup(identifier, synced: false)
                syncFailureReason = pendingSyncFailure
                if !readOnly { stampLegacyCaptures() }
                return
            } catch {
                // Fall back to in-memory, keeping the reason for the probe.
                container = try Self.inMemoryContainer()
                backing = .inMemory(reason: "App Group \(identifier) not writable: \(error.localizedDescription)")
                syncFailureReason = pendingSyncFailure
                return
            }
        }

        container = try Self.inMemoryContainer()
        backing = .inMemory(
            reason: inMemory ? "requested" : "no App Group configured"
        )
        syncFailureReason = nil
    }

    /// An in-memory container that never talks to iCloud.
    ///
    /// `cloudKitDatabase` must be `.none`. The default, `.automatic`, syncs even an in-memory
    /// store, which once pulled real history into the demo store and could have pushed demo
    /// plays into the real one.
    static func inMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: Self.schema,
            isStoredInMemoryOnly: true,
            allowsSave: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        return try makeContainer(configuration)
    }

    /// Opens a container on the current schema and ``TracksMigrationPlan``.
    ///
    /// The one place a container is made, so the app, the widget's read-only open, the demo
    /// store and tests all migrate the same way.
    static func makeContainer(_ configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(
            for: Self.schema,
            migrationPlan: TracksMigrationPlan.self,
            configurations: configuration
        )
    }

    private static func open(
        group identifier: String,
        readOnly: Bool,
        cloud: ModelConfiguration.CloudKitDatabase
    ) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: Self.schema,
            isStoredInMemoryOnly: false,
            allowsSave: !readOnly,
            groupContainer: .identifier(identifier),
            cloudKitDatabase: cloud
        )
        return try makeContainer(configuration)
    }

    /// Marks pre-sync rows as this device's, once.
    ///
    /// Rows that exist the first time the store opens here were made here. The playlist and
    /// scrobble queues are scoped by device ID, so unstamped rows would never be written.
    ///
    /// Runs on every writable open, synced or not. It used to run only when sync started,
    /// so a device without iCloud, or one whose CloudKit container failed to open, never
    /// stamped its rows and they sat in neither queue for good. Read-only opens skip it,
    /// since they can't save.
    ///
    /// Done once, not every launch. On a second device the CloudKit import usually hasn't
    /// landed yet, but if it has, an imported row gets stamped too and its playlist write
    /// happens twice. One duplicate is better than a capture that never reaches the playlist.
    ///
    /// The flag is only set once the stamp is saved. It used to be set first, so a failed
    /// fetch or save marked the rows as done without touching them.
    ///
    /// - Returns: whether the stamp is now done, which tests use.
    @discardableResult
    func stampLegacyCaptures(
        deviceID: String = DeviceIdentity.current,
        isDone: () -> Bool = { CloudSync.hasStampedLegacyCaptures },
        markDone: () -> Void = { CloudSync.hasStampedLegacyCaptures = true }
    ) -> Bool {
        guard !isDone() else { return true }

        let descriptor = FetchDescriptor<Capture>(
            predicate: #Predicate { $0.capturedByDeviceID.isEmpty }
        )
        do {
            let rows = try context.fetch(descriptor)
            if !rows.isEmpty {
                for row in rows { row.capturedByDeviceID = deviceID }
                try context.save()
            }
            markDone()
            return true
        } catch {
            // Try again next launch rather than leave half-stamped rows for an unrelated
            // save to write.
            context.rollback()
            return false
        }
    }

    public var context: ModelContext { container.mainContext }

    /// The history as plain values, kept up to date in the background. One per store, so
    /// the screens and the merge share its first full read.
    public private(set) lazy var historyReader = ListeningHistoryReader(container: container)

    // MARK: - Capture

    /// Records an observation, or returns nil if the dedupe window says it's the same play.
    ///
    /// Must stay synchronous: with an `await` between the dedupe check and the insert, two
    /// observations of the same song could both be inserted. The playlist write happens
    /// later, off `needsPlaylistWrite`.
    @discardableResult
    public func recordCapture(
        songID: String,
        title: String,
        artistName: String,
        albumTitle: String? = nil,
        artworkURL: String? = nil,
        kind: CaptureKind = .radio,
        session: Session? = nil,
        now: Date = .now,
        policy: DedupePolicy = .default
    ) throws -> Capture? {
        let lastSeen = try mostRecentCaptureDate(songID: songID, kind: kind)
        guard policy.shouldCapture(lastSeen: lastSeen, now: now) else { return nil }

        let capture = Capture(
            songID: songID,
            title: title,
            artistName: artistName,
            albumTitle: albumTitle,
            artworkURL: artworkURL,
            kind: kind,
            capturedAt: now,
            session: session
        )
        context.insert(capture)
        session?.lastActivityAt = now
        try context.save()
        return capture
    }

    /// When this track was last captured, by `songKey`, across every witnessed kind.
    ///
    /// Don't filter this to radio: on-demand songs would never dedupe, and the 10-second poll
    /// would write a new row each time. Imports are excluded because they're dated when
    /// found, so a recent import would suppress a real play.
    public func lastCaptureDate(songKey: String) throws -> Date? {
        let imported = CaptureKind.imported.rawValue
        var descriptor = FetchDescriptor<Capture>(
            predicate: #Predicate { $0.songKey == songKey && $0.kindRawValue != imported },
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.capturedAt
    }

    /// This device's open session for this station, starting one if the policy says to.
    ///
    /// Only this device's sessions are considered (see ``Session/deviceID``). Another device
    /// listening at the same time has its own open session, which isn't a station change or
    /// a silence here.
    @discardableResult
    public func openSession(
        stationName: String?,
        policy: SessionPolicy = .default,
        now: Date = .now,
        deviceID: String = DeviceIdentity.current
    ) throws -> Session {
        var descriptor = Self.openSessions(deviceID: deviceID)
        descriptor.fetchLimit = 1
        let open = try context.fetch(descriptor).first

        // Compared on the same key stations are matched on, so an open session whose station
        // row is spelled differently from what the player reports isn't a station change.
        let decision = policy.decide(
            openSessionStation: open?.station.map { Self.stationKey($0.name) },
            openSessionLastActivity: open?.lastActivityAt,
            observedStation: stationName.map(Self.stationKey),
            now: now
        )

        if decision == .current, let open {
            open.lastActivityAt = now
            // A session from before sessions had a device is this device's once it's
            // extended here, so another device stops treating it as its own.
            if open.deviceID == nil { open.deviceID = deviceID }
            // Name a session that started before we knew the station, or whose station was
            // merged away on another device before this session's link to it had synced.
            if open.station == nil, stationName != nil {
                open.station = try station(named: stationName, now: now)
            }
            return open
        }

        // Close at the last activity, not now, so the silence doesn't count as listening.
        open?.endedAt = open?.lastActivityAt

        let session = Session(
            startedAt: now,
            station: try station(named: stationName, now: now),
            deviceID: deviceID
        )
        context.insert(session)
        return session
    }

    /// The station row for a name, creating one if there isn't one.
    ///
    /// Matched on ``stationKey(_:)``, the key ``mergeDuplicateStations()`` groups on, and the
    /// oldest match wins, as it does there. An exact-name match made a new row whenever the
    /// player's spelling differed from the stored one, which the next merge deleted again,
    /// every session.
    private func station(named name: String?, now: Date) throws -> Station? {
        guard let name else { return nil }
        let key = Self.stationKey(name)
        // Station names can't be folded in a predicate. There are only as many rows as
        // stations the user has listened to, so matching in memory is cheap.
        let descriptor = FetchDescriptor<Station>(
            sortBy: [SortDescriptor(\.firstSeenAt), SortDescriptor(\.name)]
        )
        if let existing = try context.fetch(descriptor).first(where: { Self.stationKey($0.name) == key }) {
            existing.lastSeenAt = max(existing.lastSeenAt, now)
            return existing
        }
        let station = Station(name: name, firstSeenAt: now)
        context.insert(station)
        return station
    }

    /// Open sessions belonging to this device, newest first. Sessions with no device predate
    /// the field and count as this device's, so one left open by an older build still closes.
    static func openSessions(deviceID: String) -> FetchDescriptor<Session> {
        let device: String? = deviceID
        return FetchDescriptor<Session>(
            predicate: #Predicate {
                $0.endedAt == nil && ($0.deviceID == nil || $0.deviceID == device)
            },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
    }

    /// Closes this device's open sessions that have gone quiet, at their `lastActivityAt`.
    /// Without this, the last session stays open after the music stops.
    ///
    /// Another device's session is left alone: its lack of activity *here* says nothing,
    /// since that device extends it, not this one.
    @discardableResult
    public func closeStaleSessions(
        policy: SessionPolicy = .default,
        now: Date = .now,
        deviceID: String = DeviceIdentity.current
    ) throws -> [Session] {
        let open = try context.fetch(Self.openSessions(deviceID: deviceID))
        let stale = open.filter { now.timeIntervalSince($0.lastActivityAt) >= policy.silenceTimeout }
        guard !stale.isEmpty else { return [] }
        for session in stale { session.endedAt = session.lastActivityAt }
        try context.save()
        return stale
    }

    /// This device's open session, if it has one.
    public func currentOpenSession(deviceID: String = DeviceIdentity.current) throws -> Session? {
        var descriptor = Self.openSessions(deviceID: deviceID)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Sessions from the last `days` days, newest first, for the Mac menu bar.
    public static func recentSessions(days: Int = 7, now: Date = .now) -> FetchDescriptor<Session> {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? .distantPast
        return FetchDescriptor<Session>(
            predicate: #Predicate { $0.startedAt >= cutoff },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
    }

    /// Inserts a capture. Called inside the synchronous decide-and-insert transaction.
    @discardableResult
    public func insertCapture(
        songKey: String,
        catalogSongID: String?,
        observation: NowPlayingObservation,
        kind: CaptureKind = .radio,
        session: Session?,
        now: Date = .now
    ) throws -> Capture {
        let capture = Capture(
            songID: catalogSongID ?? "",
            songKey: songKey,
            title: observation.title,
            artistName: observation.artistName,
            albumTitle: observation.albumTitle,
            artworkURL: observation.artworkURL,
            kind: kind,
            capturedAt: now,
            // Apple Music or Your Music, so the two can be counted apart.
            source: PlaySource(observation: observation),
            session: session
        )
        context.insert(capture)
        session?.lastActivityAt = now
        try context.save()
        return capture
    }

    /// Rows with a catalog ID but no artwork.
    public static func missingArtwork(limit: Int = 50) -> FetchDescriptor<Capture> {
        var descriptor = FetchDescriptor<Capture>(
            predicate: #Predicate { !$0.songID.isEmpty && $0.artworkURL == nil },
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// Rows with no catalog ID yet (macOS, before the search runs).
    ///
    /// Every kind but Last.fm's, not just radio: artwork is looked up by ID, so on-demand
    /// rows need one too. The playlist write checks the kind, not the ID. A Last.fm history
    /// can be a hundred thousand plays, and searching the catalog for each would hold up
    /// every playlist write behind it; those rows keep Last.fm's cover.
    ///
    /// One batch, oldest first, so a backlog is searched a drain at a time rather than all at
    /// once, which held up every playlist write behind it.
    public static func awaitingCatalogID(limit: Int = catalogSearchBatch) -> FetchDescriptor<Capture> {
        let maxAttempts = maxCatalogLookupAttempts
        let lastFM = CaptureKind.lastFM.rawValue
        var descriptor = FetchDescriptor<Capture>(
            predicate: #Predicate {
                $0.songID.isEmpty && $0.catalogLookupAttempts < maxAttempts
                    && $0.kindRawValue != lastFM
            },
            sortBy: [SortDescriptor(\.capturedAt, order: .forward)]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// How many rows one drain searches the catalog for.
    public static let catalogSearchBatch = 25

    private func mostRecentCaptureDate(songID: String, kind: CaptureKind) throws -> Date? {
        let raw = kind.rawValue
        var descriptor = FetchDescriptor<Capture>(
            predicate: #Predicate { $0.songID == songID && $0.kindRawValue == raw },
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.capturedAt
    }

    // MARK: - Queries

    /// Every capture, whatever the source. Use this for showing listening history;
    /// ``radioCaptures(since:limit:)`` is for the playlist and play-back.
    public nonisolated static func allCaptures(
        since: Date? = nil,
        limit: Int? = nil
    ) -> FetchDescriptor<Capture> {
        let cutoff = since ?? .distantPast
        var descriptor = FetchDescriptor<Capture>(
            predicate: #Predicate { $0.capturedAt >= cutoff },
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
        if let limit { descriptor.fetchLimit = limit }
        return descriptor
    }

    /// Radio rows only, for the playlist and play-back.
    public static func radioCaptures(
        since: Date? = nil,
        limit: Int? = nil
    ) -> FetchDescriptor<Capture> {
        let radio = CaptureKind.radio.rawValue
        // `#Predicate` can't come from an `if` expression, so `.distantPast` means no cutoff.
        let cutoff = since ?? .distantPast
        var descriptor = FetchDescriptor<Capture>(
            predicate: #Predicate { $0.kindRawValue == radio && $0.capturedAt >= cutoff },
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
        if let limit { descriptor.fetchLimit = limit }
        return descriptor
    }

    /// What "Play back today" would queue, in play order.
    ///
    /// Both the Today widget's Up Next and ``PlaybackController`` use this, so they always
    /// agree.
    public func playBackQueue(now: Date = .now, calendar: Calendar = .current) throws -> [Capture] {
        let captures = try context.fetch(Self.radioCaptures(since: calendar.startOfDay(for: now)))
        return PlaybackSelection.todaysUnplayed(from: captures, now: now, calendar: calendar)
    }

    /// The most recent row for one song, so a display can show what's playing.
    public static func mostRecentCapture(title: String, artistName: String) -> FetchDescriptor<Capture> {
        var descriptor = FetchDescriptor<Capture>(
            predicate: #Predicate { $0.title == title && $0.artistName == artistName },
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    /// Rows still owed a playlist write, oldest first, skipping ones that failed too often.
    ///
    /// Only this device's rows. A row synced from the iPhone may still have
    /// `needsPlaylistWrite` set, and writing it here too would add the song twice.
    public static func pendingPlaylistWrites(
        deviceID: String = DeviceIdentity.current
    ) -> FetchDescriptor<Capture> {
        let maxAttempts = maxPlaylistWriteAttempts
        return FetchDescriptor<Capture>(
            predicate: #Predicate {
                $0.needsPlaylistWrite
                    && $0.playlistWriteAttempts < maxAttempts
                    && $0.capturedByDeviceID == deviceID
            },
            sortBy: [SortDescriptor(\.capturedAt, order: .forward)]
        )
    }

    /// Writes songs read out of Apple's recently-played list.
    ///
    /// Dated now, since Apple's list has no timestamps (see ``HistoryImport``), and inserted
    /// oldest first so the order is right.
    ///
    /// `lookback` is how far back a song counts as already known. A song played again days
    /// later should be a new row.
    @discardableResult
    public func importPlayedSongs(
        _ songs: [PlayedSong],
        lookback: TimeInterval = 24 * 60 * 60,
        settings: CaptureSettings = CaptureSettings(),
        now: Date = .now
    ) throws -> Int {
        guard !songs.isEmpty else { return 0 }

        // Apple's list keeps songs for days. Only what's above the part matching last time's
        // list can be new; otherwise yesterday's songs were imported again at every launch.
        let keys = songs.map { HistoryImport.key(title: $0.title, artistName: $0.artistName) }
        let fresh = Array(songs[..<HistoryImport.unseenCount(in: keys, previous: settings.recentlyPlayedAnchor)])

        let cutoff = now.addingTimeInterval(-lookback)
        let recent = try context.fetch(TracksStore.allCaptures(since: cutoff))
        var known = Set(recent.map {
            HistoryImport.key(title: $0.title, artistName: $0.artistName)
        })
        // Don't bring back songs the user removed, or ones Tracks’ player skipped: Apple
        // lists a song the moment it starts. A song forgotten a while ago that turns up again
        // was played again.
        let forgotten = settings.forgottenSongs
        let forgottenDates = settings.forgottenSongDates
        known.formUnion(forgotten.filter {
            CaptureSettings.isForgotten(
                $0, playedAt: now, forgotten: forgotten, dates: forgottenDates, grace: PassedOverSongs.memory
            )
        })
        known.formUnion(settings.passedOverSongs.keys(since: cutoff))

        // The anchor moves only once this list has been dealt with. It used to move before
        // the fetch and save, so a save that failed marked the new songs as seen and the
        // next import skipped them for good.
        let new = HistoryImport.newSongs(in: fresh, known: known)
        guard !new.isEmpty else {
            settings.recentlyPlayedAnchor = keys
            return 0
        }

        var inserted: [Capture] = []
        for song in new {
            let capture = Capture(
                songID: song.songID,
                // The catalog ID, same as iOS uses for a witnessed play.
                songKey: song.songID,
                title: song.title,
                artistName: song.artistName,
                albumTitle: song.albumTitle,
                artworkURL: ArtworkURL.loadable(song.artworkURL),
                kind: .imported,
                capturedAt: now
            )
            context.insert(capture)
            inserted.append(capture)
        }
        do {
            try context.save()
        } catch {
            // Take these back out so an unrelated later save doesn't write them: the anchor
            // hasn't moved, so the next import offers them again.
            for capture in inserted { context.delete(capture) }
            throw error
        }
        settings.recentlyPlayedAnchor = keys
        return new.count
    }

    /// Writes plays read from the connected Last.fm account. See ``LastFMHistory``.
    ///
    /// Dated when they played, marked as already scrobbled so they're never sent back, and
    /// skipped when the store already has the play (``LastFMHistory/newPlays(in:known:forgotten:policy:)``).
    /// Only the rows near the page's dates are read, so a long history costs the same per
    /// page as a short one.
    ///
    /// - Returns: how many rows were written.
    @discardableResult
    public func importScrobbles(
        _ scrobbles: [ScrobbledTrack],
        settings: CaptureSettings = CaptureSettings()
    ) throws -> Int {
        guard let earliest = scrobbles.map(\.playedAt).min(),
              let latest = scrobbles.map(\.playedAt).max()
        else { return 0 }

        let policy = settings.dedupePolicy
        // An import from Recently Played can be dated up to a day after the play it's a copy of.
        let reach = max(policy.window, policy.importWindow)
        let from = earliest.addingTimeInterval(-reach)
        let to = latest.addingTimeInterval(reach)
        let nearby = try context.fetch(FetchDescriptor<Capture>(
            predicate: #Predicate { $0.capturedAt >= from && $0.capturedAt <= to }
        ))
        let known = nearby.map {
            LastFMHistory.KnownPlay(
                key: HistoryImport.key(title: $0.title, artistName: $0.artistName),
                playedAt: $0.capturedAt,
                kind: $0.kind
            )
        }
        // Scrobbles carry their real dates, so only plays from before the song was forgotten
        // stay out.
        let forgotten = settings.forgottenSongs
        let forgottenDates = settings.forgottenSongDates
        let wanted = scrobbles.filter {
            !CaptureSettings.isForgotten(
                HistoryImport.key(title: $0.title, artistName: $0.artistName),
                playedAt: $0.playedAt, forgotten: forgotten, dates: forgottenDates
            )
        }
        let new = LastFMHistory.newPlays(in: wanted, known: known, forgotten: [], policy: policy)
        guard !new.isEmpty else { return 0 }

        var inserted: [Capture] = []
        for scrobble in new {
            let capture = Capture(
                songID: "",
                // The same shape as a Mac capture's key, which has no catalog ID either.
                songKey: "\(scrobble.title)\u{1F}\(scrobble.artistName)",
                title: scrobble.title,
                artistName: scrobble.artistName,
                albumTitle: scrobble.albumTitle,
                artworkURL: scrobble.artworkURL,
                kind: .lastFM,
                capturedAt: scrobble.playedAt
            )
            // Already on Last.fm. When it got there isn't in the response; when it played is
            // the closest, and it keeps the row out of the scrobble queue on every device.
            capture.scrobbledAt = scrobble.playedAt
            context.insert(capture)
            inserted.append(capture)
        }
        do {
            try context.save()
        } catch {
            // Out again, so an unrelated later save doesn't write them. The progress hasn't
            // moved, so the next run reads this page again.
            for capture in inserted { context.delete(capture) }
            throw error
        }
        return new.count
    }

    /// ``forgetSong(title:artistName:settings:)``, finding the song's plays through
    /// ``historyReader`` rather than the store.
    ///
    /// The store can't fold names the way songs are matched, so for a name that isn't plain
    /// ASCII the synchronous version reads every play on the main actor. The reader already
    /// knows which plays belong to each song.
    @discardableResult
    public func forgetSong(
        title: String,
        artistName: String,
        settings: CaptureSettings = CaptureSettings()
    ) async throws -> Int {
        let identity = HistoryImport.key(title: title, artistName: artistName)
        let ids = try await historyReader.captureIDs(ofSong: identity)
        // Checked again, in case a play was renamed since the reader looked.
        let rows = existingCaptures(ids).values.filter {
            HistoryImport.key(title: $0.title, artistName: $0.artistName) == identity
        }
        for row in rows { context.delete(row) }
        settings.noteForgotten(identity)
        if !rows.isEmpty { try context.save() }
        return rows.count
    }

    /// Deletes every row for a song (matched on title and artist) and adds it to
    /// `forgottenSongs`, so the next import doesn't bring it back from Apple's list.
    @discardableResult
    public func forgetSong(
        title: String,
        artistName: String,
        settings: CaptureSettings = CaptureSettings()
    ) throws -> Int {
        let identity = HistoryImport.key(title: title, artistName: artistName)
        let rows = try context.fetch(Self.possibleMatches(title: title, artistName: artistName)).filter {
            HistoryImport.key(title: $0.title, artistName: $0.artistName) == identity
        }
        for row in rows { context.delete(row) }
        settings.noteForgotten(identity)
        if !rows.isEmpty { try context.save() }
        return rows.count
    }

    /// Rows that might be this song, for narrowing before the exact match on
    /// ``HistoryImport/key(title:artistName:)``.
    ///
    /// A predicate can't fold the way that key does, but for plain ASCII names folding is
    /// only case, and a case- and diacritic-insensitive contains finds every row whose folded
    /// name is equal ("Café" still contains "cafe"). Anything else, or a name that trims to
    /// nothing, reads every row, as before, rather than risk leaving one behind.
    static func possibleMatches(title: String, artistName: String) -> FetchDescriptor<Capture> {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPlain = { (value: String) in
            !value.isEmpty && value.unicodeScalars.allSatisfy { $0.isASCII }
        }
        guard isPlain(trimmedTitle), isPlain(trimmedArtist) else { return allCaptures() }
        return FetchDescriptor<Capture>(
            predicate: #Predicate {
                $0.title.localizedStandardContains(trimmedTitle)
                    && $0.artistName.localizedStandardContains(trimmedArtist)
            }
        )
    }

    /// Deletes a single play. It stays on Last.fm if it was already scrobbled, since
    /// Last.fm has no public API for removing one.
    public func deletePlay(_ capture: Capture) throws {
        context.delete(capture)
        try context.save()
    }

    // MARK: - Sync reconciliation

    /// Folds duplicate stations into one.
    ///
    /// Each device creates its own `Station` row, and CloudKit has no unique constraints to
    /// prevent it. Matched on a normalised name, keeping the oldest row, so every device
    /// reaches the same result on its own copy.
    @discardableResult
    public func mergeDuplicateStations() throws -> Int {
        let stations = try context.fetch(FetchDescriptor<Station>())
        var groups: [String: [Station]] = [:]
        for station in stations where !Self.stationKey(station.name).isEmpty {
            groups[Self.stationKey(station.name), default: []].append(station)
        }

        var merged = 0
        for group in groups.values where group.count > 1 {
            let ordered = group.sorted { ($0.firstSeenAt, $0.name) < ($1.firstSeenAt, $1.name) }
            guard let survivor = ordered.first else { continue }
            // Two exact copies (Motif's history brought over on two devices at once) can't be
            // told apart, so each device could keep a different one and delete the other's,
            // leaving neither. Both stay.
            if ordered.count > 1, (ordered[1].firstSeenAt, ordered[1].name) == (survivor.firstSeenAt, survivor.name) {
                continue
            }

            for duplicate in ordered.dropFirst() {
                // Move the sessions this device knows about. Any it doesn't are left without
                // a station when the deletion reaches the device that has them, rather than
                // deleted with it (see `Station.sessions`).
                for session in duplicate.sessions ?? [] { session.station = survivor }

                survivor.catalogID = survivor.catalogID ?? duplicate.catalogID
                survivor.artworkURL = survivor.artworkURL ?? duplicate.artworkURL
                survivor.firstSeenAt = min(survivor.firstSeenAt, duplicate.firstSeenAt)
                survivor.lastSeenAt = max(survivor.lastSeenAt, duplicate.lastSeenAt)

                context.delete(duplicate)
                merged += 1
            }
        }

        if merged > 0 { try context.save() }
        return merged
    }

    /// Folds captures of the same play made on two devices.
    ///
    /// Local dedupe can't catch these: the other device's row arrives through iCloud seconds
    /// later, and the iPhone's system player often reports what the Mac is playing. The keys
    /// differ too (iOS uses the catalog ID, macOS title and artist).
    ///
    /// Matched on title and artist within the dedupe window. Outside it, the same song is a
    /// real second play.
    ///
    /// Every device runs this on its own copy and the deletions sync, so it must pick the
    /// same row to keep whatever order rows were fetched or arrived in. If two devices each
    /// kept a different one, each would delete the row the other kept and the play would be
    /// gone from both. See ``isPreferredSurvivor(_:over:)``.
    @discardableResult
    public func mergeDuplicateCaptures(policy: DedupePolicy = CaptureSettings().dedupePolicy) throws -> Int {
        // Every kind, since an import and a witnessed row are a common pair. Grouped on title
        // and artist because IDs differ across sources (see `HistoryImport.key`).
        let captures = try context.fetch(TracksStore.allCaptures())
        var groups: [String: [Capture]] = [:]
        for capture in captures {
            let identity = HistoryImport.key(title: capture.title, artistName: capture.artistName)
            groups[identity, default: []].append(capture)
        }
        let merged = mergePlays(in: groups.values, policy: policy)
        if merged > 0 { try context.save() }
        return merged
    }

    /// ``mergeDuplicateCaptures(policy:)`` without reading every capture on the main actor.
    ///
    /// ``historyReader`` finds, in the background, the songs with plays close enough to
    /// merge, and only those songs' plays are fetched and merged here, by the same rules. In a
    /// long history the full merge took seconds, and it runs after every batch from iCloud.
    @discardableResult
    public func mergeDuplicatePlays(policy: DedupePolicy = CaptureSettings().dedupePolicy) async throws -> Int {
        let groups = try await historyReader.duplicatePlayGroups(policy: policy)
        guard !groups.isEmpty else { return 0 }

        let rows = existingCaptures(groups.flatMap { $0 })
        var songs: [[Capture]] = []
        for ids in groups {
            let plays = ids.compactMap { rows[$0] }
            // Only a song the reader and the store agree on. If a play is gone, or has been
            // renamed into another song, since the reader looked, part of the song would be
            // merged on its own, and devices would disagree on what to keep. The next merge
            // sees it whole.
            guard plays.count == ids.count,
                  let identity = plays.first.map({ HistoryImport.key(title: $0.title, artistName: $0.artistName) }),
                  plays.allSatisfy({ HistoryImport.key(title: $0.title, artistName: $0.artistName) == identity })
            else { continue }
            songs.append(plays)
        }
        let merged = mergePlays(in: songs, policy: policy)
        if merged > 0 { try context.save() }
        return merged
    }

    /// Merges the plays of each song, given every play of the song. Doesn't save.
    private func mergePlays(in groups: some Sequence<[Capture]>, policy: DedupePolicy) -> Int {
        var merged = 0
        for group in groups where group.count > 1 {
            var remaining = group
            // Again over what's left until nothing changes, so a second call finds nothing.
            // One pass can leave two survivors inside each other's window: a cluster that
            // starts with an import keeps a witnessed row up to a window later than its start,
            // which can put it within reach of the next cluster's survivor.
            while true {
                var kept: [Capture] = []
                var mergedThisPass = 0
                for cluster in Self.playClusters(remaining, policy: policy) {
                    let ranked = cluster.sorted(by: Self.isPreferredSurvivor)
                    let survivor = ranked[0]
                    // Exact copies, such as Motif's history brought over on two devices at
                    // once, tie, and each device would keep its own and delete the other's.
                    // Leaving a duplicate is better than losing the play everywhere.
                    if ranked.count > 1, !Self.isPreferredSurvivor(survivor, over: ranked[1]) {
                        kept.append(contentsOf: ranked)
                        continue
                    }
                    for duplicate in ranked.dropFirst() {
                        Self.absorb(duplicate, into: survivor)
                        context.delete(duplicate)
                        mergedThisPass += 1
                    }
                    kept.append(survivor)
                }
                merged += mergedThisPass
                remaining = kept
                if mergedThisPass == 0 || remaining.count < 2 { break }
            }
        }
        return merged
    }

    /// Splits one song's rows into plays.
    ///
    /// Oldest first, each row joins the current play if it falls inside the window measured
    /// from that play's *first* row, and otherwise starts the next play. The window is
    /// measured from the first row and not from the row that will survive, because the
    /// survivor can be a later row: measuring from it would stretch a play each time a
    /// witnessed row turned up after an import, and where plays split would depend on which
    /// rows had synced.
    ///
    /// `DedupePolicy.mergeWindow(earlier:later:)` depends only on the later row's kind, so
    /// rows that tie on time give the same plays in any order.
    static func playClusters(_ rows: [Capture], policy: DedupePolicy) -> [[Capture]] {
        let ordered = rows.sorted {
            $0.capturedAt != $1.capturedAt
                ? $0.capturedAt < $1.capturedAt
                : isPreferredSurvivor($0, over: $1)
        }
        var clusters: [[Capture]] = []
        var current: [Capture] = []
        for row in ordered {
            // `ordered` is oldest first, so the anchor is always the earlier of the two. An
            // import following a play gets a wide window, because it is dated when it was
            // found rather than when it played. Everything else gets the ordinary one.
            //
            // This used to skip the window check entirely whenever either row was an import,
            // which merged plays any distance apart: four plays of one song a month apart
            // collapsed into one, and an old import swallowed a real play recorded weeks
            // later. The deletions synced, so both devices lost them.
            if let anchor = current.first {
                let window = policy.mergeWindow(earlier: anchor.kind, later: row.kind)
                if row.capturedAt.timeIntervalSince(anchor.capturedAt) < window {
                    current.append(row)
                    continue
                }
                clusters.append(current)
            }
            current = [row]
        }
        if !current.isEmpty { clusters.append(current) }
        return clusters
    }

    /// Which of two rows of one play to keep. A strict total order on what every device's
    /// copy of a row agrees on, so every device keeps the same one.
    ///
    /// A witnessed row beats an import, however they're dated. It used to be the oldest row
    /// that survived, and an import is dated when it was found, often before the witnessed
    /// row of the same play synced in, so the import won and the witnessed row was deleted,
    /// taking its kind, its session, a pending playlist write and its scrobble state with it.
    /// Radio beats on demand for the same reason: only radio rows go to the playlist and
    /// belong to a session, so it's the row with more to lose.
    ///
    /// Among rows of the same kind the oldest wins, then fields that only break exact ties.
    static func isPreferredSurvivor(_ lhs: Capture, over rhs: Capture) -> Bool {
        let lhsRank = survivorRank(lhs.kind), rhsRank = survivorRank(rhs.kind)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        if lhs.capturedAt != rhs.capturedAt { return lhs.capturedAt < rhs.capturedAt }
        if lhs.kindRawValue != rhs.kindRawValue { return lhs.kindRawValue < rhs.kindRawValue }
        if lhs.capturedByDeviceID != rhs.capturedByDeviceID {
            return lhs.capturedByDeviceID < rhs.capturedByDeviceID
        }
        if lhs.songKey != rhs.songKey { return lhs.songKey < rhs.songKey }
        if lhs.songID != rhs.songID { return lhs.songID < rhs.songID }
        return (lhs.addedToPlaylistAt != nil ? 0 : 1, lhs.scrobbledAt != nil ? 0 : 1)
            < (rhs.addedToPlaylistAt != nil ? 0 : 1, rhs.scrobbledAt != nil ? 0 : 1)
    }

    private static func survivorRank(_ kind: CaptureKind) -> Int {
        switch kind {
        case .radio: 0
        case .onDemand: 1
        // Before an import, because its time is when the song played.
        case .lastFM: 2
        case .imported: 3
        }
    }

    /// Moves what a duplicate knew onto the row that stays, so deleting it loses nothing.
    private static func absorb(_ duplicate: Capture, into survivor: Capture) {
        // Check artwork is loadable, not just present: it may be a `musicKit://` URL (see
        // `ArtworkURL`).
        if !isLoadableArtwork(survivor.artworkURL) {
            survivor.artworkURL = duplicate.artworkURL
        }
        if survivor.albumTitle == nil { survivor.albumTitle = duplicate.albumTitle }
        if survivor.playedBackAt == nil { survivor.playedBackAt = duplicate.playedBackAt }
        if survivor.session == nil { survivor.session = duplicate.session }

        // Already in the playlist, so don't write it again.
        if duplicate.addedToPlaylistAt != nil {
            survivor.addedToPlaylistAt = survivor.addedToPlaylistAt ?? duplicate.addedToPlaylistAt
        }
        if survivor.addedToPlaylistAt != nil { survivor.needsPlaylistWrite = false }

        // Already on Last.fm, so the survivor's device mustn't send it again.
        if survivor.scrobbledAt == nil { survivor.scrobbledAt = duplicate.scrobbledAt }
    }

    /// See ``ArtworkURL``.
    public static func isLoadableArtwork(_ urlString: String?) -> Bool {
        ArtworkURL.isLoadable(urlString)
    }

    /// Rows that have a cover address of any kind.
    ///
    /// Whether it loads is decided by parsing the URL, which a predicate can't do, but most
    /// rows from before a cover was found have none and never need reading.
    static func capturesWithArtwork() -> FetchDescriptor<Capture> {
        FetchDescriptor<Capture>(
            predicate: #Predicate { $0.artworkURL != nil },
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
    }

    /// Forgets artwork nothing can load, so the ordinary backfill fetches it again.
    ///
    /// Runs on the main actor after every synced change, so the store narrows it to covers
    /// that don't start `http://` or `https://`. Reading every row with a cover took two
    /// seconds in a long history, and nearly all of them load.
    @discardableResult
    public func clearUnloadableArtwork() throws -> Int {
        let rows = try context.fetch(Self.possiblyUnloadableArtwork())
            .filter { !Self.isLoadableArtwork($0.artworkURL) }
        guard !rows.isEmpty else { return 0 }
        for row in rows { row.artworkURL = nil }
        try context.save()
        return rows.count
    }

    /// Rows whose cover address doesn't start with a lowercase `http://` or `https://`: a
    /// superset of those ``ArtworkURL`` can't load, which also parses scheme case.
    static func possiblyUnloadableArtwork() -> FetchDescriptor<Capture> {
        FetchDescriptor<Capture>(
            predicate: #Predicate { capture in
                if let url = capture.artworkURL {
                    !url.starts(with: "http://") && !url.starts(with: "https://")
                } else {
                    false
                }
            }
        )
    }

    /// Every cover address in the history, once each. What ``ArtworkRepair`` probes.
    ///
    /// From ``historyReader``: reading every row with a cover took seconds on the main actor.
    public func artworkURLs() async throws -> [String] {
        try await historyReader.artworkURLs()
    }

    /// Forgets the given covers wherever they appear, leaving the rows for the backfill to
    /// fill in again.
    ///
    /// - Returns: how many rows were cleared, which is usually more than `urls.count` since
    ///   an album's songs share a cover.
    @discardableResult
    public func clearArtwork(urls: Set<String>) throws -> Int {
        guard !urls.isEmpty else { return 0 }
        // Only the rows with these covers, a few hundred addresses per query.
        let all = Array(urls)
        var rows: [Capture] = []
        for start in stride(from: 0, to: all.count, by: 500) {
            let chunk = Array(all[start..<min(start + 500, all.count)])
            rows += try context.fetch(FetchDescriptor<Capture>(
                predicate: #Predicate { capture in
                    if let url = capture.artworkURL {
                        chunk.contains(url)
                    } else {
                        false
                    }
                }
            ))
        }
        guard !rows.isEmpty else { return 0 }
        for row in rows { row.artworkURL = nil }
        try context.save()
        return rows.count
    }

    /// Case- and accent-insensitive station name.
    nonisolated static func stationKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    // MARK: - Scrobbling

    public static let maxScrobbleAttempts = 3

    /// Songs owed a scrobble, oldest first.
    ///
    /// Only this device's rows, or every device would scrobble every synced row. Imports are
    /// left out unless `includingImported`, since they're dated when found (see
    /// ``HistoryImport``).
    public static func pendingScrobbles(
        deviceID: String = DeviceIdentity.current,
        includingImported: Bool,
        limit: Int = 50
    ) -> FetchDescriptor<Capture> {
        let maxAttempts = maxScrobbleAttempts
        let imported = CaptureKind.imported.rawValue
        var descriptor = FetchDescriptor<Capture>(
            predicate: #Predicate {
                $0.scrobbledAt == nil
                    && $0.scrobbleAttempts < maxAttempts
                    && $0.capturedByDeviceID == deviceID
                    && (includingImported || $0.kindRawValue != imported)
            },
            sortBy: [SortDescriptor(\.capturedAt, order: .forward)]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }

    // MARK: - Retention

    /// Trims on-demand rows.
    ///
    /// Not called. On-demand rows used to be disposable; they're listening history now.
    public func pruneOnDemandCaptures(keeping limit: Int = 500) throws {
        let onDemand = CaptureKind.onDemand.rawValue
        let descriptor = FetchDescriptor<Capture>(
            predicate: #Predicate { $0.kindRawValue == onDemand },
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
        let rows = try context.fetch(descriptor)
        guard rows.count > limit else { return }
        for row in rows[limit...] { context.delete(row) }
        try context.save()
    }
}
