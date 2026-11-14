import Foundation
import Observation
import SwiftData
import TracksCore
import TracksMusic

/// Owns the one `NowPlayingSource` and feeds it to the coordinator.
///
/// Keep this a single instance. On macOS a second observer means duplicate notifications
/// and duplicate captures.
@MainActor
@Observable
public final class CaptureService {
    public private(set) var isRunning = false
    /// Whether you've paused history: nothing you play is kept, not even what Apple Music's
    /// Recently Played shows afterwards, until you resume. Kept on this device, and across
    /// launches, since a pause that quietly ended when the app next opened wouldn't be one.
    public private(set) var isPaused = UserDefaults.standard.bool(forKey: CaptureService.pausedKey)

    /// Where the pause is kept. Not a synced setting: pausing one device leaves the others.
    public nonisolated static let pausedKey = "historyPaused"
    /// Set from a resume until Recently Played has been read, as the songs it shows then
    /// include ones played while paused.
    nonisolated static let anchorOwedKey = "historyResumeAnchorOwed"

    /// Whether history is paused, for code that doesn't hold the service: the player telling a
    /// music server what played, say.
    public nonisolated static var isHistoryPaused: Bool {
        UserDefaults.standard.bool(forKey: pausedKey)
    }
    public private(set) var lastCapture: CaptureSnapshot?
    public private(set) var lastDecision: CaptureDecision?
    public private(set) var currentStation: String?

    /// Whether music is audible, as of the last poll. The status item reads this because
    /// `NowPlayingMonitor` only polls while the popup is open.
    ///
    /// Nil until the first poll returns, so launch doesn't briefly blank the status item.
    public private(set) var isSomethingPlaying: Bool?

    /// What is audible right now, captured or not. A song plays from its first second but
    /// only becomes ``lastCapture`` once it passes the minimum listening time.
    public private(set) var nowPlaying: NowPlaying?
    /// The session in progress, if any. Nil once silence closes it.
    public private(set) var openSession: Session?

    private let store: TracksStore
    /// The store's reads for what's shown, off the main actor.
    private let reads: CaptureReads
    /// Goes up with each observation recorded, so an older read can't show over a newer one.
    private var displayGeneration = 0
    /// The song ``nowPlaying`` is about to show once its read lands.
    private var pendingNowPlayingKey: String?
    private let settings: CaptureSettings
    private let scrobbler: ScrobbleService
    private let coordinator: CaptureCoordinator
    private let source: any NowPlayingSource
    private var pump: Task<Void, Never>?
    private var housekeeping: Task<Void, Never>?
    private var poll: Task<Void, Never>?
    private var recheck: Task<Void, Never>?
    private var artworkLookup: Task<Void, Never>?
    /// The Last.fm send started after an observation, and whether another was asked for
    /// while it ran.
    private var scrobbling: Task<Void, Never>?
    private var scrobbleAgain = false
    /// The song artwork was last looked up for, so a failed lookup is not retried every poll.
    private var artworkLookupKey: String?
    /// What that lookup found. Kept separately because `nowPlaying` is rebuilt from each
    /// poll, and the observation carries no artwork.
    private var artworkLookupResult: String?

    /// How often to ask Music.app what is playing. Each poll is one Apple event.
    private static let pollInterval: TimeInterval = 10

    /// How long a run of observations has to send what's owed to Last.fm once.
    private static let scrobbleSettle: Duration = .seconds(1)

    /// How long a station has to be stopped before the day's captures are played back.
    /// Long enough to skip gaps between tracks, short enough that the listener is likely
    /// still there to hear it.
    private static let autoPlaybackDelay: TimeInterval = 120

    /// Called when a station has stopped and the day still has unplayed captures. Set by
    /// the app, which owns the player.
    public var autoPlayback: (@MainActor () async -> Void)?

    /// When the music stopped, or nil while something is playing.
    private var silentSince: Date?
    /// One play-back per listening session. Cleared when a station starts again.
    private var hasAutoPlayedThisSession = false

