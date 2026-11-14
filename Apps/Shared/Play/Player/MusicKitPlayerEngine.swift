import Foundation
import MusicKit
import Observation
import SwiftUI
import TracksCore
import TracksMusic

/// Plays through MusicKit's application player: Apple Music, inside Tracks.
///
/// It keeps playing in the background (the app declares background audio), which is what lets
/// Tracks keep every song it plays. The lock screen, Control Center and AirPlay come with it.
///
/// On the Mac the player isn't touched until Tracks first plays something (see
/// `TracksPlayerContext.isInUse`), so someone who only plays music in Music keeps their media
/// keys there. On iPhone it's first reached once launch has settled, and every call to it waits
/// out a scene change, which a call reconnecting to Apple's player service can outlast (see
/// ``PlayerQuiet``).
@MainActor
final class MusicKitPlayerEngine: PlayerEngine {
    var onChange: (() -> Void)?

    private(set) var current: PlayerTrack?
    private(set) var upNext: [PlayerTrack] = []
    /// Requests between being made and the player starting, while songs are looked up. A
    /// count, since a second request can arrive before the first has started.
    private var starting = 0
    /// Counts play requests. A request that a newer one overtook while its songs were looked up
    /// stops there, rather than setting its queue over the newer one's: two queues set one after
    /// the other cut the first one's start short (MPMusicPlayerControllerErrorDomain error 2) and
    /// could leave the older request playing.
    private var latestPlay = 0
    /// The request whose queue has been set and hasn't started yet. Until it has, the player
    /// can pass through the queue's first song on the way to the one asked for, which isn't
    /// shown: the song on changes once, to the one that starts.
    private var queueStarting: Int?
    /// Covers with an ordinary web address for the songs queued, by song id. The player's own
    /// entries often carry a `musicKit://` cover only MusicKit's ArtworkImage can draw, which
    /// can lose its picture as the mini player opens into Now Playing (see ``CoverImage``);
    /// these are drawn from Tracks’ own cache instead.
    private var queuedCovers: [String: Artwork] = [:]
    /// Songs whose catalog cover is being looked up, by song id. A station's songs aren't
    /// known ahead, so their covers are found as each one starts.
    private var coversLookedUp: Set<String> = []
    /// Each entry's track as last made, by entry id. The player reports a change many times a
    /// song, and most of the queue is the same each time.
    private var made: [String: MadeTrack] = [:]
    private var player: ApplicationMusicPlayer { ApplicationMusicPlayer.shared }
    private var watch: Task<Void, Never>?

    init() {
        TracksPlayerContext.whenInUse { [weak self] in self?.follow() }
    }

    /// Follows the player's queue and state, once it's in use.
    private func follow() {
        guard watch == nil else { return }
        watch = Task { [weak self] in
            guard let player = self?.player else { return }
            let changes = Observations {
                QueueState(
                    entryIDs: player.queue.entries.map(\.id),
                    currentID: player.queue.currentEntry?.id,
                    // An entry resolves from a bare title to its song a moment after it starts.
                    currentIsResolved: player.queue.currentEntry?.item != nil,
                    status: player.state.playbackStatus,
                    shuffle: player.state.shuffleMode,
                    repeatMode: player.state.repeatMode
                )
            }
            for await _ in changes {
                guard let self else { return }
                self.refreshWhenQuiet()
            }
        }
    }

    private var refreshOwed = false

    /// The player reports many changes at once as it reconnects, often as a scene changes:
    /// they're read once it has settled, in one go.
    private func refreshWhenQuiet() {
        guard !refreshOwed else { return }
        refreshOwed = true
        PlayerQuiet.run { [weak self] in
            self?.refreshOwed = false
            self?.refresh()
        }
    }

    private struct QueueState: Equatable {
        let entryIDs: [String]
        let currentID: String?
        let currentIsResolved: Bool
        let status: MusicPlayer.PlaybackStatus
        let shuffle: MusicPlayer.ShuffleMode?
        let repeatMode: MusicPlayer.RepeatMode?
    }

    // MARK: - State

