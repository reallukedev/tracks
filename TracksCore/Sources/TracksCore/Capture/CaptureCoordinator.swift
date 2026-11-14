import Foundation
import SwiftData

/// The capture loop: observations in, rows and playlist writes out.
///
/// The store work happens in the store's ``HistoryWriter``, off the main actor. Observations
/// are taken in one at a time, so two of the same song (macOS polls every 10 seconds) can't
/// both pass the dedupe check. The slow work (catalog lookup, playlist write) happens
/// afterwards, from the saved row.
@MainActor
public final class CaptureCoordinator {
    private let store: TracksStore
    private let writer: HistoryWriter
    private let settings: CaptureSettings
    private let playlistWriter: any PlaylistWriter
    /// Catalog ids (macOS, where the notification has none), artwork, and the station's
    /// name when Tracks starts mid-station. Nil in tests that don't need it.
    private let catalogResolver: (any CatalogResolving)?
    private let sessionPolicy: SessionPolicy

    /// The most recent decision, for the UI and the probe to show.
    public private(set) var lastDecision: CaptureDecision?
    /// Station name learned from the last announcement, applied to subsequent captures.
    public private(set) var currentStationName: String?
    /// Whether we've already asked Apple which station is on. It's a network call, so once
    /// per station.
    private var hasAskedForStationName = false

    public init(
        store: TracksStore,
        settings: CaptureSettings = CaptureSettings(),
        playlistWriter: any PlaylistWriter,
        catalogResolver: (any CatalogResolving)? = nil,
        sessionPolicy: SessionPolicy = .default
    ) {
        self.store = store
        self.writer = store.writer
        self.settings = settings
        self.playlistWriter = playlistWriter
        self.catalogResolver = catalogResolver
        self.sessionPolicy = sessionPolicy
    }

    // MARK: - Ingest

    /// When the current song was first seen, for the share of it that must play.
    private var pendingKey: String?
    private var pendingSince: Date?

    /// Handles one observation. Returns the decision so callers can log it.
    ///
    /// - Parameter force: skip the minimum listening time. Used by the App Intent and the
    ///   Action Button.
    @discardableResult
    public func handle(
        _ observation: NowPlayingObservation,
        now: Date = .now,
        force: Bool = false
    ) async -> CaptureDecision {
        // Station announcements aren't captured, but they're where the station name comes from.
        if let station = observation.announcedStationName {
            currentStationName = station
            hasAskedForStationName = true
        } else if currentStationName == nil, !hasAskedForStationName {
            // The app started mid-station, so there was no announcement. Ask Apple.
            hasAskedForStationName = true
            currentStationName = try? await catalogResolver?.mostRecentStationName()
        }

        var observation = observation
        if observation.stationName == nil { observation.stationName = currentStationName }

        let policy = CapturePolicy(
            dedupe: settings.dedupePolicy,
            excludedStations: settings.excludedStations,
            forceCapture: settings.forceCapture,
            capturesOnDemand: settings.capturesOnDemand
        )

        let decision = await ingest(observation, policy: policy, now: now, force: force)
        lastDecision = decision

        // Drain on every observation, not just new captures, so a failed write is retried
        // within 10 seconds instead of waiting for the next song. Cheap when nothing is owed.
        // Not waited for: a drain can spend minutes on the catalog, and the observations
        // queued behind it would be handled late, with their listening clocks started late.
        startDrain()
        return decision
    }

    /// The observation being taken in, which the next one waits for.
    private var ingesting: Task<CaptureDecision, Never>?

    /// Takes observations in one at a time, in the order they arrived.
    ///
    /// The dedupe check and the insert are two trips to the writer, and a second observation
    /// of the same song let in between them would pass the same check and be kept twice.
    private func ingest(
        _ observation: NowPlayingObservation,
        policy: CapturePolicy,
        now: Date,
        force: Bool
    ) async -> CaptureDecision {
        let previous = ingesting
        let task = Task {
            _ = await previous?.value
            // Before the insert: this observation is also how long the last song kept playing.
            await followScrobbleWatch(observation, now: now)
            return await decideAndInsert(observation, policy: policy, now: now, force: force)
        }
        ingesting = task
        return await task.value
    }