    public init(store: TracksStore, settings: CaptureSettings = CaptureSettings()) {
        self.store = store
        self.reads = CaptureReads(container: store.container)
        self.settings = settings
        self.scrobbler = ScrobbleService(store: store, settings: settings)

        #if os(macOS)
        // Music.app, Tracks’ own Apple Music player, and its player for your own music. Nothing
        // stops Music.app playing alongside Tracks’, so it's only heard while Tracks’ is quiet.
        self.source = MergedNowPlayingSource([
            DeferringNowPlayingSource(PlayerInfoSource(), deferringWhile: { TracksPlayerContext.isPlaying }),
            ApplicationMusicPlayerSource(),
            PushedNowPlayingSource.yourMusic,
        ])
        #else
        // The Music app, Tracks’ own Apple Music player on the Play tab, and its player for your
        // own music. Only one plays at a time.
        self.source = MergedNowPlayingSource([SystemMusicPlayerSource(), ApplicationMusicPlayerSource(), PushedNowPlayingSource.yourMusic])
        #endif

        // Both platforms need it, so an iPhone manages on its own. macOS searches for every
        // song's id. iOS reads the id off the queue entry, but a radio song's cover there is
        // a `musicKit://` URL that never loads, so its rows get their artwork from here.
        self.coordinator = CaptureCoordinator(
            store: store,
            settings: settings,
            playlistWriter: MusicKitPlaylistWriter(),
            catalogResolver: CatalogLookup()
        )
    }

    /// The service for ``TracksStore/shared()``, one per process for the app and its intents
    /// alike: a second would drain the same scrobbles and playlist writes beside the first
    /// and send each twice.
    public static func shared() throws -> CaptureService {
        if let sharedService { return sharedService }
        let service = CaptureService(store: try TracksStore.shared())
        sharedService = service
        return service
    }

    private static var sharedService: CaptureService?

    /// Retries whatever is outstanding: unresolved ids, missing artwork, failed playlist
    /// writes, unsent scrobbles. Called at launch.
    public func catchUp() async {
        await closeStaleSessions()
        await mergeSyncedDuplicates()
        await importRecentlyPlayed()
        await coordinator.drainPendingWrites()
        await scrobbler.drain()
    }

    /// Stops keeping what you play until ``resume()``, even across launches.
    public func pause() {
        isPaused = true
        UserDefaults.standard.set(true, forKey: Self.pausedKey)
        stop()
    }

    /// Keeps what you play again. Songs played while paused stay out: Apple Music's
    /// Recently Played, as it stands now, becomes the list new songs are counted from.
    public func resume() async {
        isPaused = false
        UserDefaults.standard.set(false, forKey: Self.pausedKey)
        // Owed until the list is read, here or by the next import, so a resume offline
        // doesn't let the paused songs in later.
        UserDefaults.standard.set(true, forKey: Self.anchorOwedKey)
        if let songs = try? await RecentlyPlayedSource().recentlyPlayed(limit: 30) {
            settings.recentlyPlayedAnchor = songs.map { HistoryImport.key(title: $0.title, artistName: $0.artistName) }
            UserDefaults.standard.set(false, forKey: Self.anchorOwedKey)
        }
        // Paused again while the list was read.
        guard !isPaused else { return }
        start()
    }

    /// Picks up listening that happened while Tracks wasn't running, from Apple's
    /// recently-played list. See ``HistoryImport`` for what an import can and can't record.
    @discardableResult
    public func importRecentlyPlayed() async -> Int {
        guard settings.importsRecentlyPlayed, !isPaused else { return 0 }
        guard let songs = try? await RecentlyPlayedSource().recentlyPlayed(limit: 30), !isPaused else { return 0 }
        // A resume that couldn't read the list: the songs played while paused can't be told
        // from later ones, so this list only becomes where new songs are counted from.
        if UserDefaults.standard.bool(forKey: Self.anchorOwedKey) {
            settings.recentlyPlayedAnchor = songs.map { HistoryImport.key(title: $0.title, artistName: $0.artistName) }
            UserDefaults.standard.set(false, forKey: Self.anchorOwedKey)
            return 0
        }
        let imported = (try? store.importPlayedSongs(songs)) ?? 0
        if imported > 0, lastCapture == nil {
            let latest = await reads.read(latest: true, song: nil, deviceID: DeviceIdentity.current).latest
            if lastCapture == nil { lastCapture = latest }
        }
        return imported
    }

