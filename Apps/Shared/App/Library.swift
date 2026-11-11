import SwiftUI
import Combine
import SwiftData
import Observation
import TracksCore
import TracksMusic

/// The listening history as plain values, kept up to date as the store changes.
///
/// Screens read `history` and compute what they need from it; the `revision` changes on
/// every rebuild so they know when to recompute.
///
/// Nothing here reads the store on the main actor. ``ListeningHistoryReader`` reads it in
/// the background, and after the first read only what changed, so a long history doesn't
/// freeze the app after every song.
@MainActor
@Observable
final class Library {
    private(set) var history = ListeningHistory([])
    private(set) var sessions: [SessionStat] = []
    private(set) var revision = 0
    /// False until the first rebuild, so screens can tell "loading" from "empty".
    private(set) var isLoaded = false

    @ObservationIgnored private let artistArtwork = ArtistArtworkCache()
    @ObservationIgnored private let songMetadataCache = SongMetadataCache()
    /// Read from disk once, in the background before the first rebuild is shown, then kept in
    /// step with each round of lookups.
    @ObservationIgnored private var songMetadata: [String: SongMetadata] = [:]
    @ObservationIgnored private var hasLoadedSongMetadata = false
    @ObservationIgnored private var artistLookup: Task<Void, Never>?
    @ObservationIgnored private var metadataLookup: Task<Void, Never>?
    /// False in a demo launch. Checked after every request too.
    @ObservationIgnored private var looksUpCatalog = false
    /// Whether lookups have found something ``history`` doesn't show yet.
    @ObservationIgnored private var hasUnpublishedLookups = false
    @ObservationIgnored private var lastLookupPublish = ContinuousClock.now

    @ObservationIgnored private var reader: ListeningHistoryReader?
    /// The reader's version this library last showed.
    @ObservationIgnored private var version: Int?
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    /// A change arrived while a refresh was already running, so another is owed.
    @ObservationIgnored private var needsAnotherRefresh = false
    /// Failed attempts at the first read, which is tried again a few times on its own.
    @ObservationIgnored private var failedFirstReads = 0

    private static let lookupPublishInterval: Duration = .seconds(2)

    /// How long to let a burst of saves settle before reading. A Mac capture saves the row,
    /// then its id and cover, then the playlist write and scrobble, within seconds.
    private static let settle: Duration = .milliseconds(400)

    /// How many times a failed first read is tried again before waiting for the store to change.
    private static let firstReadRetries = 5

    /// Sample data brings its own genres and years: its made-up songs mustn't reach Apple
    /// Music or the caches.
    private static let sampleMetadata = DemoLibrary.songMetadata()

    /// Starts following `store`. Call once, before any view observes the library.
    ///
    /// - Parameter looksUpCatalog: false for sample data, whose made-up artists and songs
    ///   mustn't reach Apple Music or the caches.
    func connect(to store: TracksStore, looksUpCatalog: Bool) {
        guard reader == nil else { return }
        self.looksUpCatalog = looksUpCatalog
        if !looksUpCatalog { CatalogCredits.shared.update(from: Self.sampleMetadata) }
        // The store's own reader, which the merge shares, so the history is read in full once.
        reader = store.historyReader
        refresh()
    }

    /// Brings ``history`` up to date with the store. Cheap to call often: calls that arrive
    /// while a read is running are folded into one more read after it.
    func refresh() {
        guard let reader else { return }
        guard refreshing == nil else {
            needsAnotherRefresh = true
            return
        }
        refreshing = Task {
            defer { refreshing = nil }
            repeat {
                needsAnotherRefresh = false
                // The first load goes straight away; later ones wait out the burst.
                if isLoaded { try? await Task.sleep(for: Self.settle) }
                do {
                    if let (change, version) = try await reader.changes(after: version) {
                        if looksUpCatalog, !hasLoadedSongMetadata {
                            songMetadata = await Self.loadSongMetadata(from: songMetadataCache)
                            hasLoadedSongMetadata = true
                            lookupsGeneration += 1
                            CatalogCredits.shared.update(from: songMetadata)
                        }
                        let generation = lookupsGeneration
                        let (artwork, metadata) = lookups
                        // Each new song is a step on from what's shown, taken off the main
                        // actor. Rebuilding from every play, after every song, cost a long
                        // history a sort of all of it, and the main actor the lookups' pass
                        // over every play as well.
                        let base = publishedLookups == generation ? history : nil
                        let (rebuilt, sessions, reached) = try await Self.build(
                            change, version: version, onto: base, reader: reader,
                            artwork: artwork, metadata: metadata
                        )
                        self.version = reached
                        publish(rebuilt, sessions: sessions, lookups: generation)
                    }
                    if !isLoaded {
                        isLoaded = true
                        revision += 1
                    }
                } catch {
                    // Keep showing what was there; the next change reads again. Until a first
                    // read works there's nothing to show, and calling it loaded would greet
                    // someone with years of listening as new, so that one is retried, backing off.
                    if !isLoaded, failedFirstReads < Self.firstReadRetries {
                        failedFirstReads += 1
                        try? await Task.sleep(for: .seconds(1 << failedFirstReads))
                        needsAnotherRefresh = true
                    }
                }
            } while needsAnotherRefresh
        }
    }

