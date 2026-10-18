import Foundation
import Observation
import SwiftUI
import MusicKit
import TracksCore
import TracksMusic

/// Tracks’ player, as every screen sees it: what's on, what's next, and the controls.
///
/// The engine plays; this adds what Tracks knows on top. It notices skips and remembers them
/// (see ``ListeningSignals``) so the mixes learn, runs the sleep timer, and turns failures
/// into something the screens can explain.
@MainActor
@Observable
final class PlayerModel {
    private(set) var status: PlayerStatus = .stopped
    private(set) var current: PlayerTrack? {
        didSet {
            // Its background readied now, so the player shows it the moment it's opened or
            // the song changes under it, with the next song's after it.
            guard current?.cover != oldValue?.cover else { return }
            BackdropArtStore.shared.prepare([current?.cover])
        }
    }
    private(set) var upNext: [PlayerTrack] = [] {
        didSet {
            // And the next song's, so the change to it is ready too.
            guard upNext.first?.cover != oldValue.first?.cover else { return }
            BackdropArtStore.shared.prepare([upNext.first?.cover])
        }
    }
    private(set) var isShuffled = false
    @ObservationIgnored private var level: Float = 1
    private(set) var repeatMode: PlayerRepeat = .off
    /// When the current song started, for how close it is to counting.
    private(set) var trackStartedAt: Date?
    /// Where the music is coming from. Nil until something has been played this launch.
    private(set) var context: PlayContext?
    /// The last thing that went wrong, until it's dismissed or something plays.
    var problem: PlayerProblem?
    private(set) var sleepTimer: SleepTimer?
    /// Skips and "suggest less", which steer the mixes.
    private(set) var signals: ListeningSignals
    /// Tracks Radio's finds that played and had their downloads removed after, newest first, to
    /// keep from Up Next if one was liked.
    private(set) var playedAndRemoved: [PlayerTrack] = []

    /// The song left paused when Tracks last closed, shown as the song on until it's played or
    /// replaced. Nothing is handed to the engine until then, so opening Tracks never takes the
    /// audio or the media keys from another app. See ``restoreLastSession()``.
    private(set) var waitingSession: LastSession?

    /// Where the person has asked play or pause to go, shown at once while the player catches
    /// up, so the button answers the tap rather than the engine a moment later.
    private(set) var intendsToPlay: Bool?

    @ObservationIgnored private var engine: any PlayerEngine
    /// The player the source was switched to while music played: it takes over from the next
    /// thing played, so switching doesn't stop the music.
    @ObservationIgnored private var nextEngine: (any PlayerEngine)?
    @ObservationIgnored private let signalsStore: SignalsStore
    /// How far the current song got, sampled while playing: at a song change the engine
    /// already reports the new song's time.
    @ObservationIgnored private var lastSample: (trackID: String, time: TimeInterval)?
    /// Until when a song giving way isn't a skip: a new request replaced the queue, and the
    /// player can report the change a moment after the request returns.
    @ObservationIgnored private var replacingQueueUntil = Date.distantPast
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// Counts play requests, so a slow one finishing late can't undo a newer one.
    @ObservationIgnored private var latestRequest = 0
    /// Play requests still starting. While one is, nothing is added to the queue it's
    /// replacing, since the live mix's picks belong to the queue that was on.
    @ObservationIgnored private var requestsStarting = 0
    /// Set by Previous: going back isn't a verdict on the song being left.
    @ObservationIgnored private var isGoingBack = false
    @ObservationIgnored private var goingBackCount = 0

    /// Sample data: the engine only pretends, and songs play without catalog ids.
    let isDemo: Bool

    init(engine: any PlayerEngine, isDemo: Bool = false, signalsStore: SignalsStore = SignalsStore()) {
        self.engine = engine
        self.isDemo = isDemo
        self.signalsStore = signalsStore
        var signals = signalsStore.load()
        signals.blocked = CaptureSettings().blockedArtists
        self.signals = signals
        listen(to: engine)
        engineChanged()
        followBlockedArtistsFromOtherDevices()
    }

    /// Follows an engine's changes, and takes its remote controls' Next and Previous, so the
    /// car and the lock screen skip as the app's own buttons do.
    private func listen(to engine: any PlayerEngine) {
        engine.onChange = { [weak self] in self?.engineChanged() }
        guard let local = engine as? LocalPlayerEngine else { return }
        local.onNotice = { [weak self] in self?.confirm($0) }
        local.onRemoteNext = { [weak self] in self?.skipToNext() }
        local.onRemotePrevious = { [weak self] in self?.skipToPrevious() }
        local.onAutoSkip = { [weak self] in self?.isAutoSkipping = true }
    }

    var hasQueue: Bool { current != nil }

    /// For an alert: true while there's a problem to show, and clears it when dismissed.
    var isShowingProblem: Bool {
        get { problem != nil }
        set { if !newValue { problem = nil } }
    }

    /// A mix's songs as the player takes them: the ones Apple Music identified, or all of
    /// them for a player that finds songs by name.
    func songs(in mix: Mix) -> [HistorySong] {
        (engine.playsByName ? mix.songs : mix.playableSongs).map(HistorySong.init)
    }

    /// Whether a history song can be played: it has a catalog id, or the player finds songs by
    /// name, as sample data's and your own music's do.
    func canPlay(songID: String) -> Bool {
        engine.playsByName || !songID.isEmpty
    }

    /// Changes the player behind the model, when the music source changes. Whatever was
    /// playing stops, unless it's to keep playing.
    /// - Parameter keepingWhatsPlaying: for a quick switch: a song that's on carries on, and
    ///   the new player takes over from the next thing played.
    func use(_ engine: any PlayerEngine, keepingWhatsPlaying: Bool = false) {
        guard engine !== self.engine else {
            nextEngine = nil
            return
        }
        if keepingWhatsPlaying, current != nil {
            nextEngine = engine
            return
        }
        nextEngine = nil
        // Your own songs can't wait on the Apple Music player, nor Apple Music's on yours.
        if let waitingSession, waitingSession.isYourMusic != (engine is LocalPlayerEngine) {
            self.waitingSession = nil
            current = nil
            upNext = []
            status = .stopped
        }
        self.engine.pause()
        self.engine.deactivate()
        self.engine.onChange = nil
        self.engine = engine
        engine.setLevel(level)
        listen(to: engine)
        // A request still starting on the old player is no longer the latest, and the song
        // that was on isn't being skipped: the source changed under it.
        latestRequest += 1
        lastSample = nil
        replacingQueueUntil = .now.addingTimeInterval(3)
        live = nil
        liveGetsReady = false
        livePick?.cancel()
        livePick = nil
        cancelPickAgain()
        endAutoplay()
        context = nil
        intendsToPlay = nil
        sleepTimer = nil
        engineChanged()
    }
    /// Playing, or asked to play and about to. What the play and pause buttons show.
    var isPlaying: Bool { intendsToPlay ?? (status == .playing) }

    /// The current song's position. Not observed: views that show it redraw on a timeline.
    var playbackTime: TimeInterval { waitingSession?.time ?? engine.playbackTime }

    // MARK: - Playing

    /// Replaces the queue and plays.
    ///
    /// Requests can overlap (a lookup can take a while), so each carries a number and only the
    /// newest one decides where the music is coming from.
    func play(_ request: PlayRequest, from context: PlayContext, shuffled: Bool = false) {
        Task { await start(request, from: context, shuffled: shuffled) }
    }

    /// ``play(_:from:shuffled:)``, returning once the player has started or failed: for Siri
    /// and Shortcuts, which mustn't finish before the music does start.
    func start(_ request: PlayRequest, from context: PlayContext, shuffled: Bool = false) async {
        takeOverIfSwitched()
        intendsToPlay = true
        settleIntent()
        problem = nil
        // A new queue is a new song, not the end of this one.
        if sleepTimer == .endOfSong { sleepTimer = nil }
        latestRequest += 1
        let requestID = latestRequest
        replacingQueueUntil = .distantFuture
        // A pick still being looked up for the live mix on now would land in the new queue,
        // and adding to a queue as it starts cuts its start short.
        livePick?.cancel()
        livePick = nil
        cancelPickAgain()
        // A new queue plays through before Autoplay follows on from it. A live mix has ended
        // it already, as it set its own mix up.
        if context.kind != .endless { endAutoplay() }
        queuePlayed = []
        requestsStarting += 1
        let engine = self.engine
        let before = engine.current?.id
        defer {
            requestsStarting -= 1
            if requestID == latestRequest { replacingQueueUntil = .now.addingTimeInterval(3) }
        }
        do {
            try await engine.play(request, context: context, shuffled: shuffled)
            // The music source changed while this was starting: the old player mustn't play.
            guard engine === self.engine else {
                engine.pause()
                return
            }
            if requestID == latestRequest {
                self.context = context
                // Anything else playing ends the live mix.
                if context.kind != .endless {
                    live = nil
                    liveGetsReady = false
                }
            }
        } catch {
            // A newer request, or another music source, took over: whatever this one ran into
            // is no longer anything to tell anyone.
            guard engine === self.engine, requestID == latestRequest else { return }
            // The queue may have been replaced before starting failed.
            if engine.current?.id != before { self.context = context }
            report(error)
        }
    }