    // Reads of the player are as dangerous as calls to it: either can reconnect to Apple's
    // player service and hold the main thread for seconds, and inside a scene update iOS ends
    // the app for it (0x8BADF00D). So each read is kept, and while ``PlayerQuiet`` holds work
    // back the kept one answers instead, the time carried on by the clock if it was playing.
    // The time is only ever read off the main thread (see ``readTime()``): asking for it waits
    // on the service every time a song changes.

    /// The player as last read.
    private struct Reading {
        var playbackStatus: MusicPlayer.PlaybackStatus = .stopped
        var shuffle: MusicPlayer.ShuffleMode?
        var repeatMode: MusicPlayer.RepeatMode?
        var time: TimeInterval = 0
        var timeReadAt = ContinuousClock.now
    }

    private var reading = Reading()

    /// Whether the player can be read now: it's in use, and no scene is changing.
    private var canRead: Bool { TracksPlayerContext.isInUse && !PlayerQuiet.isQuiet }

    var status: PlayerStatus {
        if starting > 0 { return .loading }
        guard TracksPlayerContext.isInUse else { return .stopped }
        if canRead { note(player.state.playbackStatus) }
        switch reading.playbackStatus {
        case .playing, .seekingForward, .seekingBackward: return .playing
        case .paused, .interrupted: return current == nil ? .stopped : .paused
        case .stopped: return current == nil ? .stopped : .paused
        @unknown default: return current == nil ? .stopped : .paused
        }
    }

    var playbackTime: TimeInterval {
        guard TracksPlayerContext.isInUse else { return 0 }
        if canRead, ContinuousClock.now - reading.timeReadAt >= Self.timeReadInterval { readTime() }
        return lastKnownPlaybackTime
    }

    /// How long the clock carries the time on before the player is asked again. Playing, the
    /// two agree; this only bounds how late a seek from elsewhere, such as Control Center,
    /// shows.
    private static let timeReadInterval: Duration = .seconds(1)

    private var timeRead: Task<Void, Never>?
    /// Moves on whenever the time is set here, so a read that started before doesn't undo it.
    private var timeGeneration = 0
    /// Whether the time was set, while a read was under way, by a change the player made
    /// itself, and so wants reading again once that one is back.
    private var readsAgain = false

    /// Asks the player for the time off the main thread, and keeps the answer.
    private func readTime() {
        guard timeRead == nil else { return }
        readsAgain = false
        let generation = timeGeneration
        timeRead = Task { [weak self] in
            let time = await PlayerReads.run { ApplicationMusicPlayer.shared.playbackTime }
            guard let self else { return }
            self.timeRead = nil
            guard generation == self.timeGeneration else {
                if self.readsAgain, self.canRead { self.readTime() }
                return
            }
            self.reading.time = time.isFinite ? max(0, time) : 0
            self.reading.timeReadAt = .now
        }
    }

    /// Sets the time without asking the player, as a seek or a new song moves it. `check` asks
    /// the player straight away, for changes the player made itself: one Tracks just asked for
    /// may not have reached it yet, so it waits for the next read.
    private func setTime(_ time: TimeInterval, check: Bool) {
        timeGeneration &+= 1
        reading.time = time
        reading.timeReadAt = .now
        readsAgain = check && timeRead != nil
        if check, canRead { readTime() }
    }

    /// Keeps a new status, carrying the time on by the clock up to the change so it doesn't
    /// jump back while the player is asked.
    private func note(_ status: MusicPlayer.PlaybackStatus) {
        guard status != reading.playbackStatus else { return }
        let time = lastKnownPlaybackTime
        reading.playbackStatus = status
        setTime(time, check: true)
    }

    /// The time as last read, moved on by the clock while playing, without touching the
    /// player: for saving where the music is as the app leaves.
    var lastKnownPlaybackTime: TimeInterval {
        guard reading.playbackStatus == .playing else { return reading.time }
        let since = ContinuousClock.now - reading.timeReadAt
        let time = reading.time + Double(since.components.seconds) + Double(since.components.attoseconds) / 1e18
        guard let duration = current?.duration, duration > 0 else { return time }
        return min(time, duration)
    }

    var isShuffled: Bool {
        guard TracksPlayerContext.isInUse else { return false }
        if canRead { reading.shuffle = player.state.shuffleMode }
        return reading.shuffle == .songs
    }