    /// Finds covers that no longer load and fetches them again.
    ///
    /// Two kinds go wrong: `musicKit://` addresses that were never loadable (see
    /// ``ArtworkURL``), spotted without a network, and `https` ones that have since been taken
    /// down, which only a request can tell. Both are forgotten, and then the ordinary backfill
    /// asks the catalog for them again. Artists Apple Music had no picture for are asked about
    /// again too, since an early lookup can have missed one.
    ///
    /// Driven from Settings, so it reports what it did rather than working silently.
    public func repairArtwork() async -> ArtworkRepairReport {
        var report = ArtworkRepairReport()

        // Cheap and offline, so it happens whether or not the probes get through.
        var forget = Set<String>()
        let urls = (try? await store.artworkURLs()) ?? []
        report.checked = urls.count
        forget.formUnion(ArtworkRepair.unloadable(among: urls))

        let reachable = urls.filter { !forget.contains($0) }
        forget.formUnion(await ArtworkRepair.broken(
            among: reachable,
            probe: ArtworkRepair.networkProbe()
        ))

        report.cleared = (try? store.clearArtwork(urls: forget)) ?? 0
        // Reads and writes the whole file.
        await Self.forgetMissingArtistArtwork()
        report.restored = await coordinator.backfillAllArtwork()
        return report
    }

    @concurrent
    private nonisolated static func forgetMissingArtistArtwork() async {
        ArtistArtworkCache().forgetMissing()
    }

    /// Folds together the duplicate rows iCloud sync produces. Runs at launch and on the
    /// housekeeping timer, since synced rows can arrive at any time.
    ///
    /// Not gated on sync being on: duplicates outlive sync being turned off. The merge is
    /// idempotent, and cheap however long the history: the duplicates are found in the
    /// background.
    private func mergeSyncedDuplicates() async {
        _ = await SyncReconciler.merge(store)
    }

    /// Ends sessions that have gone quiet. Silence produces no observations, so this runs on
    /// a timer as well as at launch.
    private func closeStaleSessions() async {
        _ = try? await store.closeStaleSessions()
        showOpenSession(await reads.read(latest: false, song: nil, deviceID: DeviceIdentity.current).openSession)
    }