    /// The transaction: reads the dedupe state and writes the row. Only ever one at a time
    /// (see ``ingest(_:policy:now:force:)``).
    private func decideAndInsert(
        _ observation: NowPlayingObservation,
        policy: CapturePolicy,
        now: Date,
        force: Bool
    ) async -> CaptureDecision {
        let songKey = observation.catalogSongID ?? Self.metadataKey(for: observation)
        let lastSeen = try? await writer.lastCaptureDate(songKey: songKey)
        let decision = policy.decide(observation, lastSeen: lastSeen, now: now)

        guard case .capture(let capturable) = decision else { return decision }

        // After the policy, which is pure: this needs state kept across observations.
        if let waiting = timeStillOwed(songKey: songKey, duration: observation.duration, now: now, force: force) {
            return .ignore(waiting)
        }

        let hold = scrobbleHold(songKey: songKey, duration: observation.duration, now: now)
        let new = HistoryWriter.NewCapture(
            songKey: songKey,
            catalogSongID: capturable.catalogSongID,
            observation: capturable.observation,
            kind: capturable.kind,
            // Only radio belongs to a session. On-demand plays mustn't extend one.
            session: capturable.kind == .radio
                ? .init(stationName: capturable.stationName, policy: sessionPolicy)
                : nil,
            now: now,
            scrobbleHold: hold?.reason
        )
        if let id = try? await writer.recordCapture(new) {
            scrobbleWatch = hold?.needs.map {
                ScrobbleWatch(id: id, songKey: songKey, needs: $0, played: hold?.played ?? 0, lastSeen: now, isPlaying: true)
            }
        }
        return decision
    }

    /// Nil once enough of the song has played, otherwise how much is left.
    ///
    /// The clock starts when a song is first seen and resets when a different one arrives.
    private func timeStillOwed(songKey: String, duration: TimeInterval?, now: Date, force: Bool) -> CaptureDecision.Reason? {
        // Kept even when nothing has to play first, for the scrobble watch.
        if pendingKey != songKey {
            pendingKey = songKey
            pendingSince = now
        }
        let minimum = settings.minimumListen(forDuration: duration)
        guard !force, minimum > 0 else { return nil }

        let playedFor = now.timeIntervalSince(pendingSince ?? now)
        guard playedFor < minimum else { return nil }
        return .tooShort(playedFor: playedFor, needs: minimum)
    }

    // MARK: - Scrobbling

    /// The latest play kept before it had played long enough for Last.fm, and how much of it
    /// has played since it was first seen.
    private struct ScrobbleWatch {
        let id: PersistentIdentifier
        let songKey: String
        let needs: TimeInterval
        var played: TimeInterval
        /// The last observation, and whether this song was playing at it.
        var lastSeen: Date
        var isPlaying: Bool
    }

    private var scrobbleWatch: ScrobbleWatch?
    /// Whether the first observation since launch has been checked for a play an earlier
    /// run was still watching.
    private var hasLookedForHeldPlay = false

    /// Whether a new play is held out of the scrobble queue until it has played long enough,
    /// by ``ScrobblePolicy``, and what the watch that lets it go needs. With a share of 0 every
    /// song is kept the moment it's seen, skips and jingles included, and each of those used
    /// to be scrobbled.
    ///
    /// - Returns: nil when the play can be scrobbled straight away. `needs` is nil when it
    ///   never can, being too short.
    private func scrobbleHold(
        songKey: String,
        duration: TimeInterval?,
        now: Date
    ) -> (reason: String, needs: TimeInterval?, played: TimeInterval)? {
        guard let needs = ScrobblePolicy().requiredPlayback(forDuration: duration) else {
            return (ScrobblePolicy.tooShortReason, nil, 0)
        }
        let played = pendingKey == songKey ? now.timeIntervalSince(pendingSince ?? now) : 0
        guard played < needs else { return nil }
        return (ScrobblePolicy.notPlayedEnoughReason, needs, played)
    }