    var repeatMode: PlayerRepeat {
        guard TracksPlayerContext.isInUse else { return .off }
        if canRead { reading.repeatMode = player.state.repeatMode }
        return switch reading.repeatMode {
        case .one: .one
        case .all: .all
        default: .off
        }
    }

    private func refresh() {
        guard queueStarting == nil else {
            onChange?()
            return
        }
        let entries = Array(player.queue.entries)
        let currentEntry = player.queue.currentEntry
        var kept: [String: MadeTrack] = [:]
        func track(_ entry: MusicPlayer.Queue.Entry) -> PlayerTrack {
            let made = self.track(from: entry, isCurrent: entry.id == currentEntry?.id)
            kept[entry.id] = made
            return made.track
        }
        let previousID = current?.id
        current = currentEntry.map(track)
        // A new song starts from its beginning; the player is asked for the exact time.
        if current?.id != previousID { setTime(0, check: true) }
        if TracksPlayerContext.isStation {
            upNext = []
            // A station can play for days, a song every few minutes, and nothing replaces its
            // queue: only the song playing needs its looked-up cover kept.
            let playing = Set(kept.values.compactMap(\.songID))
            if queuedCovers.keys.contains(where: { !playing.contains($0) }) {
                queuedCovers = queuedCovers.filter { playing.contains($0.key) }
            }
            coversLookedUp.formIntersection(playing)
        } else if let currentEntry, let index = entries.firstIndex(where: { $0.id == currentEntry.id }) {
            upNext = entries[(index + 1)...].map(track)
        } else {
            upNext = entries.map(track)
        }
        made = kept
        onChange?()
    }

    /// A track as made from an entry, and what it was made from.
    private struct MadeTrack {
        let songID: String?
        let title: String
        let isLive: Bool
        let track: PlayerTrack
    }

    private func track(from entry: MusicPlayer.Queue.Entry, isCurrent: Bool) -> MadeTrack {
        // Reading `item` asks Apple's player service on the main thread, once per entry. Only
        // the current entry's song can change under it (a live station's), so a resolved one
        // further down the queue is taken as made.
        if !isCurrent, let cached = made[entry.id], cached.songID != nil,
           cached.title == entry.title, cached.isLive == TracksPlayerContext.isLiveStation {
            return cached
        }
        var song: Song?
        if case .song(let resolved) = entry.item { song = resolved }
        let isLive = TracksPlayerContext.isLiveStation
        if let cached = made[entry.id], cached.songID == song?.id.rawValue, cached.title == entry.title, cached.isLive == isLive {
            return cached
        }
        let title = song?.title ?? entry.title
        var artwork = song?.artwork ?? entry.artwork
        if artwork.flatMap(Self.loadableCover) == nil, let song {
            if let queued = queuedCovers[song.id.rawValue] {
                artwork = queued
            } else {
                lookUpCover(of: song, for: entry.id)
            }
        }
        let track = PlayerTrack(
            id: entry.id,
            title: title,
            artistName: song?.artistName ?? entry.subtitle ?? "",
            albumTitle: song?.albumTitle,
            cover: artwork.map(CoverArt.artwork) ?? .url(nil, seed: title),
            duration: SongLength.shown(song?.duration, isLiveBroadcast: isLive),
            isExplicit: song?.contentRating == .explicit,
            song: song
        )
        return MadeTrack(songID: song?.id.rawValue, title: entry.title, isLive: isLive, track: track)
    }

    // MARK: - Playing