    public func start() {
        guard !isRunning, !isPaused else { return }
        isRunning = true
        // Seed from the store so the menu bar has something to show before the next capture.
        if lastCapture == nil {
            Task { [weak self, reads] in
                let latest = await reads.read(latest: true, song: nil, deviceID: DeviceIdentity.current).latest
                if let self, self.lastCapture == nil { self.lastCapture = latest }
            }
        }
        // A new stream every time: the one before was finished by `stop()`, so resuming
        // after a pause has to iterate this one, not the old one.
        let observations = source.start()
        // Well inside the fifteen minute silence timeout, and the query is cheap.
        housekeeping = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.closeStaleSessions()
                await self?.mergeSyncedDuplicates()
                // Catches scrobbles queued before a Last.fm account was connected mid-session.
                await self?.scrobbler.drain()
            }
        }
        pump = Task { [coordinator] in
            for await observation in observations {
                if Task.isCancelled { return }
                let decision = await coordinator.handle(observation)
                await self.record(decision, observation: observation)
                self.scrobbleSoon()
            }
        }
        #if os(macOS)
        startPolling()
        #endif
    }

    #if os(macOS)
    /// Polls Music.app on a timer as well as listening for notifications.
    ///
    /// A radio station changing track doesn't reliably post `com.apple.Music.playerInfo`;
    /// in one eleven minute session only two songs were captured. Scripting reports the
    /// live track correctly, so the poll is the fallback and the notification stays for
    /// speed. Polling the same song again is harmless: it has the same dedupe key and is
    /// rejected before the store.
    ///
    /// Each poll reads whichever player is making sound, as ``currentObservation()`` picks it,
    /// so Tracks’ own player playing counts as music and never as silence to fill.
    private func startPolling() {
        poll = Task { [weak self] in
            var isFirst = true
            while !Task.isCancelled {
                // Poll straight away on launch.
                if isFirst {
                    isFirst = false
                } else {
                    try? await Task.sleep(for: .seconds(Self.pollInterval))
                }
                guard let self, self.isRunning else { return }

                let observation = await self.currentObservation()
                let isPlaying = observation?.playbackState == .playing
                // Tracks’ own player is music too, even before its entry resolves into a song
                // and gives an observation. Auto-playback must never start over it.
                guard isPlaying || TracksPlayerContext.isPlaying else {
                    if self.isSomethingPlaying != false { self.isSomethingPlaying = false }
                    if self.nowPlaying != nil { self.nowPlaying = nil }
                    // Nothing plays, so a read still on its way mustn't show a song again.
                    if self.pendingNowPlayingKey != nil {
                        self.pendingNowPlayingKey = nil
                        self.displayGeneration &+= 1
                    }
                    if self.silentSince == nil { self.silentSince = .now }
                    await self.considerAutoPlayback()
                    continue
                }

                if self.isSomethingPlaying != true { self.isSomethingPlaying = true }
                self.silentSince = nil
                self.hasAutoPlayedThisSession = false

                guard let observation, isPlaying else { continue }
                let decision = await self.coordinator.handle(observation)
                await self.record(decision, observation: observation)
                self.scrobbleSoon()
            }
        }
    }
    /// Plays the day's captures back once the station has stopped, so radio listens count
    /// as plays in Apple Music.
    ///
    /// Only fires when someone is at the machine (unknown presence counts as absent), once
    /// per listening session, and when nothing else is playing (the caller checks that).
    /// Playing into an empty room would log plays nobody heard.
    private func considerAutoPlayback() async {
        guard settings.autoPlayBack, !hasAutoPlayedThisSession else { return }
        guard let silentSince,
              Date.now.timeIntervalSince(silentSince) >= Self.autoPlaybackDelay
        else { return }
        guard UserPresence.isPresent() else { return }

        let unplayed = (try? store.playBackQueue()) ?? []
        guard !unplayed.isEmpty else { return }

        hasAutoPlayedThisSession = true
        await autoPlayback?()
    }
    #endif

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        // Nothing is being watched, so don't claim to know what's playing.
        isSomethingPlaying = nil
        nowPlaying = nil
        pendingNowPlayingKey = nil
        // A read still on its way mustn't show a song again.
        displayGeneration &+= 1
        pump?.cancel()
        pump = nil
        housekeeping?.cancel()
        housekeeping = nil
        poll?.cancel()
        poll = nil
        recheck?.cancel()
        recheck = nil
        artworkLookup?.cancel()
        artworkLookup = nil
        artworkLookupKey = nil
        artworkLookupResult = nil
        source.stop()
    }

    /// Checks again once a song has played long enough to count.
    ///
    /// iOS only observes on a queue change, so without this a song waiting out its minimum
    /// listening time would never be captured.
    private func scheduleRecheck(after remaining: TimeInterval) {
        recheck?.cancel()
        recheck = Task { [weak self] in
            // Slightly past due, so rounding can't make it fire early and reschedule.
            try? await Task.sleep(for: .seconds(max(0.5, remaining) + 0.5))
            guard let self, !Task.isCancelled, self.isRunning else { return }
            guard let observation = await self.currentObservation(),
                  observation.playbackState == .playing
            else { return }
            let decision = await self.coordinator.handle(observation)
            await self.record(decision, observation: observation)
            self.scrobbleSoon()
        }
    }

    /// Sends what's owed to Last.fm without holding up the next observation: a slow request
    /// would otherwise start the next song's listening clock late. After every observation,
    /// not only a capture, since one can release a play held until enough of it was heard.
    private func scrobbleSoon() {
        guard scrobbling == nil else {
            scrobbleAgain = true
            return
        }
        scrobbling = Task { [weak self] in
            // Observations come in runs (the notification, the poll, a recheck), and each drain
            // saves and reads the store on the main actor: one drain answers the run.
            try? await Task.sleep(for: Self.scrobbleSettle)
            repeat {
                self?.scrobbleAgain = false
                await self?.scrobbler.drain()
            } while self?.scrobbleAgain == true
            self?.scrobbling = nil
        }
    }

    /// - Parameter observation: what was playing when this was decided, so the display
    ///   follows the music rather than the writes.
    private func record(_ decision: CaptureDecision, observation: NowPlayingObservation? = nil) async {
        lastDecision = decision
        if case .ignore(.tooShort(let playedFor, let needs)) = decision {
            scheduleRecheck(after: needs - playedFor)
        }
        // Each poll and notification lands here, mostly with nothing new: setting the same
        // values again would redraw everything that reads them.
        let station = coordinator.currentStationName
        if station != currentStation { currentStation = station }

        let isCapture = if case .capture = decision { true } else { false }
        let playing = observation.flatMap { $0.playbackState == .playing && $0.isIdentifiable ? $0 : nil }
        let shows = playing.flatMap { $0.announcedStationName == nil ? $0 : nil }
        // Only an observation that changes what's shown supersedes a read on its way: Tracks'
        // player starting pauses the Music app, and that pause mustn't drop Tracks' song.
        if let shows {
            pendingNowPlayingKey = Self.songKey(for: shows)
            displayGeneration &+= 1
        } else if clearNowPlaying(for: observation) {
            displayGeneration &+= 1
        }
        let generation = displayGeneration
        let read = await reads.read(
            latest: isCapture,
            song: playing.map { ($0.title, $0.artistName) },
            deviceID: DeviceIdentity.current
        )
        // A capture's row is the newest whichever read lands last.
        if isCapture, let latest = read.latest,
           latest.capturedAt >= lastCapture?.capturedAt ?? .distantPast {
            setLastCapture(latest)
        }
        // A newer observation's read is on its way, and what it shows wins.
        guard generation == displayGeneration else { return }
        showOpenSession(read.openSession, refresh: isCapture)
        if let shows {
            pendingNowPlayingKey = nil
            updateNowPlaying(shows, existing: read.song)
        }
        // Skipping back to an already captured song should still update `lastCapture`.
        if !isCapture, playing != nil, let existing = read.song { setLastCapture(existing) }
    }

    private func setLastCapture(_ snapshot: CaptureSnapshot?) {
        if snapshot != lastCapture { lastCapture = snapshot }
    }

    /// The session read in the background, as the main context's own object.
    ///
    /// - Parameter refresh: fetch it again even if it's the one shown. A capture extends the
    ///   session in the store's writer, and the main context's copy keeps its old song count
    ///   and station until it's fetched.
    private func showOpenSession(_ id: PersistentIdentifier?, refresh: Bool = false) {
        guard let id else {
            if openSession != nil { openSession = nil }
            return
        }
        guard refresh || id != openSession?.persistentModelID else { return }
        var descriptor = FetchDescriptor<Session>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        let session = (try? store.context.fetch(descriptor))?.first
        if session !== openSession {
            openSession = session
        } else {
            // The same object with new values, which observation doesn't see on its own.
            withMutation(keyPath: \.openSession) {}
        }
    }

    /// What ``nowPlaying`` does for an observation with no song to show.
    /// - Returns: whether it cleared a song shown or on its way.
    private func clearNowPlaying(for observation: NowPlayingObservation?) -> Bool {
        let shown = pendingNowPlayingKey ?? nowPlaying.map(Self.songKey(for:))
        guard let shown else { return false }
        // A pause from one player is about its own song. On iPhone, Tracks’ player starting
        // pauses the Music app, and that pause mustn't take away the song Tracks is playing.
        if let observation, Self.songKey(for: observation) != shown { return false }
        pendingNowPlayingKey = nil
        if nowPlaying != nil { nowPlaying = nil }
        return true
    }

    /// Updates ``nowPlaying`` from every playing observation, captured or not. Artwork comes
    /// from an earlier capture of the same song, or a catalog lookup, since the macOS
    /// notification carries none and an iOS radio song's can't be loaded.
    private func updateNowPlaying(_ observation: NowPlayingObservation, existing: CaptureSnapshot?) {
        let key = Self.songKey(for: observation)
        let next = NowPlaying(
            title: observation.title,
            artistName: observation.artistName,
            albumTitle: observation.albumTitle ?? existing?.albumTitle,
            artworkURL: observation.artworkURL
                ?? existing?.artworkURL
                ?? (artworkLookupKey == key ? artworkLookupResult : nil)
        )
        if next != nowPlaying { nowPlaying = next }
        if nowPlaying?.artworkURL == nil { lookUpArtwork(for: observation) }
    }

    /// Fetches a cover for a song that has no capture to borrow one from. Runs once per
    /// song, and a failure is remembered too so it isn't retried every poll.
    ///
    /// On iOS a radio song's own cover is a `musicKit://` URL that can't be loaded (see
    /// ``ArtworkURL``), so the observation arrives without one, but it does carry the id.
    private func lookUpArtwork(for observation: NowPlayingObservation) {
        let key = Self.songKey(for: observation)
        guard artworkLookupKey != key else { return }
        artworkLookupKey = key
        artworkLookupResult = nil
        artworkLookup?.cancel()

        artworkLookup = Task { [weak self] in
            guard let found = await Self.catalogArtwork(for: observation), !Task.isCancelled,
                  let self, self.artworkLookupKey == key
            else { return }
            // Kept for the song whether or not it's on show this moment, so the next rebuild of
            // `nowPlaying` has it: an observation in between can clear the card briefly, and the
            // cover mustn't be lost with it, since it isn't looked up twice.
            self.artworkLookupResult = found.artworkURL
            guard self.nowPlaying.map(Self.songKey(for:)) == key else { return }
            self.nowPlaying = NowPlaying(
                title: observation.title,
                artistName: observation.artistName,
                albumTitle: self.nowPlaying?.albumTitle ?? found.albumTitle,
                artworkURL: found.artworkURL
            )
        }
    }

    /// A loadable cover: by id when the observation has one (iOS), otherwise by searching the
    /// catalog (the macOS notification has no id).
    private static func catalogArtwork(
        for observation: NowPlayingObservation
    ) async -> (artworkURL: String, albumTitle: String?)? {
        let lookup = CatalogLookup()
        if let id = observation.catalogSongID,
           MusicItemIdentity.isCatalogID(id) || MusicItemIdentity.isLibraryID(id) {
            guard let url = try? await lookup.artworkURLs(forSongIDs: [id])[id] else { return nil }
            return (url, nil)
        }
        let query = CatalogQuery(
            title: observation.title,
            artistName: observation.artistName,
            duration: observation.duration,
            albumTitle: observation.albumTitle
        )
        guard let match = try? await lookup.resolve(query), let url = match.artworkURL else { return nil }
        return (url, match.albumTitle)
    }

    /// The single-capture path used by the App Intent, Action Button and Back Tap. Works
    /// without the capture loop running, which on iOS is most of the time.
    @discardableResult
    public func captureCurrentSong() async -> CaptureDecision {
        // Paused history keeps nothing, whoever asks. The intent has no reason of its own for
        // this yet, so it reads as nothing playing.
        guard !isPaused else { return .ignore(.notPlaying) }
        guard let observation = await currentObservation() else {
            return .ignore(.unidentifiable)
        }
        // The user asked for this song, so skip the minimum listening time.
        let decision = await coordinator.handle(observation, force: true)
        await record(decision, observation: observation)
        // Written and sent now: from the intent, the process is suspended soon after this
        // returns, and handling no longer waits for the playlist write.
        if case .capture = decision {
            await coordinator.drainPendingWrites()
            await scrobbler.drain()
        }
        return decision
    }

    static func songKey(for observation: NowPlayingObservation) -> String {
        songKey(title: observation.title, artistName: observation.artistName)
    }

    static func songKey(for song: NowPlaying) -> String {
        songKey(title: song.title, artistName: song.artistName)
    }

    private static func songKey(title: String, artistName: String) -> String {
        "\(title)\u{1F}\(artistName)"
    }

    private func currentObservation() async -> NowPlayingObservation? {
        #if os(iOS)
        // Each read below can reconnect to Apple's player service on the main thread. The poll
        // keeps running in the background, so it waits out scene changes (see PlayerQuiet).
        await PlayerQuiet.settled()
        #endif
        // Whichever player is making sound. Tracks’ own wins when it's playing: on iPhone
        // starting it interrupted the Music app, and on the Mac capture only listens to
        // Music.app while Tracks’ is quiet.
        if PushedNowPlayingSource.yourMusic.isPlaying {
            return PushedNowPlayingSource.yourMusic.current
        }
        if ApplicationMusicPlayerSource.isPlaying {
            return await ApplicationMusicPlayerSource.readObservation()
        }
        #if os(iOS)
        let other = await SystemMusicPlayerSource.readObservation()
        #else
        // Off the main actor: an Apple event blocks its thread until Music answers or times out.
        let other = await ScriptingQueue.run { PlayerInfoSource.currentObservation() }
        #endif
        if let other { return other }
        return await ApplicationMusicPlayerSource.readObservation()
    }
}

/// What the status display reads from the store after each observation, each in a context of
/// its own on the concurrent pool so a poll never waits on the store on the main actor. The
/// coordinator has saved the rows these look for before they run.
nonisolated struct CaptureReads: Sendable {
    let container: ModelContainer

    struct Read: Sendable {
        /// The newest capture, when asked for.
        var latest: CaptureSnapshot?
        /// The newest capture of the song asked about.
        var song: CaptureSnapshot?
        var openSession: PersistentIdentifier?
    }

    @concurrent
    func read(latest: Bool, song: (title: String, artistName: String)?, deviceID: String) async -> Read {
        let context = ModelContext(container)
        var read = Read()
        if latest {
            read.latest = (try? context.fetch(TracksStore.allCaptures(limit: 1)))?.first?.snapshot
        }
        if let song {
            let descriptor = TracksStore.mostRecentCapture(title: song.title, artistName: song.artistName)
            read.song = (try? context.fetch(descriptor))?.first?.snapshot
        }
        var sessions = TracksStore.openSessions(deviceID: deviceID)
        sessions.fetchLimit = 1
        read.openSession = (try? context.fetch(sessions))?.first?.persistentModelID
        return read
    }
}