    /// Counts the time since the last observation toward the watched play if it was
    /// playing, and lets it be scrobbled once that's enough. A different song playing ends
    /// the watch: whatever the play reached by then is all it gets.
    private func followScrobbleWatch(_ observation: NowPlayingObservation, now: Date) async {
        if !hasLookedForHeldPlay {
            hasLookedForHeldPlay = true
            if scrobbleWatch == nil { scrobbleWatch = await heldPlayStillPlaying(observation, now: now) }
        }
        guard var watch = scrobbleWatch else { return }
        if watch.isPlaying { watch.played += max(0, now.timeIntervalSince(watch.lastSeen)) }
        watch.lastSeen = now

        let isSameSong = observation.isIdentifiable
            && (observation.catalogSongID ?? Self.metadataKey(for: observation)) == watch.songKey
        watch.isPlaying = isSameSong && observation.playbackState == .playing

        if watch.played >= watch.needs {
            scrobbleWatch = nil
            await writer.updateCapture(watch.id) { $0.releaseForScrobbling() }
        } else if observation.isCapturable, !isSameSong {
            scrobbleWatch = nil
        } else {
            scrobbleWatch = watch
        }
    }

    /// The watch an earlier run left behind, when the song it held back is still playing.
    ///
    /// The watch lives in memory, so when iOS ended Tracks in the background while Music
    /// kept playing, the play stayed held for good and the song never scrobbled. Dedupe keeps
    /// the same song from being captured again, so nothing else would start a new watch.
    /// The time since it was kept counts as played, as long as that fits inside the song.
    private func heldPlayStillPlaying(_ observation: NowPlayingObservation, now: Date) async -> ScrobbleWatch? {
        guard observation.isCapturable,
              let needs = ScrobblePolicy().requiredPlayback(forDuration: observation.duration)
        else { return nil }
        let songKey = observation.catalogSongID ?? Self.metadataKey(for: observation)
        let held = try? await writer.read { context -> (id: PersistentIdentifier, capturedAt: Date)? in
            let deviceID = DeviceIdentity.current
            let imported = CaptureKind.imported.rawValue
            var descriptor = FetchDescriptor<Capture>(
                predicate: #Predicate {
                    $0.songKey == songKey && $0.capturedByDeviceID == deviceID && $0.kindRawValue != imported
                },
                sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
            )
            descriptor.fetchLimit = 1
            guard let capture = try context.fetch(descriptor).first,
                  capture.lastScrobbleError == ScrobblePolicy.notPlayedEnoughReason,
                  capture.isHeldFromScrobbling
            else { return nil }
            return (capture.persistentModelID, capture.capturedAt)
        }
        guard let held else { return nil }
        let elapsed = now.timeIntervalSince(held.capturedAt)
        let length = observation.duration.flatMap { $0 > 0 ? $0 : nil } ?? CaptureSettings.assumedSongLength
        guard elapsed >= 0, elapsed <= length else { return nil }
        return ScrobbleWatch(
            id: held.id,
            songKey: songKey,
            needs: needs,
            played: elapsed,
            lastSeen: now,
            isPlaying: true
        )
    }

    /// Identity for a track with no catalog ID yet (macOS, before the search runs).
    static func metadataKey(for observation: NowPlayingObservation) -> String {
        "\(observation.title)\u{1F}\(observation.artistName)".lowercased()
    }

    // MARK: - Resolution and playlist writes

    /// The drain in progress, which later callers wait on rather than starting their own.
    ///
    /// Launch, every observation, the Mac's poll and the housekeeping timer all drain, and a
    /// drain spends most of its time waiting on Apple with the rows it fetched. Two at once
    /// both wrote the same songs, so the playlist got them twice.
    private var runningDrain: Task<Void, Never>?
    /// Set when someone asked for a drain while one was running, so a capture made after the
    /// running drain fetched its rows still gets written without waiting for the next song.
    private var wantsAnotherDrain = false

    /// Leaves the Apple Music API alone for a while after writes fail for reasons that aren't
    /// any one song's fault.
    private(set) var writeBackoff = RetryBackoff()
    /// The same for catalog searches and artwork lookups, which otherwise went out on every
    /// ten-second poll while offline or without a token.
    private(set) var lookupBackoff = RetryBackoff()
    /// The clock, replaceable so tests can step past the backoff.
    var now: () -> Date = { .now }

    /// How long to leave a song the catalog had no cover for before asking about it again.
    /// Apple does add artwork to old releases, just not often.
    static let artworkMissRetryAfter: TimeInterval = 7 * 24 * 60 * 60
    /// The most songs remembered as having no cover, so the list, which goes into the query,
    /// can't grow without end. The ones due soonest are dropped first.
    static let artworkMissLimit = 2_000

    /// Resolves missing catalog IDs, backfills artwork, then writes to the playlist.
    /// Cheap when there's nothing to do.
    ///
    /// If a drain is already running this waits for it, and that drain takes one more look
    /// before it finishes.
    public func drainPendingWrites() async {
        await startDrain().value
    }

    /// Starts a drain, or asks the running one for one more look, without waiting for it.
    @discardableResult
    private func startDrain() -> Task<Void, Never> {
        if let runningDrain {
            wantsAnotherDrain = true
            return runningDrain
        }
        let task = Task {
            repeat {
                wantsAnotherDrain = false
                await drainOnce()
            } while wantsAnotherDrain
            // Cleared here rather than by the caller, with nothing in between that can
            // suspend, so a caller can't join a drain that has already finished looking.
            runningDrain = nil
        }
        runningDrain = task
        return task
    }

    private func drainOnce() async {
        await resolveMissingCatalogIDs()
        await backfillArtwork()
        guard settings.autoAddToPlaylist else { return }
        guard writeBackoff.allows(at: now()) else { return }

        // Saved first, so every row has the identity it will keep. Only identities are held
        // across the requests below: sync can merge a row away while one is out.
        store.saveMainContext()
        let writable = (try? await writer.read { context in
            try context.fetch(TracksStore.pendingPlaylistWrites())
                .filter { !$0.songID.isEmpty }
                .map(\.persistentModelID)
        }) ?? []
        guard !writable.isEmpty else { return }

        guard let playlistID = await ensurePlaylist() else { return }

        // A service failure not yet put down to its song. An outage and a song Apple chokes
        // on look the same from one request, so the next write decides: if it goes through,
        // the service is up and that song gets the attempt; if it fails too, it's an outage
        // and neither does.
        var unexplained: (id: PersistentIdentifier, message: String)?

        writing: for id in writable {
            // Looked up again each time: an earlier write's wait is long enough for a merge
            // to delete this row, or to fold it into one already in the playlist.
            let songID = await writer.read { context in
                TracksStore.existingCaptures([id], in: context)[id].flatMap {
                    $0.needsPlaylistWrite && !$0.songID.isEmpty ? $0.songID : nil
                }
            }
            guard let songID else { continue }

            do {
                try await playlistWriter.addSongs(ids: [songID], toPlaylist: playlistID)
                writeBackoff.reset()
                let added = now()
                await writer.updateCapture(id) {
                    $0.needsPlaylistWrite = false
                    $0.addedToPlaylistAt = added
                    $0.lastPlaylistWriteError = nil
                }
                if let earlier = unexplained {
                    unexplained = nil
                    await chargeWriteAttempt(earlier.id, message: earlier.message)
                }
            } catch {
                let message = String(describing: error)
                switch Self.blame(for: error) {
                case .song:
                    // A deleted playlist also answers 404, and charging the song for it would
                    // drop every pending song one after another. Forget the playlist instead,
                    // keep the rows, and the next drain creates a new one.
                    if Self.isNotFound(error),
                       (try? await playlistWriter.playlistExists(playlistID)) == false {
                        forgetPlaylist()
                        await writer.updateCapture(id) { $0.lastPlaylistWriteError = message }
                        break writing
                    }
                    // Won't succeed on retry, so stop trying this row.
                    await chargeWriteAttempt(id, message: message, stopsWriting: true)
                case .service:
                    await writer.updateCapture(id) { $0.lastPlaylistWriteError = message }
                    if unexplained == nil {
                        unexplained = (id, message)
                    } else {
                        // Two in a row. The rows stay as they were and the queue waits.
                        unexplained = nil
                        writeBackoff.recordFailure(at: now())
                        break writing
                    }
                case .setup:
                    // No token or no subscription fails every write the same way, and none
                    // of it is the song's doing. Kept pending for when it's sorted out.
                    await writer.updateCapture(id) { $0.lastPlaylistWriteError = message }
                    writeBackoff.recordFailure(at: now())
                    break writing
                }
            }
        }
        // The last write failed and nothing came after to tell why. Assume the service, so
        // nothing is charged, but wait before asking again.
        if unexplained != nil { writeBackoff.recordFailure(at: now()) }
    }

    /// Whose fault a failed playlist write was, which decides what the queue does next.
    enum WriteFailure: Equatable {
        /// The song or the request for it. Charged to the row.
        case song
        /// The network or Apple's servers. Retried later, for nothing.
        case service
        /// The token or the subscription. Every write would fail, so the queue waits.
        case setup
    }

    static func blame(for error: any Error) -> WriteFailure {
        // Anything the writer didn't classify came from below it: a URL error, a
        // cancellation. Neither says anything about the song.
        guard let writeError = error as? PlaylistWriteError else { return .service }
        return switch writeError {
        case .permanent: .song
        case .transient: .service
        case .notConfigured, .notSubscribed: .setup
        }
    }

    static func isNotFound(_ error: any Error) -> Bool {
        if case .permanent(let status, _) = error as? PlaylistWriteError { return status == 404 }
        return false
    }

    /// The user deleted the playlist.
    private func forgetPlaylist() {
        settings.playlistID = nil
    }

    private func chargeWriteAttempt(_ id: PersistentIdentifier, message: String, stopsWriting: Bool = false) async {
        await writer.updateCapture(id) {
            $0.playlistWriteAttempts += 1
            $0.lastPlaylistWriteError = message
            if stopsWriting { $0.needsPlaylistWrite = false }
        }
    }

    /// macOS has no catalog ID until we search for one.
    private func resolveMissingCatalogIDs() async {
        guard let catalogResolver, lookupBackoff.allows(at: now()) else { return }
        store.saveMainContext()
        let unresolved = (try? await writer.read { context in
            try context.fetch(TracksStore.awaitingCatalogID()).map {
                (
                    id: $0.persistentModelID,
                    query: CatalogQuery(
                        title: $0.title,
                        artistName: $0.artistName,
                        duration: nil,
                        albumTitle: $0.albumTitle
                    )
                )
            }
        }) ?? []
        guard !unresolved.isEmpty else { return }

        var answers: [(id: PersistentIdentifier, match: CatalogCandidate?)] = []
        var searchFailure: (id: PersistentIdentifier, message: String)?
        for row in unresolved {
            do {
                answers.append((row.id, try await catalogResolver.resolve(row.query)))
            } catch {
                // The search itself failed: no network, or MusicKit can't get a developer
                // token (a new App ID can take a while to get one). That says nothing about
                // this song, so it isn't an attempt, and every other row would fail the same
                // way. The next drain tries again. Kept on the row so the probe can show why.
                searchFailure = (row.id, "Catalog search failed: \(error)")
                lookupBackoff.recordFailure(at: now())
                break
            }
            lookupBackoff.reset()
        }

        let (found, failure) = (answers, searchFailure)
        _ = try? await writer.write { context in
            let rows = TracksStore.existingCaptures(found.map(\.id) + [failure?.id].compactMap { $0 }, in: context)
            if let failure { rows[failure.id]?.lastPlaylistWriteError = failure.message }
            for answer in found {
                // Gone, or given an ID some other way, while the search was out.
                guard let capture = rows[answer.id], capture.songID.isEmpty else { continue }
                guard let match = answer.match else {
                    capture.catalogLookupAttempts += 1
                    // No confident match. Give up after a few tries.
                    if capture.catalogLookupAttempts >= maxCatalogLookupAttempts {
                        capture.needsPlaylistWrite = false
                        capture.lastPlaylistWriteError = "No confident catalog match"
                    }
                    continue
                }
                capture.songID = match.id
                capture.lastPlaylistWriteError = nil
                if capture.artworkURL == nil { capture.artworkURL = match.artworkURL }
                if capture.albumTitle == nil { capture.albumTitle = match.albumTitle }
            }
        }
    }

    /// Fills in artwork for rows that have a catalog ID but no cover, in one request.
    ///
    /// Songs the catalog comes back with no cover for are set aside in
    /// ``CaptureSettings/artworkMisses`` for ``artworkMissRetryAfter``. Before that, the newest
    /// fifty rows without a cover were asked about on every pass, and when the catalog had
    /// none for them no older row was ever reached.
    ///
    /// - Returns: how many songs were asked about and how many rows got a cover, or nil when
    ///   there was nothing to ask or the request failed.
    @discardableResult
    private func backfillArtwork() async -> (asked: Int, filled: Int)? {
        guard let catalogResolver, lookupBackoff.allows(at: now()) else { return nil }
        let excluded = currentArtworkMisses()
        store.saveMainContext()
        let excludedSongIDs = Array(excluded.keys)
        let missing = (try? await writer.read { context in
            try context.fetch(TracksStore.missingArtwork(excludingSongIDs: excludedSongIDs))
                .map { (id: $0.persistentModelID, songID: $0.songID) }
        }) ?? []
        guard !missing.isEmpty else { return nil }

        let songIDs = Array(Set(missing.map(\.songID)))
        guard let urls = try? await catalogResolver.artworkURLs(forSongIDs: songIDs) else {
            lookupBackoff.recordFailure(at: now())
            return nil
        }

        let filled = (try? await writer.write { context in
            let rows = TracksStore.existingCaptures(missing.map(\.id), in: context)
            var filled = 0
            for row in missing {
                guard let capture = rows[row.id],
                      capture.artworkURL == nil,
                      capture.songID == row.songID,
                      let url = urls[row.songID]
                else { continue }
                capture.artworkURL = url
                filled += 1
            }
            return filled
        }) ?? 0

        let unanswered = Set(songIDs).subtracting(urls.keys)
        if !unanswered.isEmpty {
            let retryAt = now().addingTimeInterval(Self.artworkMissRetryAfter)
            var misses = excluded
            for songID in unanswered { misses[songID] = retryAt }
            if misses.count > Self.artworkMissLimit {
                misses = Dictionary(
                    uniqueKeysWithValues: misses.sorted { $0.value > $1.value }.prefix(Self.artworkMissLimit).map { ($0.key, $0.value) }
                )
            }
            settings.artworkMisses = misses
        }
        return (songIDs.count, filled)
    }

    /// The remembered misses that haven't come due, forgetting the ones that have.
    private func currentArtworkMisses() -> [String: Date] {
        let stored = settings.artworkMisses
        let now = now()
        let current = stored.filter { $0.value > now }
        if current.count != stored.count { settings.artworkMisses = current }
        return current
    }

    /// Fetches covers for every row missing one, not just the first batch.
    ///
    /// ``drainPendingWrites()`` does a batch per pass, which keeps up with live listening but
    /// would take a long time to fill in a history after ``TracksStore/clearArtwork(urls:)``.
    ///
    /// Asked for from Settings, so the songs set aside as having no cover are asked about
    /// again too.
    ///
    /// - Returns: how many covers were found.
    @discardableResult
    public func backfillAllArtwork() async -> Int {
        settings.artworkMisses = [:]
        // Asked for by the person, so it tries now rather than waiting out an earlier failure.
        lookupBackoff.reset()
        var total = 0
        // Every pass either fills its rows or sets their songs aside, so the next reaches
        // different ones, and the loop ends when nothing is left or a request fails. The
        // bound is only a backstop, at fifty rows a pass.
        for _ in 0..<2_000 {
            guard let pass = await backfillArtwork(), pass.asked > 0 else { break }
            total += pass.filled
        }
        return total
    }

    /// Creates the playlist on first use and remembers its ID.
    ///
    /// One already in the library with the same name is adopted instead. A new device often
    /// drains before iCloud has brought the synced ID down, and a create whose answer was lost
    /// still made the playlist; either way a second one would split the history.
    private func ensurePlaylist() async -> String? {
        if let existing = settings.playlistID { return existing }
        let name = settings.playlistName
        do {
            let id: String
            if let found = try await playlistWriter.existingPlaylist(named: name) {
                id = found
            } else {
                id = try await playlistWriter.createPlaylist(
                    name: name,
                    description: "Songs Tracks captured from Apple Music Radio."
                )
            }
            // Synced down while the request was out: that one wins.
            if let synced = settings.playlistID { return synced }
            settings.playlistID = id
            return id
        } catch {
            writeBackoff.recordFailure(at: now())
            return nil
        }
    }
}

/// Stop searching for a song the catalog will not confidently identify.
public let maxCatalogLookupAttempts = 3