    func play(_ request: PlayRequest, context: PlayContext, shuffled: Bool) async throws {
        latestPlay += 1
        let playID = latestPlay
        starting += 1
        onChange?()
        defer {
            starting -= 1
            if queueStarting == playID { queueStarting = nil }
            refresh()
        }
        try await Self.checkAccess()
        let allowsExplicit = PlayPreferences.allowsExplicit

        let queue: ApplicationMusicPlayer.Queue
        var systemShuffle = false
        // The song tapped, when it isn't the first: the queue is checked to be on it before
        // any of it plays.
        var startSong: StartSong?
        var queued: [Song] = []
        switch request {
        case .history(let songs, let start):
            let wanted = songs.indices.contains(start) && !shuffled ? songs[start].songID : nil
            let found = try await Self.lookUp(songs)
            let allowed = Self.allowed(found, allowsExplicit: allowsExplicit)
            try Self.checkStart(wanted, in: found.map(\.id.rawValue), allowed: allowed.map(\.id.rawValue))
            let index = allowed.firstIndex { $0.id.rawValue == wanted }
            startSong = StartSong(allowed, at: index)
            queued = allowed
            queue = try await Self.queue(of: allowed, startingAt: index, shuffled: shuffled)
        case .songs(let songs, let start):
            let wanted = songs.indices.contains(start) && !shuffled ? songs[start].id.rawValue : nil
            let allowed = Self.allowed(songs, allowsExplicit: allowsExplicit)
            try Self.checkStart(wanted, in: songs.map(\.id.rawValue), allowed: allowed.map(\.id.rawValue))
            let index = allowed.firstIndex { $0.id.rawValue == wanted }
            startSong = StartSong(allowed, at: index)
            queued = allowed
            queue = try await Self.queue(of: allowed, startingAt: index, shuffled: shuffled)
        case .station(let station):
            // A station can't be filtered ahead of time; the player model skips what's not allowed.
            queue = ApplicationMusicPlayer.Queue(for: [station])
        case .album(let album):
            if allowsExplicit {
                queue = ApplicationMusicPlayer.Queue(for: [album])
                systemShuffle = shuffled
            } else {
                queued = Self.allowed(try await Self.tracks(of: album), allowsExplicit: false)
                queue = try await Self.queue(of: queued, startingAt: nil, shuffled: shuffled)
            }
        case .playlist(let playlist):
            if allowsExplicit {
                queue = ApplicationMusicPlayer.Queue(for: [playlist])
                systemShuffle = shuffled
            } else {
                queued = Self.allowed(try await Self.tracks(of: playlist), allowsExplicit: false)
                queue = try await Self.queue(of: queued, startingAt: nil, shuffled: shuffled)
            }
        case .demoStation, .local:
            throw PlayerProblem.nothingToPlay
        }

        // Every call to the player waits out a scene change: see ``PlayerQuiet``.
        await PlayerQuiet.settled()
        // Overtaken while the songs were looked up: the newer request plays instead.
        guard playID == latestPlay else { throw CancellationError() }

        // Everything about the queue is settled before it's handed over, and nothing touches
        // it after until it plays: a change while it gets ready can start it over from its
        // first song, which is then heard before the one tapped.
        // Counted, so Apple Music's own recommendations and Recently Played learn from it too.
        queue.affectsListeningHistory = true
        #if os(iOS)
        // As MusicKit asks, so the first change already uses it.
        player.transition = PlayPreferences.musicTransition
        #endif
        player.state.shuffleMode = systemShuffle ? .songs : .off
        if context.isStation { player.state.repeatMode = MusicPlayer.RepeatMode.none }
        queueStarting = playID
        queuedCovers = Self.covers(of: queued)
        coversLookedUp = []
        player.queue = queue
        // In the same main-actor turn as the queue change, so nothing reading the player
        // (the capture source, its recheck) can see the new queue under the old flag, or the
        // old song under the new one.
        if context.isStation {
            TracksPlayerContext.playingStation(named: context.title, isLive: request.isLiveBroadcast)
        } else {
            TracksPlayerContext.playingOnDemand()
        }
        try await start(playID, on: startSong)
    }

    /// Starts the queue just set. If starting fails and no newer request is the reason, it's
    /// tried once more, quietly, a moment later: the player often manages it the second time,
    /// after something touched the queue while it was getting ready.
    private func start(_ playID: Int, on startSong: StartSong?) async throws {
        do {
            try await ready(playID, on: startSong)
            try await ApplicationPlayerCommands.play()
            return
        } catch {
            guard playID == latestPlay else { throw CancellationError() }
            guard PlaybackFailure(error).isWorthRetrying else { throw PlayerProblem(error) }
        }
        try? await Task.sleep(for: .milliseconds(400))
        await PlayerQuiet.settled()
        guard playID == latestPlay else { throw CancellationError() }
        do {
            try await ready(playID, on: startSong)
            try await ApplicationPlayerCommands.play()
        } catch {
            guard playID == latestPlay else { throw CancellationError() }
            throw PlayerProblem(error)
        }
    }