    /// Play Next and Play Later. Starts playing if nothing is queued, and replaces a station,
    /// which has no queue to add to: songs added to it would be kept as radio.
    func enqueue(_ request: PlayRequest, next: Bool, title: String) {
        // Songs from the source switched to can't join the other's queue: they play instead.
        guard hasQueue, context?.isStation != true, nextEngine == nil else {
            play(request, from: .songs(title))
            return
        }
        // The song left paused isn't in the player yet: added songs would play in its place
        // and its Up Next would be lost. It starts first, and they join its queue.
        if waitingSession != nil {
            let resuming = resumeWaitingSession()
            Task {
                await resuming?.value
                guard waitingSession == nil, hasQueue else { return }
                enqueue(request, next: next, title: title)
            }
            return
        }
        problem = nil
        // What you add plays before Autoplay's picks, as in Music: they make way, and
        // Autoplay follows on after your songs.
        if isAutoplaying {
            let picks = IndexSet(upNext.indices.filter { isAutoplayPick(upNext[$0]) })
            if !picks.isEmpty { engine.removeUpNext(at: picks) }
        }
        userEnqueues += 1
        Task {
            defer {
                userEnqueues -= 1
                topUpLiveIfNeeded()
            }
            do {
                let before = upNext.count
                try await engine.enqueue(request, next: next)
                if !next { playBeforeLivePicks(added: upNext.count - before) }
                confirm(next ? String(localized: "Playing Next") : String(localized: "Added to Queue"))
            } catch {
                report(error)
            }
        }
    }

    /// Play Next and Play Later under way, which Autoplay and a live mix wait for so their
    /// picks don't land ahead of your songs.
    @ObservationIgnored private var userEnqueues = 0

    /// On a live mix, songs added to the end play before the songs it has picked, as they do
    /// before Autoplay's, and it carries on picking after them. Only with your own music,
    /// whose player adds them at once: Apple Music's looks them up first, and a pick could
    /// land in between.
    private func playBeforeLivePicks(added: Int) {
        guard isLive, !isAutoplaying, engine is LocalPlayerEngine, added > 0, let live, upNext.count >= added else { return }
        let start = upNext.count - added
        guard let firstPick = upNext.firstIndex(where: { live.hasPicked($0.songIdentity) }), firstPick < start else { return }
        engine.moveUpNext(from: IndexSet(start..<upNext.count), to: firstPick)
    }

    /// Adds to the end of the queue quietly, for songs still loading behind a playlist.
    func append(_ request: PlayRequest) {
        guard hasQueue, waitingSession == nil else { return }
        Task { try? await engine.enqueue(request, next: false) }
    }

    /// The player's own level under the phone's volume, for Louder at Speed. Kept for the
    /// next player, if the music source changes mid-drive.
    func setLevel(_ level: Float) {
        self.level = level
        engine.setLevel(level)
    }

    /// Whether Tracks plays the audio itself and can set its level: your own music, or the
    /// pretend player. Apple Music's level is the system's.
    var setsOwnLevel: Bool { !(engine is MusicKitPlayerEngine) }

    func togglePlayPause() {
        guard waitingSession == nil else {
            resumeWaitingSession()
            return
        }
        let play = !isPlaying
        intendsToPlay = play
        if play {
            Task {
                do { try await engine.resume() } catch { report(error) }
            }
        } else {
            engine.pause()
        }
        settleIntent()
    }