    /// What the lookups have found, as ``history`` shows it.
    private var lookups: (artwork: [String: String], metadata: [String: SongMetadata]) {
        (looksUpCatalog ? artistArtwork.urls : [:], looksUpCatalog ? songMetadata : Self.sampleMetadata)
    }

    /// Goes up whenever the lookups find something, so a rebuild knows whether what it
    /// started from still carries all of them.
    @ObservationIgnored private var lookupsGeneration = 0
    /// The ``lookupsGeneration`` that ``history`` carries.
    @ObservationIgnored private var publishedLookups = -1

    /// The history after `change`, off the main actor: the reader's steps taken from `base`
    /// where they can be, and otherwise everything sorted and estimated again, the costly
    /// part of a rebuild.
    ///
    /// - Parameter base: what's shown, when it carries these lookups; nil to start again.
    /// - Returns: the history, its sessions in order, and the reader's version they're at.
    @concurrent
    private nonisolated static func build(
        _ change: ListeningHistoryReader.Change,
        version: Int,
        onto base: ListeningHistory?,
        reader: ListeningHistoryReader,
        artwork: [String: String],
        metadata: [String: SongMetadata]
    ) async throws -> (ListeningHistory, [SessionStat], Int) {
        if case .steps(let steps, let sessions) = change, let next = base?.applying(steps) {
            return (next, sessions.sorted { $0.startedAt < $1.startedAt }, version)
        }
        let snapshot: ListeningHistoryReader.Snapshot
        var reached = version
        if case .everything(let everything) = change {
            snapshot = everything
        } else {
            // Asked for from the start, which always has an answer.
            guard let (everything, latest) = try await reader.snapshot(after: nil) else { throw CancellationError() }
            (snapshot, reached) = (everything, latest)
        }
        return (
            ListeningHistory(snapshot.captures, artistArtwork: artwork, songMetadata: metadata),
            snapshot.sessions.sorted { $0.startedAt < $1.startedAt },
            reached
        )
    }

    /// Lookups attached to `history` off the main actor: with years of plays, crediting them
    /// all again took tens of milliseconds there.
    @concurrent
    private nonisolated static func attach(
        _ history: ListeningHistory,
        artwork: [String: String],
        metadata: [String: SongMetadata]
    ) async -> ListeningHistory {
        history.with(artistArtwork: artwork, songMetadata: metadata)
    }

    /// Lets the history that's been replaced go in the background. A long one is hundreds of
    /// thousands of values to release, which was a few milliseconds on the main actor after
    /// every song.
    private static func retire(_ old: ListeningHistory) {
        Task.detached(priority: .background) {
            // Long enough for the main actor to have let go of its own reference first.
            try? await Task.sleep(for: .seconds(1))
            withExtendedLifetime(old) {}
        }
    }

    private func publish(_ rebuilt: ListeningHistory, sessions: [SessionStat], lookups generation: Int) {
        let old = history
        history = rebuilt
        Self.retire(old)
        publishedLookups = generation
        self.sessions = sessions
        // Lookups found while the rebuild ran aren't in it yet.
        hasUnpublishedLookups = generation != lookupsGeneration
        isLoaded = true
        revision += 1
        if looksUpCatalog {
            lookUpArtistArtwork()
            lookUpSongMetadata()
            publishLookups(force: true)
        }
    }

    /// Fetches pictures for artists that don't have one yet, most played first, and
    /// rebuilds as they arrive. A failed request records nothing, so the next update
    /// tries again.
    private func lookUpArtistArtwork() {
        guard artistLookup == nil else { return }
        artistLookup = Task {
            defer {
                artistLookup = nil
                publishLookups(force: true)
            }
            while looksUpCatalog {
                let requests = await Self.pendingArtists(in: history, lookedUp: artistArtwork.lookedUp)
                guard !requests.isEmpty,
                      let found = try? await CatalogLookup().artistArtworkURLs(for: requests),
                      looksUpCatalog
                else { return }

                artistArtwork.record(found: found, asked: requests.map(\.artistIdentity))
                // `pending` reads what's recorded, not what's published, so the next round
                // doesn't ask again for these.
                lookupsGeneration += 1
                hasUnpublishedLookups = true
                publishLookups(force: false)
            }
        }
    }