    /// A song tapped part way down a list, as the queue was made.
    private struct StartSong {
        let id: String
        let index: Int
        let listCount: Int

        /// Nil for the first song, or none: a queue starts there anyway.
        init?(_ songs: [Song], at index: Int?) {
            guard let index, index > 0 else { return nil }
            id = songs[index].id.rawValue
            self.index = index
            listCount = songs.count
        }
    }

    /// Gets a queue started part way down ready, and puts it on the song tapped if it isn't
    /// already, before any of it plays. Told only where to start, the player can begin on the
    /// queue's first song and move on a moment later, after its first seconds are heard.
    private func ready(_ playID: Int, on startSong: StartSong?) async throws {
        guard let startSong else { return }
        try await ApplicationPlayerCommands.prepare()
        guard playID == latestPlay else { throw CancellationError() }
        let entries = Array(player.queue.entries)
        let currentID = player.queue.currentEntry?.id
        let move = QueueStart.correction(
            wantedID: startSong.id,
            wantedIndex: startSong.index,
            listCount: startSong.listCount,
            entryIDs: entries.map { $0.item?.id.rawValue },
            current: entries.firstIndex { $0.id == currentID }
        )
        if let move { player.queue.currentEntry = entries[move] }
    }

    func enqueue(_ request: PlayRequest, next: Bool) async throws {
        // Songs looked up for the queue that's on now. If another replaces it meanwhile, they
        // aren't added to that one, nor while it's still getting ready to play.
        let queueID = latestPlay
        try await Self.checkAccess()
        let allowsExplicit = PlayPreferences.allowsExplicit
        let songs: [Song]
        switch request {
        case .history(let history, _):
            songs = try await Self.lookUp(history)
        case .songs(let list, _):
            songs = list
        case .album(let album):
            guard !allowsExplicit else {
                await PlayerQuiet.settled()
                guard queueID == latestPlay, starting == 0 else { throw CancellationError() }
                try await ApplicationPlayerCommands.insert([album], next: next)
                refresh()
                return
            }
            songs = try await Self.tracks(of: album)
        case .playlist(let playlist):
            guard !allowsExplicit else {
                await PlayerQuiet.settled()
                guard queueID == latestPlay, starting == 0 else { throw CancellationError() }
                try await ApplicationPlayerCommands.insert([playlist], next: next)
                refresh()
                return
            }
            songs = try await Self.tracks(of: playlist)
        case .station, .demoStation, .local:
            // A station replaces the queue; there's nothing to add it after.
            throw PlayerProblem.nothingToPlay
        }
        let allowed = Self.allowed(songs, allowsExplicit: allowsExplicit)
        guard !allowed.isEmpty else { throw Self.emptyProblem(allowsExplicit: allowsExplicit) }
        await PlayerQuiet.settled()
        try Task.checkCancellation()
        guard queueID == latestPlay, starting == 0 else { throw CancellationError() }
        queuedCovers.merge(Self.covers(of: allowed)) { _, new in new }
        try await ApplicationPlayerCommands.insert(allowed, next: next)
        refresh()
    }

    func pause() {
        // Switching the music source pauses the old player, which may never have played.
        guard TracksPlayerContext.isInUse else { return }
        PlayerQuiet.run { [player] in player.pause() }
    }

    func resume() async throws {
        await PlayerQuiet.settled()
        do {
            try await ApplicationPlayerCommands.play()
        } catch {
            throw PlayerProblem(error)
        }
    }

    func skipToNext() async throws {
        await PlayerQuiet.settled()
        try await ApplicationPlayerCommands.skipToNext()
    }

    /// Back to the start of the song after the first few seconds, as every player does, and
    /// to the song before otherwise.
    func skipToPrevious() async throws {
        await PlayerQuiet.settled()
        if playbackTime > 3 || upNext.isEmpty && TracksPlayerContext.isStation {
            player.restartCurrentEntry()
            setTime(0, check: false)
        } else {
            try await ApplicationPlayerCommands.skipToPrevious()
        }
    }

    func seek(to time: TimeInterval) {
        setTime(max(0, time), check: false)
        PlayerQuiet.run { [player] in player.playbackTime = max(0, time) }
    }