    /// Lets the engine have the last word if it never reaches what was asked, so the button
    /// can't be left showing something that isn't happening.
    private func settleIntent() {
        // Only the latest tap's timer settles it: an earlier one could clear a newer intent.
        let asked = intendsToPlay
        intentSettling?.cancel()
        intentSettling = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, intendsToPlay == asked else { return }
            intendsToPlay = nil
        }
    }

    @ObservationIgnored private var intentSettling: Task<Void, Never>?

    func skipToNext() {
        guard waitingSession == nil else {
            resumeWaitingSession(startingAt: 1)
            return
        }
        Task {
            // On a live mix the next song may still be being picked: wait, rather than skip
            // off the end of the queue.
            if upNext.isEmpty, let autoplayStart { await autoplayStart.value }
            if isLive || isAutoplaying, upNext.isEmpty, let livePick { await livePick.value }
            do { try await engine.skipToNext() } catch { report(error) }
        }
    }

    func skipToPrevious() {
        guard waitingSession == nil else {
            // Back to the start of the song, as Previous does part way through one.
            waitingSession?.time = 0
            return
        }
        noteReplayIfRestarting()
        isGoingBack = true
        goingBackCount += 1
        let tap = goingBackCount
        Task {
            do { try await engine.skipToPrevious() } catch { report(error) }
            // Previous may only have restarted the song. Either way the next change is
            // the person's own again after a moment, counted from the latest tap.
            try? await Task.sleep(for: .seconds(2))
            if goingBackCount == tap { isGoingBack = false }
        }
    }

    func seek(to time: TimeInterval) {
        guard waitingSession == nil else {
            waitingSession?.time = time
            return
        }
        engine.seek(to: time)
        lastSample = current.map { ($0.id, time) }
    }

    func toggleShuffle() {
        engine.setShuffled(!isShuffled)
    }

    func cycleRepeat() {
        engine.setRepeat(repeatMode.next)
    }

    /// A repeat mode by name, for a menu that lists them.
    func setRepeat(_ mode: PlayerRepeat) {
        engine.setRepeat(mode)
    }

    func jump(toUpNext index: Int) {
        guard waitingSession == nil else {
            resumeWaitingSession(startingAt: index + 1)
            return
        }
        Task {
            do { try await engine.jump(toUpNext: index) } catch { report(error) }
        }
    }

    func removeUpNext(at offsets: IndexSet) {
        if var waiting = waitingSession {
            // Up Next is everything after the first song.
            waiting.tracks.remove(atOffsets: IndexSet(offsets.map { $0 + 1 }))
            waitingSession = waiting
            upNext = Array(waiting.tracks.dropFirst())
            return
        }
        let removed = offsets.compactMap { upNext.indices.contains($0) ? upNext[$0] : nil }
        engine.removeUpNext(at: offsets)
        // A pick taken out of a live mix or Autoplay is a no to it, heard as a skip would be,
        // and another takes its place.
        guard picksLive, let live else { return }
        for track in removed where isAutoplaying ? isAutoplayPick(track) : live.hasPicked(track.songIdentity) {
            self.live?.noteSkipped(track.songIdentity)
            // On Tracks Radio getting songs ready, it also stops downloading.
            if liveGetsReady, let radioDownloads {
                radioDownloads.decline(HistorySong(track))
                waitingSince[track.songIdentity] = nil
            }
        }
        followSteering()
        topUpLiveIfNeeded()
    }

    func moveUpNext(from offsets: IndexSet, to destination: Int) {
        if var waiting = waitingSession {
            var ahead = Array(waiting.tracks.dropFirst())
            ahead.move(fromOffsets: offsets, toOffset: destination)
            waiting.tracks = Array(waiting.tracks.prefix(1)) + ahead
            waitingSession = waiting
            upNext = ahead
            return
        }
        engine.moveUpNext(from: offsets, to: destination)
    }

    // MARK: - Stations and the library

    /// A station made from a song, as Music's Create Station does.
    func playStation(from song: Song) {
        startStation(named: song.title) { try await song.with([.station]).station }
    }

    /// The artist's own station.
    func playStation(from artist: Artist) {
        startStation(named: artist.name) { try await artist.with([.station]).station }
    }

    private func startStation(named name: String, find: @escaping () async throws -> MusicKit.Station?) {
        problem = nil
        if sleepTimer == .endOfSong { sleepTimer = nil }
        Task {
            do {
                try await MusicKitPlayerEngine.checkAccess()
                guard let station = try await find() else {
                    problem = .failed(String(localized: "Apple Music doesn't have a station for \(name)."))
                    return
                }
                play(.station(station), from: PlayContext(kind: .station, title: station.name))
            } catch {
                report(error)
            }
        }
    }

    func addToLibrary(_ song: Song) {
        add { try await Self.addToAppleMusicLibrary(song) }
    }

    func addToLibrary(_ album: Album) {
        add {
            #if os(iOS)
            try await MusicLibrary.shared.add(album)
            #else
            try await Self.sendAddition(of: [album.id], as: .albums)
            #endif
        }
    }

    func addToLibrary(_ playlist: Playlist) {
        add {
            #if os(iOS)
            try await MusicLibrary.shared.add(playlist)
            #else
            try await Self.sendAddition(of: [playlist.id], as: .playlists)
            #endif
        }
    }

    /// MusicKit's own call on iPhone. The Mac doesn't have it, so it asks Apple Music the way
    /// Music does.
    private static func addToAppleMusicLibrary(_ song: Song) async throws {
        #if os(iOS)
        try await MusicLibrary.shared.add(song)
        #else
        try await sendAddition(of: [song.id], as: .songs)
        #endif
    }

    #if os(macOS)
    private static func sendAddition(of ids: [MusicItemID], as kind: AppleMusicLibraryAdd.Kind) async throws {
        // Already in the library, so there's nothing to ask for.
        guard let request = AppleMusicLibraryAdd.request(adding: ids.map(\.rawValue), as: kind) else { return }
        let response = try await MusicDataRequest(urlRequest: request).response()
        guard (200..<300).contains(response.urlResponse.statusCode) else {
            throw PlayerProblem.failed(String(localized: "Apple Music couldn't add this to your library. Try again in a moment."))
        }
    }
    #endif

    // MARK: - Favorites

    /// Which songs are Apple Music favorites, as far as Tracks knows: looked up for the songs
    /// on screen, and changed by the star. Missing means not looked up yet.
    private(set) var favorites: [MusicItemID: Bool] = [:]
    @ObservationIgnored private var favoritesToLookUp: Set<MusicItemID> = []
    @ObservationIgnored private var favoritesLookUp: Task<Void, Never>?

    func isFavorite(_ song: Song) -> Bool {
        favorites[song.id] == true
    }

    /// Stars or unstars a song in Apple Music, as the star in Music does. A favorite is added
    /// to the library too, as Music adds them. Shown at once, and put back if it fails.
    func setFavorite(_ song: Song, _ isFavorite: Bool) {
        let was = favorites[song.id]
        favorites[song.id] = isFavorite
        // Loving the song on now tells a live mix or Autoplay to play more like it.
        if isFavorite, canAskForMoreLikeThis, let current, current.song?.id == song.id {
            live?.noteLoved(current.songIdentity)
            followSteering()
            repickNext(unlessBy: current.artistName)
        }
        // With sample data there's no Apple Music to tell; the star still shows what happens.
        guard !isDemo else { return }
        Task {
            do {
                try await MusicKitPlayerEngine.checkAccess()
                if isFavorite {
                    try await Self.addToAppleMusicLibrary(song)
                    try await Self.send(AppleMusicFavorites.favorite(songID: song.id.rawValue))
                } else {
                    try await Self.send(AppleMusicFavorites.unfavorite(songID: song.id.rawValue))
                }
            } catch {
                favorites[song.id] = was
                report(error, couldnt: isFavorite
                    ? String(localized: "Couldn't Favorite")
                    : String(localized: "Couldn't Remove Favorite"))
            }
        }
    }

    /// Finds out whether a song on screen is already a favorite. Songs asked about together
    /// are looked up in one request.
    func lookUpFavorite(_ song: Song) {
        guard !isDemo, favorites[song.id] == nil else { return }
        favoritesToLookUp.insert(song.id)
        guard favoritesLookUp == nil else { return }
        favoritesLookUp = Task {
            try? await Task.sleep(for: .milliseconds(250))
            // Library songs are rated under another path, and every row here is from the catalog.
            let ids = favoritesToLookUp.filter { favorites[$0] == nil && !$0.rawValue.hasPrefix("i.") }
            favoritesToLookUp = []
            favoritesLookUp = nil
            let all = Array(ids)
            for start in stride(from: 0, to: all.count, by: 50) {
                let chunk = all[start..<min(start + 50, all.count)]
                guard let data = try? await Self.send(AppleMusicFavorites.ratings(songIDs: chunk.map(\.rawValue))) else { continue }
                let loved = AppleMusicFavorites.favoriteIDs(in: data)
                // A star tapped while this was out wins over what came back.
                for id in chunk where favorites[id] == nil {
                    favorites[id] = loved.contains(id.rawValue)
                }
            }
        }
    }

    @discardableResult
    private static func send(_ request: URLRequest) async throws -> Data {
        let response = try await MusicDataRequest(urlRequest: request).response()
        guard (200..<300).contains(response.urlResponse.statusCode) else {
            throw PlayerProblem.failed(String(localized: "Apple Music couldn't change this favorite. Try again in a moment."))
        }
        return response.data
    }

    private func add(_ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await MusicKitPlayerEngine.checkAccess()
                try await work()
                confirm(String(localized: "Added to Library"))
            } catch {
                report(error, couldnt: String(localized: "Couldn't Add to Library"))
            }
        }
    }

    /// Adds a song to one of your Apple Music playlists, or to a new one by that name.
    func add(_ song: Song, toPlaylist playlist: Playlist?, named name: String) {
        Task {
            do {
                try await MusicKitPlayerEngine.checkAccess()
                #if os(iOS)
                if let playlist {
                    _ = try await MusicLibrary.shared.add(song, to: playlist)
                } else {
                    _ = try await MusicLibrary.shared.createPlaylist(name: name, items: [song])
                }
                #else
                // MusicKit can't change your library on the Mac, so Apple Music is asked directly.
                let writer = MusicKitPlaylistWriter()
                let id = if let playlist { playlist.id.rawValue } else { try await writer.createPlaylist(name: name, description: nil) }
                try await writer.addSongs(ids: [song.id.rawValue], toPlaylist: id)
                #endif
                confirm(String(localized: "Added to \u{201C}\(name)\u{201D}"))
            } catch {
                report(error, couldnt: String(localized: "Couldn't Add to Playlist"))
            }
        }
    }

    /// A short confirmation, shown over everything for a moment, like Music's.
    private(set) var confirmation: String?
    @ObservationIgnored private var confirmationTask: Task<Void, Never>?

    func confirm(_ message: String) {
        confirmation = message
        confirmationTask?.cancel()
        confirmationTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            confirmation = nil
        }
    }

    // MARK: - Sleep timer

    func setSleepTimer(_ timer: SleepTimer?) {
        sleepTimer = timer
        startTickerIfNeeded()
    }

    /// Time left on a timed sleep timer.
    func sleepRemaining(at date: Date = .now) -> TimeInterval? {
        guard case .at(let end) = sleepTimer else { return nil }
        return max(0, end.timeIntervalSince(date))
    }

    // MARK: - Signals

    func isSuggestingLess(_ songIdentity: String) -> Bool {
        signals.suggestLess.contains(songIdentity)
    }

    func setSuggestLess(_ songIdentity: String, _ isOn: Bool) {
        signals.setSuggestLess(songIdentity, isOn)
        signalsStore.save(signals)
        // A live mix hears it at once, as a skip of that artist.
        if isOn, picksLive {
            live?.noteSkipped(songIdentity)
            followSteering()
        }
        confirm(isOn ? String(localized: "Tracks Will Suggest This Less") : String(localized: "Tracks Will Suggest This Again"))
    }

    /// Forgets every skip and "suggest less". Blocked artists stay blocked: they're a list of
    /// their own, in Settings.
    func resetSignals() {
        let blocked = signals.blocked
        signals = ListeningSignals()
        signals.blocked = blocked
        signalsStore.save(signals)
    }

    // MARK: - Blocked artists

    /// Whether the artist is blocked, by their whole name.
    func isBlocked(artist name: String) -> Bool {
        signals.blocked.contains(artist: name)
    }

    /// Never plays or suggests the artist again, on any of your devices: out of every mix,
    /// Tracks Radio, Autoplay and suggestion, out of Up Next now, and skipped if they're on.
    func block(artist name: String) {
        var blocked = signals.blocked
        guard blocked.block(name) else { return }
        apply(blocked)
        confirm(String(localized: "Blocked \(name)"))
    }

    func unblock(artist name: String) {
        var blocked = signals.blocked
        guard blocked.contains(artist: name) else { return }
        blocked.unblock(name)
        apply(blocked)
        confirm(String(localized: "Unblocked \(name)"))
    }

    /// Keeps the list, then takes the artists in it out of what's playing.
    private func apply(_ blocked: BlockedArtists, saving: Bool = true) {
        if saving { CaptureSettings().blockedArtists = blocked }
        // The mixes and suggestions are rebuilt as the signals change.
        signals.blocked = blocked
        live?.blocked = blocked
        guard !blocked.isEmpty else { return }
        let theirs = IndexSet(upNext.indices.filter { blocked.blocks(songBy: upNext[$0].artistName) })
        if !theirs.isEmpty { engine.removeUpNext(at: theirs) }
        skipIfBlocked(current)
    }

    /// Blocking or unblocking on another device reaches this one, with what it plays.
    private func followBlockedArtistsFromOtherDevices() {
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: SettingsSync.didChangeNotification) {
                guard let self else { return }
                let blocked = CaptureSettings().blockedArtists
                if blocked != signals.blocked { apply(blocked, saving: false) }
            }
        }
    }

    // MARK: - Following the engine

    private func engineChanged() {
        if let waitingSession {
            guard engine.current != nil else {
                // Still waiting: the song left paused stands in for the engine's empty queue.
                current = waitingSession.tracks.first
                upNext = Array(waitingSession.tracks.dropFirst())
                status = .paused
                context = waitingSession.context
                isShuffled = engine.isShuffled
                repeatMode = engine.repeatMode
                return
            }
            // It's playing for real now. The stand-in wasn't a song being left.
            self.waitingSession = nil
            current = nil
        }
        let previous = current
        let next = engine.current
        var stoppedForSleep = false

        if let previous, previous.id != next?.id {
            queuePlayed.append(previous)
            if queuePlayed.count > 12 { queuePlayed.removeFirst(queuePlayed.count - 12) }
            noteLeaving(previous)
            removeIfPlayedOnce(previous)
            if sleepTimer == .endOfSong, next != nil {
                stopForSleep()
                stoppedForSleep = true
            }
        }

        // A live station can keep one entry while its song changes underneath it. The clock
        // starts when the song first actually plays, as the capture's does, not while it's
        // still loading: a song from a server can take seconds to arrive.
        if next?.id != previous?.id || next?.songIdentity != previous?.songIdentity {
            trackStartedAt = nil
        }
        status = engine.status
        if next != nil, status == .playing, trackStartedAt == nil {
            trackStartedAt = .now
        }
        if let intendsToPlay, (status == .playing) == intendsToPlay || status == .stopped {
            self.intendsToPlay = nil
        }
        current = next
        upNext = engine.upNext
        isShuffled = engine.isShuffled
        repeatMode = engine.repeatMode
        if next == nil {
            context = nil
            endAutoplay()
            // Nothing left to reach the end of.
            if sleepTimer == .endOfSong { sleepTimer = nil }
        }
        // Moved on from a song skipped for itself or its artist: if it comes round again, on
        // Repeat, it's skipped again.
        if next?.id != explicitSkippedEntry { explicitSkippedEntry = nil }
        if next?.id != blockedSkippedEntry { blockedSkippedEntry = nil }
        // Not straight after the sleep timer stopped the music: a skip would start it again.
        if !stoppedForSleep {
            skipIfNotAllowed(next)
            skipIfBlocked(next)
        }
        topUpLiveIfNeeded()
        startAutoplayIfNeeded()
        let onPick = next.map(isAutoplayPick) ?? false
        if isOnAutoplayPick != onPick { isOnAutoplayPick = onPick }
        startTickerIfNeeded()
        if previous?.id != next?.id || status != .playing { scheduleSave() }
    }

    // MARK: - Where you left off

    /// Opens on the song that was on when Tracks last closed, paused where it was left, if
    /// Settings keeps it and it hasn't waited longer than Settings says to.
    func restoreLastSession() {
        guard !isDemo, current == nil, var session = LastSessionStore.load(),
              session.isYourMusic == (engine is LocalPlayerEngine)
        else { return }
        session.time = ResumePoint.time(leftAt: session.time, duration: session.tracks.first?.duration)
        waitingSession = session
        engineChanged()
    }

    /// Plays the song left paused, from where it was, or a later song of its queue.
    @discardableResult
    private func resumeWaitingSession(startingAt index: Int = 0) -> Task<Void, Never>? {
        // Already starting: a second tap or a song added meanwhile waits on the same start.
        if let resumingSession { return resumingSession }
        guard let session = waitingSession, session.tracks.indices.contains(index) else { return nil }
        let tracks = session.tracks
        let request: PlayRequest
        if session.isYourMusic {
            request = .local(tracks.compactMap(\.local), startingAt: index)
        } else if !engine.playsByName, tracks.allSatisfy({ $0.song != nil }) {
            request = .songs(tracks.compactMap(\.song), startingAt: index)
        } else {
            request = .history(tracks.map {
                HistorySong(songID: $0.song?.id.rawValue ?? "", title: $0.title, artistName: $0.artistName, albumTitle: $0.albumTitle)
            }, startingAt: index)
        }
        let time = index == 0 ? session.time : 0
        var context = session.context ?? .songs(String(localized: "Where You Left Off"))
        let first = MixSong(tracks[index])
        let task = Task {
            defer { resumingSession = nil }
            if context.kind == .endless {
                // Picked up live, so it carries on picking as it did before Tracks closed.
                guard !(await resumeLive(context, startingWith: first)) else {
                    seekIfStill(on: first.songIdentity, to: time)
                    return
                }
                // Can't be made now: the songs it had queued play, as a mix.
                context = PlayContext(kind: .mix, title: context.title)
            }
            await start(request, from: context)
            seekIfStill(on: first.songIdentity, to: time)
        }
        resumingSession = task
        return task
    }

    @ObservationIgnored private var resumingSession: Task<Void, Never>?

    /// Back to where the song was left, if it's the one that started: one that can't play now
    /// is passed over, and the song after it starts from the top.
    private func seekIfStill(on songIdentity: String, to time: TimeInterval) {
        guard time > 0, waitingSession == nil, current?.songIdentity == songIdentity else { return }
        seek(to: time)
    }

    /// Starts Tracks Radio or a mood again from the song it was on, for one left paused when
    /// Tracks last closed or brought from another device. False when it can't be made now:
    /// Tracks Radio turned off, say.
    func resumeLive(_ context: PlayContext, startingWith first: MixSong) async -> Bool {
        if context == .tracksRadio {
            guard PlayPreferences.isTracksRadioOn, let mix = await makeTracksRadio?(), !mix.isEmpty else { return false }
            await startLive(mix, from: .tracksRadio, startingWith: first)
        } else {
            guard let restartMood else { return false }
            await restartMood(context.title, first)
        }
        return waitingSession == nil
    }

    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    /// Saves what's on a moment after it settles, so a run of changes is one write.
    private func scheduleSave() {
        guard !isDemo else { return }
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            saveCount += 1
            let save = saveCount
            guard let session = sessionToSave() else {
                LastSessionStore.save(nil)
                return
            }
            guard let data = await LastSessionStore.encoded(session),
                  saveCount == save
            else { return }
            LastSessionStore.write(data)
        }
    }

    /// Counts saves, so one encoded in the background can't overwrite a newer one.
    @ObservationIgnored private var saveCount = 0

    /// Keeps what's on, and how far into it, for the next launch. The app calls this as it
    /// goes to the background or quits, and it's written before this returns; the player
    /// saves as songs change and pause.
    func saveSession() {
        guard !isDemo else { return }
        pendingSave?.cancel()
        pendingSave = nil
        saveCount += 1
        LastSessionStore.save(sessionToSave())
    }

    /// What to keep for the next launch. Nil for nothing, as after a station, which can't be
    /// picked up part way.
    private func sessionToSave() -> LastSession? {
        if var waiting = waitingSession {
            // Opened and left again: the wait starts over from now.
            waiting.savedAt = .now
            return waiting
        }
        guard let current, context?.isStation != true else { return nil }
        return LastSession(
            tracks: [current] + upNext.prefix(LastSession.keptAhead),
            time: engine.playbackTime,
            contextKind: context?.kind.storedName,
            contextTitle: context?.title,
            savedAt: .now
        )
    }

    /// The source was switched while music played: the new player takes over now, as
    /// something from it is played.
    private func takeOverIfSwitched() {
        guard let nextEngine else { return }
        use(nextEngine)
    }

    // MARK: - Explicit songs on stations

    /// Explicit songs in a row skipped on a station. A station that only plays them gets
    /// paused rather than skipped through for good.
    @ObservationIgnored private var explicitSkipsInARow = 0
    /// The entry last skipped for being explicit, so it's skipped once.
    @ObservationIgnored private var explicitSkippedEntry: String?
    /// Set while Tracks skips a song itself, so the skip isn't taken for the person's.
    @ObservationIgnored private var isAutoSkipping = false

    /// A station can't be filtered before it plays, so an explicit song it picks is skipped
    /// as it starts when explicit songs are off.
    ///
    /// Checked on every change, not just a new entry: a station's entry starts as a bare title
    /// and only says it's explicit once it resolves to its song a moment later.
    private func skipIfNotAllowed(_ track: PlayerTrack?) {
        guard let track, !PlayPreferences.allowsExplicit else { return }
        guard track.isExplicit else {
            // A resolved song that's fine ends the run of explicit ones.
            if track.song != nil { explicitSkipsInARow = 0 }
            return
        }
        // Skipped once: not again, nor again for its artist.
        guard explicitSkippedEntry != track.id, blockedSkippedEntry != track.id else { return }
        explicitSkippedEntry = track.id
        explicitSkipsInARow += 1
        guard explicitSkipsInARow <= 5 else {
            explicitSkipsInARow = 0
            intendsToPlay = nil
            engine.pause()
            problem = .onlyExplicit
            return
        }
        autoSkip()
    }

    /// Skips the song on Tracks' own account, so the skip isn't taken for the person's.
    private func autoSkip() {
        isAutoSkipping = true
        Task {
            do {
                try await engine.skipToNext()
            } catch {
                // It didn't skip, so the person's next skip mustn't be taken for Tracks'.
                isAutoSkipping = false
            }
        }
    }

    /// Songs by blocked artists in a row skipped. After a few, or when there'd be nothing
    /// after it, Tracks stops and says why rather than skipping through for good.
    @ObservationIgnored private var blockedSkipsInARow = 0
    /// The entry last skipped for its artist, so it's skipped once.
    @ObservationIgnored private var blockedSkippedEntry: String?

    /// Nothing filters a station, an album or a playlist by artist before it plays, so a song
    /// of a blocked artist's is skipped as it starts. Checked on every change: a station's
    /// entry only says whose it is once it resolves.
    private func skipIfBlocked(_ track: PlayerTrack?) {
        guard let track, !signals.blocked.isEmpty, !track.artistName.isEmpty else { return }
        guard signals.blocked.blocks(songBy: track.artistName) else {
            blockedSkipsInARow = 0
            return
        }
        guard blockedSkippedEntry != track.id, explicitSkippedEntry != track.id else { return }
        blockedSkippedEntry = track.id
        blockedSkipsInARow += 1
        // A station or a live mix always has a next song; anything else may not.
        let hasNext = !upNext.isEmpty || context?.isStation == true || picksLive
        guard hasNext, blockedSkipsInARow <= 5 else {
            blockedSkipsInARow = 0
            intendsToPlay = nil
            engine.pause()
            problem = .blockedArtist(Self.blockedName(for: track, in: signals.blocked))
            return
        }
        autoSkip()
    }

    /// The blocked artist a song is credited to, as they were named when blocked.
    private static func blockedName(for track: PlayerTrack, in blocked: BlockedArtists) -> String {
        let credited = LocalTrack.creditedArtists(of: track.artistName)
        return blocked.names.first { credited.contains(StatsCalculator.folded($0)) } ?? track.artistName
    }

    // MARK: - Live mixes

    /// What's picking the songs while Tracks Radio or a mood plays. Nil for anything else.
    @ObservationIgnored private var live: LiveMix?
    /// The pick being queued, which a skip waits for rather than running off the end.
    @ObservationIgnored private var livePick: Task<Void, Never>?
    /// Counts picks, so one cancelled by a new listen doesn't clear the newer one's.
    @ObservationIgnored private var livePickCount = 0
    /// Builds Tracks Radio from the history, with its tuning. Set by the app, which has both.
    @ObservationIgnored var makeTracksRadio: (() async -> LiveMix)?
    /// Starts a mood again by its name, from a song: for one left paused when Tracks last
    /// closed. Set by the app, which knows how each mood is made.
    @ObservationIgnored var restartMood: ((_ title: String, _ first: MixSong) async -> Void)?
    /// Notices driving, for Tracks Radio's Drive mode.
    let drive = DriveDetector()
    /// The moment the Tracks Radio playing was made for: the hour it follows, and whether it
    /// plays for the road.
    private(set) var radioMoment: RadioMoment = .anytime
    /// The genres Tracks Radio's tuner offers, the ones you play most first. Kept ready by the
    /// app, so the tuner opens with them in place.
    var radioGenres: [String] = []
    /// What the live mix or Autoplay last changed course for, after a run of skips or a song
    /// let play. Nil until there's something to say.
    private(set) var steering: LiveMix.Steering?
    /// Songs like the ones just played are playing on from the queue's end.
    private(set) var isAutoplaying = false
    /// The song on now is one of Autoplay's, not the queue's.
    private(set) var isOnAutoplayPick = false
    /// What Autoplay follows on from, for Up Next: the album, playlist or mix that ran out.
    private(set) var autoplayFollows: String?
    /// Makes Autoplay's mix from the last songs played. Set by the app, which has the history.
    @ObservationIgnored var makeAutoplay: ((_ seeds: [PlayerTrack]) async -> LiveMix)?
    /// Autoplay's mix being made.
    @ObservationIgnored private var autoplayStart: Task<Void, Never>?
    @ObservationIgnored private var autoplayCount = 0
    /// The request Autoplay last tried to follow, so a queue it couldn't follow isn't tried on
    /// every change.
    @ObservationIgnored private var autoplayTried: Int?
    /// The songs Autoplay has queued, as against the ones it follows on from, which its mix
    /// also counts as picked.
    @ObservationIgnored private var autoplayPicked: Set<String> = []
    /// The songs this queue has played, newest last, for Autoplay to follow on from.
    @ObservationIgnored private var queuePlayed: [PlayerTrack] = []
    /// Your own music, for Tracks Radio to start with songs on this iPhone and get its new
    /// finds ready behind them. Set by the app.
    @ObservationIgnored weak var radioDownloads: (any RadioDownloads)? {
        didSet { radioDownloads?.onReady = { [weak self] in self?.songReady($0) } }
    }
    /// Whether the live mix playing does that: Tracks Radio, from your own music, with its
    /// setting on.
    @ObservationIgnored private var liveGetsReady = false
    /// When each song waiting in Up Next to be ready was queued: one that's taken too long is
    /// let go, so the radio isn't held on it.
    @ObservationIgnored private var waitingSince: [String: Date] = [:]

    /// Whether the songs are being picked as they play, so Up Next only ever holds the next one.
    var isLive: Bool { context?.kind == .endless && hasQueue }

    var isPlayingTracksRadio: Bool { isLive && context == .tracksRadio }

    /// Tracks Radio is playing for the road: for its artwork and Now Playing to say so.
    var isRadioDriving: Bool { isPlayingTracksRadio && radioMoment.isDriving }

    /// An endless mix of everything you love, picked as it plays.
    func playTracksRadio() {
        Task { await startTracksRadio() }
    }

    /// ``playTracksRadio()``, returning once it has started or failed.
    func startTracksRadio() async {
        problem = nil
        guard PlayPreferences.isTracksRadioOn else {
            problem = .failed(String(localized: "Tracks Radio is off. Turn it on in Settings, under Play."))
            return
        }
        guard let mix = await makeTracksRadio?(), !mix.isEmpty else {
            problem = .failed(String(localized: "Play a few songs first, and Tracks Radio will have something to draw from."))
            return
        }
        await startLive(mix, from: .tracksRadio)
    }

    /// For a shake: a song Tracks thinks you'd like and haven't heard, then Tracks Radio on from
    /// it. From your own music, a find that plays at once if there is one, so the shake answers
    /// straight away. Works with Tracks Radio hidden too.
    ///
    /// Nothing is added to your library: the song just plays. Says nothing when it starts,
    /// since what's playing is its own answer (the iPhone opens Now Playing on it).
    /// - Returns: whether it started playing.
    @discardableResult
    func playSomethingNew() async -> Bool {
        guard let mix = await makeTracksRadio?(), !mix.isEmpty else {
            problem = .failed(String(localized: "Play a few songs first, and Tracks will know what to find you."))
            return false
        }
        var picking = mix
        picking.blocked = signals.blocked
        let ready: (MixSong) -> Bool = { [radioDownloads] song in
            guard MusicSource.current == .yourMusic, let radioDownloads else { return true }
            return radioDownloads.isReady(HistorySong(song))
        }
        let engine = self.engine
        let canPlay: (MixSong) -> Bool = { engine.canPlayNow($0) }
        guard let first = picking.next(newFinds: true, where: { ready($0) && canPlay($0) })
            ?? picking.next(newFinds: true, where: canPlay)
            ?? picking.next(playable: canPlay)
        else { return false }
        await startLive(mix, from: .tracksRadio, startingWith: first)
        return problem == nil && hasQueue
    }

    /// Applies a new tuning to Tracks Radio while it plays, keeping what it has already picked
    /// and learned. The song queued next stays; the one after follows the new tuning.
    func retuneTracksRadio() async {
        // Not while another music source waits to take over: the new mix would be made from
        // it, and the radio carries on from the one it started on until then.
        guard isPlayingTracksRadio, nextEngine == nil, let makeTracksRadio else { return }
        // The moment it's made for now, so following the moment doesn't make it again.
        followedMoment = TracksRadioSource.moment(drive: drive)
        retunes += 1
        let retune = retunes
        var mix = await makeTracksRadio()
        guard !mix.isEmpty,
              // Only the latest tuning lands, and only on the radio still playing.
              retune == retunes, isPlayingTracksRadio, nextEngine == nil, let current = live
        else { return }
        // What's been picked while the new mix was made, the song queued next included.
        mix.continueListen(from: current)
        mix.blocked = signals.blocked
        live = mix
        radioMoment = mix.moment
    }

    /// Counts retunes, so one that finishes after a newer one is dropped.
    @ObservationIgnored private var retunes = 0

    /// Plays a live mix: the first song, and one more after it. Each song after that is picked
    /// as the one before starts, from what's been skipped and played through so far.
    /// - Parameter first: a song to start with, as when one is tapped on a mood's page.
    func startLive(_ mix: LiveMix, from context: PlayContext, startingWith first: MixSong? = nil) async {
        // The source switched to takes over now, before the mix is set up for it: switching
        // after would end the mix.
        takeOverIfSwitched()
        var mix = mix
        // Before the first picks, which the rest follow.
        mix.blocked = signals.blocked
        // Tracks Radio starts from what landed at this moment before, and opens by trying a
        // few directions unless it starts from a song.
        if context == .tracksRadio { mix.begin(with: TracksRadioSource.habits, probing: first == nil) }
        var songs: [MixSong] = []
        if let first {
            mix.note(picked: first.songIdentity)
            // The song it starts from says what you're in the mood for.
            mix.lean(toward: first.songIdentity)
            songs.append(first)
        }
        let engine = self.engine
        let getsReady = context == .tracksRadio && MusicSource.current == .yourMusic && radioDownloads?.downloadsFirst == true
        // Opens on one of your strongest songs for the moment, since the first song is the one
        // most often skipped when it doesn't land: one that plays at once, where that matters.
        if first == nil {
            let opener = if getsReady, let radioDownloads {
                mix.opener(where: { radioDownloads.isReady(HistorySong($0)) && engine.canPlayNow($0) })
            } else {
                mix.opener(where: { engine.canPlayNow($0) })
            }
            if let opener { songs.append(opener) }
        }
        // Songs that play at once to start with, so the radio begins without a wait.
        if getsReady, let radioDownloads {
            while songs.count < 2, let next = mix.next(where: { radioDownloads.isReady(HistorySong($0)) }) { songs.append(next) }
        }
        while songs.count < 2, let next = mix.next(playable: { engine.canPlayNow($0) }) { songs.append(next) }
        guard !songs.isEmpty else {
            problem = .nothingToPlay
            return
        }
        livePick?.cancel()
        livePick = nil
        cancelPickAgain()
        endAutoplay()
        live = mix
        steering = nil
        moreLikeThis = []
        radioMoment = context == .tracksRadio ? mix.moment : .anytime
        followedMoment = nil
        liveGetsReady = getsReady
        waitingSince = [:]
        // Repeat has no place on a mix without an end, and its button isn't shown there.
        if repeatMode != .off { engine.setRepeat(.off) }
        lastLivePick = songs.count > 1 ? songs.last?.songIdentity : nil
        await start(.history(songs.map(HistorySong.init)), from: PlayContext(kind: .endless, title: context.title))
        topUpLiveIfNeeded()
    }

    /// Picks the next song when there's none waiting after this one. Only one is queued ahead,
    /// so every pick knows about the song before it.
    private func topUpLiveIfNeeded() {
        followTheMoment()
        // The live mix's picks are for the queue on now, not one still replacing it.
        guard requestsStarting == 0 else { return }
        // Autoplay turned off in Settings while it played: it stops picking, and what it
        // picked makes way.
        if isAutoplaying, !PlayPreferences.autoplay {
            setAutoplay(false)
            return
        }
        // Songs you're adding land first; picking resumes once they have.
        guard userEnqueues == 0 else { return }
        // Nothing could be queued a moment ago: wait for the retry rather than spend picks.
        guard pickAgain == nil else { return }
        if liveGetsReady, let radioDownloads, context?.kind == .endless {
            topUpReadyFirst(radioDownloads)
            return
        }
        guard picksLive, status != .loading, livePick == nil, let live,
              current != nil, !upNext.contains(where: { live.hasPicked($0.songIdentity) })
        else { return }
        livePickCount += 1
        let pickID = livePickCount
        let engine = self.engine
        livePick = Task {
            defer { if livePickCount == pickID { livePick = nil } }
            // Songs that couldn't be queued go back to be picked another time, once this
            // round is over so it doesn't draw them again.
            var unqueued: [String] = []
            defer {
                for identity in unqueued {
                    self.live?.release(identity)
                    autoplayPicked.remove(identity)
                }
            }
            // Only songs that can play right now: your own music's server may be out of reach.
            // One that still can't (gone, or explicit with those off) is passed over.
            for _ in 0..<5 {
                guard !Task.isCancelled, picksLive, let song = self.live?.next(playable: { engine.canPlayNow($0) }) else { break }
                if isAutoplaying { autoplayPicked.insert(song.songIdentity) }
                do {
                    try await engine.enqueue(.history([HistorySong(song)]), next: false)
                    lastLivePick = song.songIdentity
                    return
                } catch {
                    unqueued.append(song.songIdentity)
                    continue
                }
            }
            guard !Task.isCancelled else { return }
            pickAgainSoon()
        }
    }

    /// Nothing could be queued: tried again in a little while, since the network or a server
    /// may be back by then. A pick that lands after the song on has ended plays at once.
    private func pickAgainSoon() {
        guard pickAgain == nil else { return }
        pickAgain = Task {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            pickAgain = nil
            topUpLiveIfNeeded()
        }
    }

    private func cancelPickAgain() {
        pickAgain?.cancel()
        pickAgain = nil
    }

    /// A pick waiting to be tried again. See ``pickAgainSoon()``.
    @ObservationIgnored private var pickAgain: Task<Void, Never>?
    /// The moment Tracks Radio last set out to follow, so a moment it couldn't be made for isn't
    /// tried again on every change, only once the moment changes.
    @ObservationIgnored private var followedMoment: RadioMoment?

    /// Makes Tracks Radio again once the moment it was made for has passed: the hour turned, or
    /// a drive started or ended. The song queued next stays; the one after fits the new moment.
    private func followTheMoment() {
        guard isPlayingTracksRadio, nextEngine == nil, let live else { return }
        let moment = TracksRadioSource.moment(drive: drive)
        // Once for each moment: a retune under way isn't started again, nor one that found
        // nothing to play for it.
        guard live.moment != moment, followedMoment != moment else { return }
        followedMoment = moment
        Task { await retuneTracksRadio() }
    }

    /// Up Next on Tracks Radio getting songs ready: a song that plays at once comes next, and a
    /// new find is got ready behind it, moving up once it's here. Each is picked as the one
    /// before starts, from what's been skipped and played through so far.
    private func topUpReadyFirst(_ radio: any RadioDownloads) {
        guard livePick == nil, current != nil, live != nil else { return }
        livePickCount += 1
        let pickID = livePickCount
        let engine = self.engine
        let canPlay: (MixSong) -> Bool = { engine.canPlayNow($0) }
        livePick = Task {
            defer { if livePickCount == pickID { livePick = nil } }
            // Let go of a find that's waited too long: its server couldn't get it.
            let now = Date.now
            if let stale = upNext.indices.first(where: { index in
                waitingSince[upNext[index].songIdentity].map { now.timeIntervalSince($0) > Self.longestWait } ?? false
            }) {
                let track = upNext[stale]
                radio.decline(HistorySong(track))
                waitingSince[track.songIdentity] = nil
                engine.removeUpNext(at: IndexSet(integer: stale))
            }
            // The radio's own songs in Up Next. Songs you've queued stay ahead of them.
            let picks = upNext.filter { live?.hasPicked($0.songIdentity) == true }
            var couldNotPick = false
            // Next of its own, a song that plays at once, unless its next already does.
            if picks.first.map({ !radio.isReady(HistorySong($0)) }) ?? true {
                if let song = live?.next(where: { radio.isReady(HistorySong($0)) }) {
                    do {
                        try await engine.enqueue(.history([HistorySong(song)]), next: false)
                        lastLivePick = song.songIdentity
                        playAhead(of: picks.first, song)
                    } catch {
                        live?.release(song.songIdentity)
                        couldNotPick = true
                    }
                } else if picks.isEmpty {
                    // Nothing on this iPhone left to pick: the next song streams.
                    if let song = live?.next(playable: canPlay) {
                        do {
                            try await engine.enqueue(.history([HistorySong(song)]), next: false)
                            lastLivePick = song.songIdentity
                        } catch {
                            live?.release(song.songIdentity)
                            couldNotPick = true
                        }
                    } else {
                        couldNotPick = true
                    }
                }
            }
            guard !Task.isCancelled, liveGetsReady else { return }
            // Behind it, a new find being got ready, one at a time.
            if !upNext.contains(where: { waitingSince[$0.songIdentity] != nil }),
               let find = live?.next(newFinds: true, where: { !radio.isReady(HistorySong($0)) && canPlay($0) }) {
                radio.prepare(HistorySong(find))
                waitingSince[find.songIdentity] = .now
                do {
                    try await engine.enqueue(.history([HistorySong(find)]), next: false)
                } catch {
                    radio.decline(HistorySong(find))
                    waitingSince[find.songIdentity] = nil
                }
            }
            if couldNotPick, !Task.isCancelled { pickAgainSoon() }
        }
    }

    /// Moves a song just added to the end of Up Next ahead of the radio's song still coming
    /// down, so it plays first, and stays behind any you've queued.
    private func playAhead(of waiting: PlayerTrack?, _ song: MixSong) {
        guard let waiting,
              let from = upNext.lastIndex(where: { $0.songIdentity == song.songIdentity }),
              let to = upNext.firstIndex(where: { $0.id == waiting.id }), from > to
        else { return }
        engine.moveUpNext(from: IndexSet(integer: from), to: to)
    }

    /// A new find waiting in Up Next is ready: it plays next, rather than waiting behind the
    /// songs picked to play while it came down.
    private func songReady(_ identity: String) {
        guard liveGetsReady, waitingSince[identity] != nil,
              let position = upNext.firstIndex(where: { $0.songIdentity == identity })
        else { return }
        waitingSince[identity] = nil
        // Ahead of the radio's other songs, and behind any you've queued.
        let first = live.flatMap { live in upNext.firstIndex { live.hasPicked($0.songIdentity) } } ?? 0
        if position > first { engine.moveUpNext(from: IndexSet(integer: position), to: first) }
        // Another find to get ready behind it.
        topUpLiveIfNeeded()
    }

    /// With Delete After Playing on, a find Tracks Radio downloaded to play has its download
    /// removed once it's given way, and is kept a while in Up Next to keep after all.
    private func removeIfPlayedOnce(_ track: PlayerTrack) {
        guard context?.kind == .endless, let radioDownloads,
              radioDownloads.finishedPlaying(HistorySong(track))
        else { return }
        playedAndRemoved.removeAll { $0.songIdentity == track.songIdentity }
        playedAndRemoved.insert(track, at: 0)
        if playedAndRemoved.count > 8 { playedAndRemoved.removeLast() }
    }

    /// Keeps a song Tracks Radio played and removed: downloaded again, and kept.
    func keepPlayed(_ track: PlayerTrack) {
        radioDownloads?.keep(HistorySong(track))
        playedAndRemoved.removeAll { $0.songIdentity == track.songIdentity }
        confirm(String(localized: "Keeping \u{201C}\(track.title)\u{201D}"))
    }

    /// How long a new find waits in Up Next to be ready before it's let go.
    private static let longestWait: TimeInterval = 20 * 60

    /// Previous well into a live mix's song starts it over: wanting to hear it again, which
    /// says more than letting it play.
    private func noteReplayIfRestarting() {
        guard picksLive, let current, live?.knows(current.songIdentity) == true,
              let lastSample, lastSample.trackID == current.id, lastSample.time >= Self.restartsAfter
        else { return }
        live?.noteReplayed(current.songIdentity)
        followSteering()
    }

    /// How far into a song Previous starts it over, rather than going back a song.
    private static let restartsAfter: TimeInterval = 3

    /// Tells the live mix how a song went, so the next picks follow.
    private func noteLive(_ track: PlayerTrack, _ listen: LiveMix.Listen) {
        guard picksLive else { return }
        live?.note(listen, of: track.songIdentity)
        followSteering()
    }

    /// Why a song the live mix or Autoplay picked came up, for Up Next to say. Nil for a song
    /// you queued, or one with nothing that stands out.
    func pickReason(for track: PlayerTrack) -> LiveMix.Reason? {
        guard picksLive, let live, live.hasPicked(track.songIdentity) else { return nil }
        // Autoplay counts the songs it follows on from as picked too; only its own say why.
        if isAutoplaying, !isAutoplayPick(track) { return nil }
        return live.reason(for: track.songIdentity)
    }

    /// The song the live mix last put in Up Next, so only its own pick, never one you queued,
    /// makes way for another.
    @ObservationIgnored private var lastLivePick: String?

    /// The songs asked for more like this listen, so asking shows as done.
    private(set) var moreLikeThis: Set<String> = []

    /// Whether the song on can steer what's picked next: a song of a live mix like Tracks Radio,
    /// or one of Autoplay's own. Not a song of the queue Autoplay follows on from, which its
    /// mix doesn't know.
    var canAskForMoreLikeThis: Bool {
        guard picksLive, let current, let live else { return false }
        return live.knows(current.songIdentity)
    }

    /// The song on is one to hear more like: its artist and genre come up more for the rest of
    /// the listen, as loving it would, without making it a favorite or adding it anywhere.
    func playMoreLikeThis() {
        guard canAskForMoreLikeThis, let current, !moreLikeThis.contains(current.songIdentity) else { return }
        moreLikeThis.insert(current.songIdentity)
        live?.noteLoved(current.songIdentity)
        followSteering()
        repickNext(unlessBy: current.artistName)
        confirm(String(localized: "More Like This Coming Up"))
    }

    /// The live mix's song waiting next was picked before what was just asked for: it makes
    /// way for one picked now, so the answer is heard next rather than a song later. Kept when
    /// it's already by the artist asked for. Never a song you queued, nor a new find being got
    /// ready, which is already on its way down.
    private func repickNext(unlessBy artistName: String) {
        guard context?.kind == .endless, livePick == nil, requestsStarting == 0,
              let lastLivePick, waitingSince[lastLivePick] == nil,
              let index = upNext.lastIndex(where: { $0.songIdentity == lastLivePick }),
              upNext[index].artistName != artistName
        else { return }
        self.lastLivePick = nil
        live?.release(lastLivePick)
        // The engine says Up Next has changed, and the mix picks again from there.
        engine.removeUpNext(at: IndexSet(integer: index))
    }

    /// Takes up what the live mix is doing about the songs so far, for Up Next to say. A turn
    /// away after a run of skips is said at once too, so the skips are seen to be heard.
    private func followSteering() {
        // What Tracks Radio has learned, kept for its next listen. Never from sample data.
        if !isDemo, let habits = live?.habits() { TracksRadioSource.keep(habits) }
        let now = live?.steering
        guard now != steering else { return }
        steering = now
        if let now, now.isTurningAway { confirm(now.headline) }
    }

    // MARK: - Autoplay

    /// Whether the songs playing are picked as they play: a live mix, or Autoplay.
    private var picksLive: Bool { context?.kind == .endless || isAutoplaying }

    /// Turns Autoplay on or off, from Up Next's button or Settings. Off takes away what it
    /// has queued; on starts it at once if the queue is already on its last song.
    func setAutoplay(_ isOn: Bool) {
        UserDefaults.standard.set(isOn, forKey: PlayPreferences.autoplayKey)
        if isOn {
            startAutoplayIfNeeded()
            return
        }
        if isAutoplaying {
            let picks = IndexSet(upNext.indices.filter { isAutoplayPick(upNext[$0]) })
            if !picks.isEmpty { engine.removeUpNext(at: picks) }
        }
        endAutoplay()
    }

    /// Whether a song in Up Next is one of Autoplay's.
    func isAutoplayPick(_ track: PlayerTrack) -> Bool {
        isAutoplaying && autoplayPicked.contains(track.songIdentity)
    }

    /// Starts Autoplay once the queue is on its last song, so the first of its songs is
    /// waiting by the time this one ends and plays straight on. Not after a station or a live
    /// mix, which never run out, nor with Repeat on, which goes round again instead.
    private func startAutoplayIfNeeded() {
        guard PlayPreferences.autoplay, !isAutoplaying, autoplayStart == nil, requestsStarting == 0,
              let context, !context.isStation, context.kind != .endless, repeatMode == .off,
              nextEngine == nil, waitingSession == nil, let current, upNext.isEmpty,
              status == .playing || status == .paused,
              autoplayTried != latestRequest, let makeAutoplay
        else { return }
        let request = latestRequest
        autoplayTried = request
        let seeds = Array((queuePlayed + [current]).suffix(8))
        autoplayCount += 1
        let id = autoplayCount
        autoplayStart = Task {
            // One cancelled by endAutoplay can finish after a newer one began: it leaves that be.
            defer { if autoplayCount == id { autoplayStart = nil } }
            var mix = await makeAutoplay(seeds)
            // Nothing like these at all: not tried again for this queue.
            guard !Task.isCancelled, request == latestRequest, !mix.isEmpty else { return }
            // Only onto the queue it was made for, still on its last song. If that's changed
            // while it was made, it's tried again when the queue is next on its last song.
            guard self.current != nil, upNext.isEmpty, PlayPreferences.autoplay, repeatMode == .off else {
                autoplayTried = nil
                return
            }
            for seed in seeds { mix.note(picked: seed.songIdentity) }
            mix.blocked = signals.blocked
            live = mix
            steering = nil
            moreLikeThis = []
            autoplayFollows = context.title
            isAutoplaying = true
            topUpLiveIfNeeded()
        }
    }

    /// Stops Autoplay picking. What it queued stays unless it's being turned off.
    private func endAutoplay() {
        autoplayStart?.cancel()
        autoplayStart = nil
        guard isAutoplaying else { return }
        isAutoplaying = false
        isOnAutoplayPick = false
        autoplayPicked = []
        autoplayFollows = nil
        steering = nil
        moreLikeThis = []
        live = nil
        livePick?.cancel()
        livePick = nil
        cancelPickAgain()
    }

    // MARK: - Saving

    /// Saves songs from the history to the Apple Music library as a new playlist.
    func saveAsPlaylist(named name: String, songs: [HistorySong]) {
        Task {
            do {
                try await MusicKitPlayerEngine.checkAccess()
                let found = try await MusicKitPlaybackService.songs(for: songs.map(\.songID).filter { !$0.isEmpty })
                guard !found.isEmpty else {
                    problem = .nothingToPlay
                    return
                }
                let description = String(localized: "Made by Tracks from your listening.")
                #if os(iOS)
                _ = try await MusicLibrary.shared.createPlaylist(name: name, description: description, items: found)
                #else
                // MusicKit can't make a playlist on the Mac; the writer asks Apple Music directly.
                let writer = MusicKitPlaylistWriter()
                let playlistID = try await writer.createPlaylist(name: name, description: description)
                try await writer.addSongs(ids: found.map(\.id.rawValue), toPlaylist: playlistID)
                #endif
                confirm(String(localized: "Saved to Your Library"))
            } catch {
                report(error, couldnt: String(localized: "Couldn't Save Playlist"))
            }
        }
    }

    /// The sleep timer's moment: stop, and leave the next song at its start.
    private func stopForSleep() {
        sleepTimer = nil
        intendsToPlay = nil
        engine.pause()
        engine.seek(to: 0)
    }

    /// Records a skip when the song gave way early, and not because a new request replaced it.
    private func noteLeaving(_ track: PlayerTrack) {
        let wentBack = isGoingBack
        let autoSkipped = isAutoSkipping
        isGoingBack = false
        isAutoSkipping = false
        defer { lastSample = nil }
        notePassedOver(track)
        guard !wentBack, !autoSkipped, Date.now > replacingQueueUntil, context?.isStation != true,
              let lastSample, lastSample.trackID == track.id
        else { return }
        let listen = LiveMix.Listen(playedFor: lastSample.time, duration: track.duration)
        noteLive(track, listen)
        guard listen == .skipped else { return }
        signals.recordSkip(of: track.songIdentity)
        signalsStore.save(signals)
    }

    /// A song from Apple Music left before it counted, however it went: Apple lists it as
    /// played the moment it starts, and the next import of that list, here or on another of
    /// the user's devices, mustn't count it.
    private func notePassedOver(_ track: PlayerTrack) {
        guard !isDemo, track.local == nil else { return }
        let settings = CaptureSettings()
        let playedFor = lastSample.flatMap { $0.trackID == track.id ? $0.time : nil } ?? 0
        guard playedFor < settings.minimumListen(forDuration: track.duration)
            || ListeningSignals.isSkip(playedFor: playedFor, duration: track.duration)
        else { return }
        settings.notePassedOver(title: track.title, artistName: track.artistName)
    }

    /// Samples the position once a second while playing, and checks the sleep timer. Stops
    /// when there's nothing to watch, so a paused player costs nothing.
    private func startTickerIfNeeded() {
        let needed = status == .playing || sleepTimer != nil
        guard needed else {
            ticker?.cancel()
            ticker = nil
            return
        }
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func tick() {
        if let current, status == .playing {
            let time = engine.playbackTime
            // The same song back at its start after nearly finishing: Repeat One looped it,
            // which is the end of a song even though nothing changed.
            if sleepTimer == .endOfSong, let lastSample, lastSample.trackID == current.id,
               let duration = current.duration, lastSample.time > duration - 5, time < lastSample.time - 5 {
                self.lastSample = nil
                stopForSleep()
                return
            }
            lastSample = (current.id, time)
            // Autoplay turned on or off in Settings takes effect while the song plays, not only
            // when the next one starts.
            if !isAutoplaying {
                startAutoplayIfNeeded()
            } else if !PlayPreferences.autoplay {
                setAutoplay(false)
            }
            // Now and then while playing, so a Mac that loses power, or an app that's ended
            // without warning, still picks up close to where it was.
            savesIn -= 1
            if savesIn <= 0 {
                savesIn = 30
                scheduleSave()
            }
        } else if sleepTimer == .endOfSong, status != .loading, upNext.isEmpty,
                  let current, let lastSample, lastSample.trackID == current.id,
                  let duration = current.duration, lastSample.time > duration - 3 {
            // The last song of the queue ran out: the timer has nothing left to wait for.
            sleepTimer = nil
        }
        if case .at(let end) = sleepTimer, Date.now >= end {
            sleepTimer = nil
            intendsToPlay = nil
            engine.pause()
        }
        if status != .playing, sleepTimer == nil {
            ticker?.cancel()
            ticker = nil
        }
    }

    /// Ticks until the next save while playing.
    @ObservationIgnored private var savesIn = 30

    private func report(_ error: any Error) {
        // Overtaken by something newer, which speaks for itself.
        if !(error is PlayerProblem), PlaybackFailure(error) == .superseded { return }
        intendsToPlay = nil
        problem = PlayerProblem(error)
    }

    /// For something other than playing, which leaves what's playing as it is.
    private func report(_ error: any Error, couldnt title: String) {
        problem = PlayerProblem(error, couldnt: title)
    }
}

/// Keeps ``ListeningSignals`` on this device, in the app's own defaults.
struct SignalsStore {
    var defaults: UserDefaults = .standard
    static let key = "playListeningSignals"

    func load() -> ListeningSignals {
        guard let data = defaults.data(forKey: Self.key),
              let signals = try? JSONDecoder().decode(ListeningSignals.self, from: data)
        else { return ListeningSignals() }
        return signals
    }

    func save(_ signals: ListeningSignals) {
        guard let data = try? JSONEncoder().encode(signals) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