    /// Fetches genres and release years for songs that don't have them yet, most played
    /// first. Songs with an id go in batches of a couple of hundred; the few that need a
    /// search are limited per round, so the Summary fills in quickly and then keeps up with
    /// each new song. A failed request records nothing, so the next update tries again.
    private func lookUpSongMetadata() {
        guard metadataLookup == nil else { return }
        metadataLookup = Task {
            defer {
                metadataLookup = nil
                publishLookups(force: true)
            }
            while looksUpCatalog {
                let requests = await Self.pendingSongs(in: history, known: songMetadata)
                guard !requests.isEmpty,
                      let found = try? await CatalogLookup().songMetadata(for: requests),
                      looksUpCatalog
                else { return }

                songMetadata = await Self.record(
                    found: found,
                    asked: requests.map(\.songIdentity),
                    into: songMetadata,
                    cache: songMetadataCache
                )
                CatalogCredits.shared.update(from: songMetadata)
                lookupsGeneration += 1
                hasUnpublishedLookups = true
                publishLookups(force: false)
            }
        }
    }

    // Each of these walks every play, or writes the whole cache to disk, so they run off the
    // main actor.

    @concurrent
    private nonisolated static func pendingArtists(
        in history: ListeningHistory,
        lookedUp: Set<String>
    ) async -> [ArtistArtworkLookup.Request] {
        ArtistArtworkLookup.pending(in: history, lookedUp: lookedUp, limit: 25)
    }

    @concurrent
    private nonisolated static func pendingSongs(
        in history: ListeningHistory,
        known: [String: SongMetadata]
    ) async -> [SongMetadataLookup.Request] {
        SongMetadataLookup.pending(in: history, known: known, limit: 200, searchLimit: 20)
    }

    @concurrent
    private nonisolated static func loadSongMetadata(from cache: SongMetadataCache) async -> [String: SongMetadata] {
        cache.load()
    }

    @concurrent
    private nonisolated static func record(
        found: [String: SongMetadata],
        asked: [String],
        into existing: [String: SongMetadata],
        cache: SongMetadataCache
    ) async -> [String: SongMetadata] {
        cache.record(found: found, asked: asked, into: existing)
    }

    /// Puts what the lookups have found into ``history`` and bumps ``revision``, at most
    /// every ``lookupPublishInterval`` while they run and once more when they finish.
    ///
    /// A large library takes dozens of batches to fill in, and publishing each one made every
    /// screen recompute its statistics dozens of times over.
    private func publishLookups(force: Bool) {
        guard hasUnpublishedLookups, looksUpCatalog, attaching == nil else { return }
        let now = ContinuousClock.now
        guard force || now - lastLookupPublish >= Self.lookupPublishInterval else { return }
        lastLookupPublish = now
        attaching = Task {
            defer { attaching = nil }
            while hasUnpublishedLookups, looksUpCatalog {
                let (base, shown, generation) = (history, revision, lookupsGeneration)
                let (artwork, metadata) = lookups
                let attached = await Self.attach(base, artwork: artwork, metadata: metadata)
                // A rebuild landed meanwhile, with the lookups of its own: look again.
                guard revision == shown else { continue }
                history = attached
                Self.retire(base)
                publishedLookups = generation
                hasUnpublishedLookups = generation != lookupsGeneration
                lastLookupPublish = .now
                revision += 1
            }
        }
    }

    /// Attaching what the lookups found, under way.
    @ObservationIgnored private var attaching: Task<Void, Never>?

    /// Forces a recompute without new data, e.g. when the day changes and "this week" moves.
    func invalidate() {
        revision += 1
    }

    /// Starts the artist picture lookup again, after
    /// ``ArtistArtworkCache/forgetMissing()`` has put artists back in the queue. Repairing
    /// artwork doesn't always change a capture row, so it can't rely on the store's own
    /// updates to kick this off.
    func refreshArtistArtwork() {
        lookUpArtistArtwork()
    }
}

extension Capture {
    var stat: CaptureStat {
        CaptureStat(
            songKey: songKey,
            songID: songID,
            title: title,
            artistName: artistName,
            albumTitle: albumTitle,
            artworkURL: artworkURL,
            capturedAt: capturedAt,
            stationName: session?.station?.name,
            playedBackAt: playedBackAt,
            kind: kind
        )
    }
}

/// Remembers a value worked out in `body` until its key changes.
///
/// For derived data too costly to rebuild on every render, such as grouping or sorting the
/// whole history, that still has to come from the same pass as the query it's built from.
/// Copying it into `@State` from `onChange` would leave one render with rows the store has
/// already deleted. Not observable: filling it in doesn't invalidate the view.
@MainActor
final class Memo<Key: Equatable, Value> {
    private var cached: (key: Key, value: Value)?

    func value(for key: Key, compute: () -> Value) -> Value {
        if let cached, cached.key == key { return cached.value }
        let value = compute()
        cached = (key, value)
        return value
    }
}

extension View {
    /// Calls `action` after each save of `context`, and after each batch of synced changes
    /// has been folded in: the moments rows can change in place, which a query's count and
    /// ends don't show.
    func onStoreChange(of context: ModelContext, perform action: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave, object: context).receive(on: DispatchQueue.main)) { _ in
            action()
        }
        .onReceive(NotificationCenter.default.publisher(for: SyncReconciler.didReconcileNotification).receive(on: DispatchQueue.main)) { _ in
            action()
        }
    }
}