    func setShuffled(_ isShuffled: Bool) {
        PlayerQuiet.run { [player] in player.state.shuffleMode = isShuffled ? .songs : .off }
    }

    func setRepeat(_ mode: PlayerRepeat) {
        let repeatMode: MusicPlayer.RepeatMode = switch mode {
        case .off: .none
        case .all: .all
        case .one: .one
        }
        PlayerQuiet.run { [player] in player.state.repeatMode = repeatMode }
    }

    // Offsets into ``upNext`` are found in the player's own list by entry, not by position:
    // the player's list can have moved on since ``upNext`` was last made from it, and a stale
    // position can name the wrong song or one past the end.

    func jump(toUpNext index: Int) async throws {
        await PlayerQuiet.settled()
        guard upNext.indices.contains(index),
              let entry = player.queue.entries.first(where: { $0.id == upNext[index].id })
        else { return }
        player.queue.currentEntry = entry
        try await ApplicationPlayerCommands.play()
    }

    func removeUpNext(at offsets: IndexSet) {
        let ids = Set(offsets.filter(upNext.indices.contains).map { upNext[$0].id })
        PlayerQuiet.run { [player] in
            let entryIDs = player.queue.entries.map(\.id)
            let places = IndexSet(entryIDs.indices.filter { ids.contains(entryIDs[$0]) })
            guard !places.isEmpty else { return }
            player.queue.entries.remove(atOffsets: places)
        }
    }

    func moveUpNext(from offsets: IndexSet, to destination: Int) {
        let ids = Set(offsets.filter(upNext.indices.contains).map { upNext[$0].id })
        // Before the entry that was at the destination, or at the end.
        let before = upNext.indices.contains(destination) ? upNext[destination].id : nil
        PlayerQuiet.run { [player] in
            let entryIDs = player.queue.entries.map(\.id)
            let places = IndexSet(entryIDs.indices.filter { ids.contains(entryIDs[$0]) })
            guard !places.isEmpty else { return }
            let target = before.flatMap { entryIDs.firstIndex(of: $0) } ?? entryIDs.count
            player.queue.entries.move(fromOffsets: places, toOffset: target)
        }
    }

    // MARK: - Helpers

    /// Asks for Apple Music access if it hasn't been asked, since the person just pressed
    /// Play and the reason is plain. Then makes sure the account can play the catalog.
    static func checkAccess() async throws {
        var authorization = MusicAuthorization.currentStatus
        if authorization == .notDetermined {
            authorization = await MusicAuthorization.request()
        }
        // Screen Time's restriction isn't a switch the person can turn on in Tracks' settings.
        if authorization == .restricted {
            throw PlayerProblem.failed(
                String(localized: "Apple Music is restricted on this device in Screen Time."),
                title: String(localized: "Apple Music Is Restricted")
            )
        }
        guard authorization == .authorized else { throw PlayerProblem.accessDenied }
        // Can't tell offline, and a network hiccup mustn't stop music already downloaded.
        if let subscription = try? await MusicSubscription.current, !subscription.canPlayCatalogContent {
            throw PlayerProblem.needsSubscription(canSubscribe: subscription.canBecomeSubscriber)
        }
    }

    /// History songs as Apple Music songs, in order, leaving out any that can't be found.
    private static func lookUp(_ songs: [HistorySong]) async throws -> [Song] {
        let ids = songs.map(\.songID).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return [] }
        do {
            return try await MusicKitPlaybackService.songs(for: ids)
        } catch {
            throw PlayerProblem(error)
        }
    }

    /// A queue of songs, in order or freshly shuffled. Throws when there's nothing left.
    private static func queue(of songs: [Song], startingAt start: Int?, shuffled: Bool) async throws -> ApplicationMusicPlayer.Queue {
        guard !songs.isEmpty else { throw emptyProblem(allowsExplicit: PlayPreferences.allowsExplicit) }
        if shuffled { return ApplicationMusicPlayer.Queue(for: await fresh(songs)) }
        return ApplicationMusicPlayer.Queue(for: songs, startingAt: start.map { songs[$0] })
    }

    /// The song someone tapped was left out for being explicit: say so, rather than quietly
    /// playing the list from somewhere else.
    private static func checkStart(_ wanted: String?, in all: [String], allowed: [String]) throws {
        guard let wanted, all.contains(wanted), !allowed.contains(wanted) else { return }
        throw PlayerProblem.explicitSong
    }

    /// Everything, or everything but the explicit songs.
    private static func allowed(_ songs: [Song], allowsExplicit: Bool) -> [Song] {
        allowsExplicit ? songs : songs.filter { $0.contentRating != .explicit }
    }

    /// Nothing to play: because every song was explicit, or because none could be found.
    private static func emptyProblem(allowsExplicit: Bool) -> PlayerProblem {
        allowsExplicit ? .nothingToPlay : .onlyExplicit
    }

    /// An album's songs, for playing it without its explicit ones.
    private static func tracks(of album: Album) async throws -> [Song] {
        do {
            return songs(in: try await album.with([.tracks]).tracks)
        } catch {
            throw PlayerProblem(error)
        }
    }

    /// A playlist's songs, every page of them up to a couple of thousand.
    private static func tracks(of playlist: Playlist) async throws -> [Song] {
        do {
            var batch = try await playlist.with([.tracks]).tracks
            var songs = Self.songs(in: batch)
            while let current = batch, current.hasNextBatch, songs.count < 2_000 {
                batch = try await current.nextBatch()
                songs += Self.songs(in: batch)
            }
            return songs
        } catch {
            throw PlayerProblem(error)
        }
    }

    private static func songs(in tracks: MusicItemCollection<Track>?) -> [Song] {
        (tracks ?? []).compactMap { track in
            if case .song(let song) = track { return song }
            return nil
        }
    }

    /// Finds the catalog's cover for a song the player gave only a `musicKit://` one, as a
    /// station's songs come, so the player's background can read its colours, then redraws it.
    private func lookUpCover(of song: Song, for entryID: String) {
        let id = song.id.rawValue
        guard coversLookedUp.insert(id).inserted else { return }
        Task { [weak self] in
            let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: song.id)
            guard let found = try? await request.response().items.first,
                  let self, let artwork = found.artwork, Self.loadableCover(artwork) != nil
            else { return }
            self.queuedCovers[id] = artwork
            self.made[entryID] = nil
            self.refresh()
        }
    }

    /// The songs' covers that have an ordinary web address, by song id.
    private static func covers(of songs: [Song]) -> [String: Artwork] {
        var covers: [String: Artwork] = [:]
        for song in songs {
            if let artwork = song.artwork, loadableCover(artwork) != nil { covers[song.id.rawValue] = artwork }
        }
        return covers
    }

    private static func loadableCover(_ artwork: Artwork) -> URL? {
        CoverImage.loadableURL(of: artwork, pixels: CoverImage.pixels(for: 0))
    }

    /// Off the main actor: it folds every artist's name.
    @concurrent
    private nonisolated static func fresh(_ songs: [Song]) async -> [Song] {
        FreshShuffle.order(songs, artist: { StatsCalculator.folded($0.artistName) }, seed: .random(in: 0...UInt64.max))
    }
}

// MARK: - Audio quality

extension MusicKitPlayerEngine {
    /// What Apple Music is playing at, as the player reports it: Lossless, Dolby Atmos and the
    /// like. The player's state is observable, so a view reading this follows it. Nil when the
    /// player doesn't say, and on the Mac until Tracks has played something, since reaching the
    /// player at all can take the media keys from Music.
    static var playingVariant: AppleMusicVariant? {
        guard TracksPlayerContext.isInUse else { return nil }
        // Kept for while a scene changes, when the player can't be read (see ``playbackTime``).
        guard !PlayerQuiet.isQuiet else { return lastVariant }
        lastVariant = ApplicationMusicPlayer.shared.state.audioVariant.flatMap(AppleMusicVariant.init)
        return lastVariant
    }

    private static var lastVariant: AppleMusicVariant?
}

extension AppleMusicVariant {
    init?(_ variant: AudioVariant) {
        switch variant {
        case .lossless: self = .lossless
        case .highResolutionLossless: self = .hiResLossless
        case .dolbyAtmos: self = .dolbyAtmos
        case .dolbyAudio: self = .dolbyAudio
        case .spatialAudio: self = .spatialAudio
        case .lossyStereo: self = .aac
        @unknown default: return nil
        }
    }
}
