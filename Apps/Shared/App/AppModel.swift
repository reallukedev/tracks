import SwiftUI
import SwiftData
import CoreData
import Observation
import TracksCore
import TracksMusic
import MusicKit

/// Everything the app needs at launch, built once and shared by every scene.
@MainActor
@Observable
final class AppModel {
    /// The real store. `nil` only if it couldn't be opened at all.
    let store: TracksStore?
    let capture: CaptureService?
    let playback: PlaybackController?
    /// Why the store couldn't be opened, for diagnostics. Too technical for the screen.
    let startupError: String?

    /// Mirrors settings and song statuses between the user's devices. Nil in a demo launch,
    /// which must not write anything of the user's to iCloud.
    let settingsSync: SettingsSync?

    /// Folds in the duplicate rows sync produces, as soon as they land rather than on the
    /// next turn of the housekeeping timer.
    let reconciler: SyncReconciler?

    /// Whether iCloud is actually taking this device's changes, which an open store doesn't
    /// prove. Nil in a demo launch.
    let syncMonitor: CloudSyncMonitor?

    /// Importing the Last.fm history. Here rather than in Settings so an import keeps going
    /// when Settings closes. Nil in a demo launch, which mustn't write the account's history.
    let lastFMHistory: LastFMHistorySync?

    /// Bringing history over from Motif, the app Tracks replaces. Here rather than in Settings
    /// so it keeps going when Settings closes.
    private(set) var motifImport: MotifImportState = .idle

    /// True when launched with `-TracksDemoData YES`. The real store is never opened, so a
    /// screenshot session can't touch anyone's history, iCloud or Last.fm.
    let isDemoLaunch: Bool

    let library = Library()

    /// Your other devices running Tracks close by: what they're playing, and their controls.
    let nearby = NearbyDevices()

    /// Tracks’ own player, for the Play tab. One per process, like the capture service.
    let player: PlayerModel
    /// The Play tab's mixes and Apple Music shelves.
    let playFeed: PlayFeed
    /// Songs and artists you've never played that Tracks suggests.
    let discovery: Discovery
    /// Your own music: files on this iPhone and songs on your servers.
    let yourMusic: YourMusic
    /// Your Lidarr, for getting music you don't have yet.
    let lidarr: Lidarr
    /// Apple Music songs downloaded to this iPhone, for Offline Mode.
    #if os(iOS)
    let downloadedSongs: DownloadedSongs
    #endif
    /// The Play tab's stack, so Now Playing can push onto it.
    let playNavigator = PlayNavigator()
    /// The one search, kept while you're away from it.
    let search = SearchSession()
    /// The song Get Info shows, asked for from any menu.
    let songInfo = SongInfoPresenter()

    /// Where Play's music comes from. Changing it changes the player; whatever was playing stops.
    var musicSource: MusicSource = MusicSource.current {
        didSet {
            guard musicSource != oldValue else { return }
            UserDefaults.standard.set(musicSource.rawValue, forKey: MusicSource.storageKey)
            player.use(engine(for: musicSource), keepingWhatsPlaying: switchesQuietly)
            switchesQuietly = false
            if musicSource == .yourMusic { prepareYourMusic() }
        }
    }

    /// Set for the one change a quick switch makes, so what's playing carries on.
    @ObservationIgnored private var switchesQuietly = false

    /// Switches where Play's music comes from without stopping what's playing: the other
    /// source's player takes over from the next thing played. For Quick Switch and Focus.
    func switchSource(to source: MusicSource) {
        guard source != musicSource else { return }
        switchesQuietly = true
        musicSource = source
    }

    /// The player for each source, made when first needed.
    @ObservationIgnored private let appleMusicEngine: any PlayerEngine
    @ObservationIgnored private var yourMusicEngine: (any PlayerEngine)?
    @ObservationIgnored private var hasPreparedYourMusic = false

    /// A page for the main window to open, asked for from outside it (the menu bar's
    /// Your Stats). The window pushes it and clears it.
    var pendingRoute: Route?

    /// The Mac sidebar selection. Lives here so menu commands can change it.
    var sidebarSelection: SidebarItem? = LaunchScene.sidebar.flatMap(SidebarItem.init(rawValue:))
        ?? (LaunchScene.searchText != nil ? .search : SidebarItem.opening)

    /// The iPhone's tab. Lives here so Summary's "See All" can move to Charts, which owns the
    /// full lists, instead of pushing a second copy inside Summary.
    /// A launch link opens on Summary, whose stack it's pushed onto (see `RootView`).
    var selectedTab: AppTab = AppTab(launchName: LaunchScene.tab)
        ?? (LaunchScene.opensSearch || LaunchScene.searchText != nil ? .search : LaunchScene.route != nil ? .summary : AppTab.opening)

    /// Apple Music access, as last read. Summary and Settings explain what it's for and offer
    /// to ask, rather than the app asking out of nowhere at launch.
    private(set) var musicAuthorization: MusicAuthorization.Status = MusicAuthorization.currentStatus

    /// Whether ``startCapture()`` has run. Startup belongs to the process, not to a window:
    /// running it again for each new window would undo a paused capture and start a second
    /// demo feed.
    @ObservationIgnored private var hasStarted = false

    init() {
        isDemoLaunch = DemoMode.isRequestedAtLaunch
        playFeed = PlayFeed(isDemo: isDemoLaunch)
        yourMusic = YourMusic(isDemo: isDemoLaunch)
        lidarr = Lidarr(isDemo: isDemoLaunch)
        yourMusic.lidarr = lidarr
        lidarr.onChange = { [weak yourMusic] in yourMusic?.forgetUnavailable() }
        if isDemoLaunch {
            // Sample songs have no catalog ids and mustn't reach Apple Music, so the demo player
            // only pretends, drawing its stations from the sample history. It stands in for
            // your own music's player too, since the sample files don't exist.
            appleMusicEngine = DemoPlayerEngine { [library] in
                DemoPlayerEngine.stationSongs(from: library.history)
            }
            yourMusicEngine = appleMusicEngine
            player = PlayerModel(engine: appleMusicEngine, isDemo: true)
        } else {
            #if os(iOS)
            TracksPlayerContext.startUsingAfterLaunch()
            #endif
            appleMusicEngine = MusicKitPlayerEngine()
            let startsWithYourMusic = MusicSource.current == .yourMusic
            let local: (any PlayerEngine)? = startsWithYourMusic ? LocalPlayerEngine(music: yourMusic, capture: .yourMusic) : nil
            yourMusicEngine = local
            player = PlayerModel(engine: local ?? appleMusicEngine)
            // The song on when Tracks last closed, paused where it was left.
            player.restoreLastSession()
        }
        discovery = Discovery(feed: playFeed, player: player, isDemo: isDemoLaunch)
        #if os(iOS)
        downloadedSongs = DownloadedSongs(isDemo: isDemoLaunch) { [playFeed] in
            playFeed.mixes.all.flatMap(\.songs)
        }
        #endif
        // Listening before the store opens, since that is when the mirror reports setup.
        let syncMonitor = isDemoLaunch ? nil : CloudSyncMonitor()
        syncMonitor?.start()
        self.syncMonitor = syncMonitor
        do {
            let store = isDemoLaunch ? try DemoMode.makeStore() : try TracksStore.shared()
            // Start watching saves before anything writes. Not in a demo launch, which
            // mustn't open the real store.
            if !isDemoLaunch { _ = WidgetRefresher.shared }
            let capture = isDemoLaunch ? CaptureService(store: store) : try CaptureService.shared()
            let playback = PlaybackController(store: store, service: PlatformPlaybackService.make())
            // The capture service decides when a station has stopped; the controller does
            // the playing. This is the one place that knows about both.
            capture.autoPlayback = { [weak playback] in await playback?.playBackToday() }
            self.store = store
            self.capture = capture
            self.playback = playback
            self.startupError = nil
            self.settingsSync = isDemoLaunch ? nil : SettingsSync.forCurrentBuild()
            self.reconciler = isDemoLaunch ? nil : SyncReconciler(store: store)
            self.lastFMHistory = isDemoLaunch ? nil : LastFMHistorySync(store: store)
            // Starts the first read of the history now, in the background, so it's under way
            // before any screen asks for it.
            library.connect(to: store, looksUpCatalog: !isDemoLaunch)
        } catch {
            self.store = nil
            self.capture = nil
            self.playback = nil
            self.startupError = error.localizedDescription
            self.settingsSync = nil
            self.reconciler = nil
            self.lastFMHistory = nil
        }
        player.makeTracksRadio = TracksRadioSource.make(library: library, discovery: discovery, yourMusic: yourMusic, player: player)
        player.radioDownloads = yourMusic
        player.makeAutoplay = AutoplaySource.make(library: library, yourMusic: yourMusic, player: player)
        player.restartMood = { [weak self] title, first in
            guard let self, let mood = Mood.allCases.first(where: { $0.title == title }) else { return }
            await MoodPlayback.start(mood, model: self, startingWith: first)
        }
        followLibraryAndMixes()
        // Motif's history comes across by itself the first time, a few seconds in, so it
        // doesn't compete with the first read of the history.
        if !isDemoLaunch, MotifImport.shouldRunAutomatically {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                await self?.importFromMotif()
            }
        }
        nearby.onCommand = { [weak player] command in
            switch command {
            case .playPause: player?.togglePlayPause()
            case .next: player?.skipToNext()
            case .previous: player?.skipToPrevious()
            }
        }
        nearby.onPause = { [weak player] in
            if player?.isPlaying == true { player?.togglePlayPause() }
        }
        nearby.onJoin = { [weak self] in self?.tellNearby() }
        nearby.onSeek = { [weak player] position in player?.seek(to: position) }
        nearby.onTakeOver = { [weak self] state, device in
            Task { _ = await self?.play(state, from: device) }
        }
        // Sample data never shows, or forgets, the devices this one really knows.
        if isDemoLaunch { nearby.keepToThisRun() }
        #if DEBUG
        nearby.showSample()
        if UserDefaults.standard.string(forKey: "TracksNearbyDemo") == "control" { controlledDeviceID = "sample" }
        #endif
    }

    /// Tells your other devices what's playing here.
    func tellNearby() {
        nearby.publish(nearbyState ?? NearbyState())
        updateHandoff()
        // Music started here: the player is this device's again.
        if player.isPlaying { controlledDeviceID = nil }
    }

    /// What Tracks is playing, as your other devices are told it. Nil with nothing queued.
    var nearbyState: NearbyState? {
        guard let track = player.current else { return nil }
        return NearbyState(
            title: track.title,
            artist: track.artistName,
            album: track.albumTitle,
            artworkURL: nearbyArtwork(Self.shareableArtwork(track.cover), for: track.title, by: track.artistName),
            isPlaying: player.isPlaying,
            position: player.playbackTime,
            duration: track.duration,
            canSkipBack: player.context?.isStation != true,
            context: player.context.map { NearbyContext($0) },
            // A live mix's picks are its own: the device it moves to picks again.
            upNext: player.isLive ? nil : player.upNext.prefix(NearbyState.carriedSongs).map { NearbySong($0) }
        )
    }

    // MARK: - Your devices, as one player

    @ObservationIgnored private var handoff: NowPlayingHandoff?

    /// Offers what Tracks is playing to your other devices through Handoff, or stops.
    func updateHandoff() {
        guard !isDemoLaunch else { return }
        let handoff = handoff ?? NowPlayingHandoff(deviceName: NearbyDevices.thisDeviceName) { [weak self] in self?.nearbyState }
        self.handoff = handoff
        handoff.update()
    }

    /// Picks up a song another device offered through Handoff, from where it had got to.
    func continueHandoff(_ activity: NSUserActivity) {
        guard let (state, name) = NowPlayingHandoff.song(from: activity) else { return }
        // Nearby too: it's asked to pause, as Play Here does.
        let device = nearby.devices.first { $0.state?.title == state.title && $0.state?.artist == state.artist }
        Task { _ = await play(state, named: device?.name ?? name, pausing: device) }
    }

    /// The device the main player is showing and controlling instead of this one, as Spotify
    /// Connect does. Nil for this device.
    var controlledDeviceID: String?

    /// The device the main player controls, while it still has a song to control.
    var controlledDevice: NearbyDevices.Device? {
        guard let controlledDeviceID else { return nil }
        return nearby.devices.first { $0.id == controlledDeviceID && $0.state?.hasSong == true }
    }

    /// Which of your devices has the music, for the checkmark in Your Devices.
    var musicLocation: MusicLocation {
        MusicLocation(
            controlled: controlledDeviceID,
            isPlayingHere: player.isPlaying,
            hasSongHere: player.hasQueue,
            peers: nearby.devices.map { MusicLocation.Peer(id: $0.id, hasSong: $0.state?.hasSong == true, isPlaying: $0.state?.isPlaying == true) }
        )
    }

    /// Shows and controls another device's song in the main player.
    func control(_ device: NearbyDevices.Device?) {
        controlledDeviceID = device?.id
    }

    /// Moves what's playing here to another device, from where it's got to. It pauses here
    /// once that device says it's playing, so music never stops in both places when the song
    /// can't be found there. The main player goes on showing it, there.
    func sendMusic(to device: NearbyDevices.Device) {
        guard var state = nearbyState else { return }
        state.position = player.playbackTime
        state.isPlaying = true
        state.sentAt = .now
        nearby.handOver(state, to: device)
        controlledDeviceID = device.id
    }

    /// The cover last sent for a song, kept for when a later look at the same song comes back
    /// without one (a paused player can drop its artwork), so the cover on your other devices
    /// stays put rather than blinking out as the song pauses.
    @ObservationIgnored private var lastNearbyArtwork: (song: String, url: String)?

    func nearbyArtwork(_ url: String?, for title: String, by artist: String) -> String? {
        let song = HistoryImport.key(title: title, artistName: artist)
        if let url {
            lastNearbyArtwork = (song, url)
            return url
        }
        return lastNearbyArtwork?.song == song ? lastNearbyArtwork?.url : nil
    }

    /// Plays here what another device is playing, from where it's got to, and pauses it there:
    /// from the music Play is on, or, with Quick Switch, from the other if only it has the song.
    /// Returns whether it could.
    func playHere(from device: NearbyDevices.Device) async -> Bool {
        guard let state = device.state else { return false }
        return await play(state, from: device)
    }

    /// Plays a song another device had on, from where it had got to, and pauses it there.
    func play(_ state: NearbyState, from device: NearbyDevices.Device) async -> Bool {
        await play(state, named: device.name, pausing: device)
    }

    /// Plays a song from another device, by name, pausing it there if it's nearby to ask. With
    /// Bring Up Next on, what it was playing from and the songs after it come too.
    private func play(_ state: NearbyState, named name: String, pausing device: NearbyDevices.Device?) async -> Bool {
        guard let title = state.title, let artist = state.artist else { return false }
        if let device, controlledDeviceID == device.id { controlledDeviceID = nil }
        let carry = state.carry(bringsQueue: NearbyDevices.bringsQueue)
        var sources = [musicSource]
        if QuickSwitch.isOn, QuickSwitch.isAvailable(yourMusic) {
            sources.append(musicSource == .appleMusic ? .yourMusic : .appleMusic)
        }
        for source in sources {
            guard let request = await request(for: title, by: artist, album: state.album, duration: state.duration, in: source) else { continue }
            switchSource(to: source)
            var following: [NearbySong] = []
            switch carry {
            case .live(let live):
                let context = PlayContext(kind: .endless, title: live.title)
                // Tracks Radio and moods start again here; another live mix, or one that can't be
                // made here, leaves the song to play by itself.
                let restarts = context == .tracksRadio || Mood.allCases.contains { $0.title == live.title }
                if restarts, let first = Self.mixSong(for: request),
                   await player.resumeLive(context, startingWith: first), player.current != nil { break }
                await player.start(request, from: .songs(String(localized: "From \(name)")))
            case .queue(let context, let songs):
                following = songs
                await player.start(request, from: context.flatMap { PlayContext($0) } ?? .songs(String(localized: "From \(name)")))
            case .song:
                await player.start(request, from: .songs(String(localized: "From \(name)")))
            }
            // Where it had got to, once it's playing here.
            if let position = state.position(at: .now), position > 3 {
                for _ in 0..<20 where player.status != .playing {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                player.seek(to: position)
            }
            if let device { nearby.pause(device) }
            await queue(following, in: source)
            return true
        }
        return false
    }

    /// A song about to play, as a live mix starts from it.
    private static func mixSong(for request: PlayRequest) -> MixSong? {
        switch request {
        case .local(let tracks, _): tracks.first?.mixSong()
        case .songs(let songs, _): songs.first.map {
            MixSong(
                songIdentity: HistoryImport.key(title: $0.title, artistName: $0.artistName),
                songID: $0.id.rawValue,
                title: $0.title,
                artistName: $0.artistName,
                albumTitle: $0.albumTitle,
                artworkURL: nil,
                plays: 0,
                lastHeard: .distantPast
            )
        }
        default: nil
        }
    }

    /// Queues songs by name behind the one playing, found one by one in the music source.
    /// Stops if something else starts meanwhile, so they never land in a queue of its own.
    private func queue(_ songs: [NearbySong], in source: MusicSource) async {
        guard !songs.isEmpty, let context = player.context else { return }
        for song in songs {
            guard musicSource == source, player.current != nil, player.context == context else { return }
            if let more = await request(for: song.title, by: song.artist, album: song.album, duration: song.duration, in: source),
               musicSource == source, player.context == context {
                player.append(more)
            }
        }
    }

    /// Switches source live and carries on with the same song from the same place, when the
    /// other source has it: "Switch to Your Music" in the car moves the song on to your own
    /// copy without a gap you'd notice. When it doesn't, the song on carries on and the other
    /// source takes over from the next thing played, as Quick Switch does.
    /// - Returns: whether the song on carried over.
    @discardableResult
    func switchSourceCarryingOn(to source: MusicSource) async -> Bool {
        guard source != musicSource else { return false }
        let player = player
        guard let track = player.current, player.status == .playing || player.status == .paused else {
            switchSource(to: source)
            return false
        }
        let wasPlaying = player.status == .playing
        let position = player.playbackTime
        let wasLive = player.isLive
        let following = player.upNext.prefix(NearbyState.carriedSongs).map { NearbySong($0) }
        guard let request = await request(for: track.title, by: track.artistName, album: track.albumTitle, duration: track.duration, in: source) else {
            switchSource(to: source)
            return false
        }
        switchSource(to: source)
        // A plain queue on the other side: a live mix's context would have the player pick
        // for a mix that isn't there.
        await player.start(request, from: .songs(track.title))
        if position > 3 {
            for _ in 0..<20 where player.status != .playing {
                try? await Task.sleep(for: .milliseconds(250))
            }
            player.seek(to: position)
        }
        if !wasPlaying, player.status == .playing { player.togglePlayPause() }
        // What was coming up comes along too, found one by one behind the song already
        // playing; Tracks Radio's picks are followed by Autoplay instead.
        if !wasLive { await queue(following, in: source) }
        return true
    }

    /// A song by name, as the music source plays it.
    private func request(for title: String, by artist: String, album: String?, duration: TimeInterval?, in source: MusicSource) async -> PlayRequest? {
        switch source {
        case .yourMusic:
            guard let track = yourMusic.track(for: HistorySong(songID: "", title: title, artistName: artist, albumTitle: album)) else { return nil }
            return .local([track])
        case .appleMusic:
            guard MusicAuthorization.currentStatus == .authorized,
                  let candidate = try? await CatalogLookup().resolve(CatalogQuery(title: title, artistName: artist, duration: duration, albumTitle: album)),
                  let songs = try? await MusicKitPlaybackService.songs(for: [candidate.id]), !songs.isEmpty
            else { return nil }
            return .songs(songs)
        }
    }

    /// A cover another device can load: Apple Music's, never one from your server, whose
    /// address carries its password.
    private static func shareableArtwork(_ cover: CoverArt) -> String? {
        let url: String?
        switch cover {
        case .artwork(let artwork): url = artwork.url(width: 300, height: 300)?.absoluteString
        case .url(let address, _): url = address
        }
        guard let url, url.hasPrefix("https://"), !url.contains("/rest/") else { return nil }
        return url
    }

    private func engine(for source: MusicSource) -> any PlayerEngine {
        switch source {
        case .appleMusic:
            return appleMusicEngine
        case .yourMusic:
            if let yourMusicEngine { return yourMusicEngine }
            let engine = LocalPlayerEngine(music: yourMusic, capture: .yourMusic)
            yourMusicEngine = engine
            return engine
        }
    }

    /// Reads the Music folder and reaches the servers, once per launch, when Your Music is in
    /// use. Reading again on each return to the app is the window's job.
    func prepareYourMusic() {
        guard !hasPreparedYourMusic else { return }
        #if DEBUG
        if isDemoLaunch {
            // The sample library is made from the sample history, once it's been read.
            guard !library.history.isEmpty else { return }
            hasPreparedYourMusic = true
            yourMusic.fillDemo(from: library.history)
            lidarr.fillDemo(artists: Array(Set(library.history.captures.map(\.artistName))).sorted().prefix(8).map(\.self))
            return
        }
        #endif
        hasPreparedYourMusic = true
        Task {
            await yourMusic.scan()
            await yourMusic.servers.connectAll()
        }
    }

    /// Songs opened in Tracks from elsewhere: copied into Your Music, which becomes the source,
    /// and shown on Play.
    func openInYourMusic(_ urls: [URL]) {
        selectedTab = .play
        sidebarSelection = .listenNow
        musicSource = .yourMusic
        prepareYourMusic()
        Task { await yourMusic.importItems(urls) }
    }

    /// The one model for the process. The phone's window, CarPlay and Siri all need the same
    /// player, so it can't belong to any one scene.
    static let shared = AppModel()

    /// Gets the process ready to play without a window: capture running, and the history's
    /// first read done with the mixes built from it. For Siri and CarPlay, which can start
    /// Tracks in the background.
    func prepareForPlaying() async {
        // Its catch-up can take a while, and nothing here needs to wait for it.
        Task { await startCapture() }
        if musicSource == .yourMusic { prepareYourMusic() }
        // Twenty seconds at most: a long history on a busy phone takes a few.
        for _ in 0..<200 {
            if library.isLoaded, playFeed.builtRevision == library.revision { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var feedFollower: Task<Void, Never>?

    /// Keeps the history and the Play tab's mixes current for as long as the process runs.
    ///
    /// Here rather than on a view, because Tracks also runs with no window at all: playing for
    /// CarPlay, or started by Siri in the background.
    private func followLibraryAndMixes() {
        let center = NotificationCenter.default
        let refreshes: [Notification.Name] = [
            ModelContext.didSave,
            SyncReconciler.didReconcileNotification,
            // Synced rows arrive without a save of any context in this process.
            .NSPersistentStoreRemoteChange,
        ]
        for name in refreshes {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.library.refresh() }
            })
        }
        observers.append(center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.library.invalidate() }
        })

        let (library, player, feed, discovery) = (library, player, playFeed, discovery)
        feedFollower = Task {
            let inputs = Observations { FeedInputs(revision: library.revision, isLoaded: library.isLoaded, signals: player.signals) }
            for await input in inputs where input.isLoaded {
                await feed.rebuild(history: library.history, signals: input.signals, revision: input.revision)
                // Songs just played, and blocked artists, aren't suggestions any more.
                discovery.prune()
            }
        }
        // The suggestions start again whenever your artists' lookups do.
        discoveryFollower = Task {
            let seeds = Observations {
                DiscoverySeeds(hasBuilt: feed.hasBuilt, hasTried: feed.hasTriedArtistLookups, lookups: feed.lookupsRevision)
            }
            for await seed in seeds where seed.hasBuilt {
                await discovery.reseed()
            }
        }
    }

    @ObservationIgnored private var discoveryFollower: Task<Void, Never>?

    private struct DiscoverySeeds: Equatable {
        let hasBuilt: Bool
        let hasTried: Bool
        let lookups: Int
    }

    private struct FeedInputs: Equatable {
        let revision: Int
        let isLoaded: Bool
        let signals: ListeningSignals
    }

    /// Whether Summary has a banner to show: a store that fell back to memory.
    var hasBanner: Bool {
        if !isDemoLaunch, case .inMemory = store?.backing { return true }
        return false
    }

    /// Showing made-up data, which only a demo launch does. Playback, deleting and Last.fm
    /// are switched off.
    var isShowingSampleData: Bool { isDemoLaunch }

    /// Starts capture and catches up on anything missed while the app was closed. Runs once
    /// per process; later calls return straight away. Does nothing in a demo launch.
    func startCapture() async {
        guard !hasStarted else { return }
        hasStarted = true
        if isDemoLaunch, DemoMode.isLiveRequested, let store {
            await DemoMode.runLiveFeed(into: store)
        }
        guard !isDemoLaunch, let capture else { return }
        // Before capture and sync, so the first song is held to the carried-over choice, and
        // it goes up rather than being taken for an unset one.
        CaptureSettings().migrateMinimumListen()
        capture.start()
        // Before the catch-up, so settings another device changed are in force for the
        // captures it is about to make.
        settingsSync?.start()
        reconciler?.start()
        // Doesn't ask for Apple Music access: a prompt at launch arrives with no reason given.
        // Capture works without it. Catalog search, artwork, the playlist and Recently Played
        // fail with `permissionDenied` until it's granted, so the catch-up runs again then.
        await capture.catchUp()
    }

    /// Asks for Apple Music access. Only called from a control that has already said what
    /// the access is for.
    func requestMusicAccess() async {
        let previous = musicAuthorization
        musicAuthorization = await MusicAuthorization.request()
        catchUpIfNewlyAuthorized(since: previous)
    }

    /// Reads access again. It can be changed in Settings while Tracks keeps running.
    func refreshMusicAuthorization() {
        let previous = musicAuthorization
        musicAuthorization = MusicAuthorization.currentStatus
        catchUpIfNewlyAuthorized(since: previous)
    }

    /// The launch catch-up couldn't reach Recently Played or the catalog without access, so
    /// it's worth another go the moment access arrives.
    private func catchUpIfNewlyAuthorized(since previous: MusicAuthorization.Status) {
        guard previous != .authorized, musicAuthorization == .authorized,
              hasStarted, !isDemoLaunch, let capture
        else { return }
        Task { await capture.catchUp() }
    }

    /// Catches up with iCloud when the app comes back to the front.
    ///
    /// Brings Motif's history over. Runs by itself once, and again whenever asked from Settings.
    func importFromMotif() async {
        guard !isDemoLaunch, let store, motifImport != .running else { return }
        motifImport = .running
        do {
            let outcome = try await MotifImport.run(into: store)
            motifImport = .finished(outcome)
            if outcome.plays > 0 {
                player.confirm(String(AttributedString(localized: "Brought Over ^[\(outcome.plays) Play](inflect: true) from Motif").characters))
            }
        } catch MotifImport.Failure.noMotifHistory {
            motifImport = .failed(String(localized: "There’s no Motif history on this device."))
        } catch {
            motifImport = .failed(String(localized: "Couldn’t read Motif’s history. Try again."))
        }
    }

    /// Both sides go quiet while the app is away (iOS suspends it, and a Mac window can sit
    /// closed for days), so this is where the user is most likely to be looking at stale
    /// settings or at rows another device has already merged.
    func syncOnForeground() {
        guard !isDemoLaunch else { return }
        refreshMusicAuthorization()
        settingsSync?.reconcileAll()
        reconciler?.reconcile()
    }
}

/// Where bringing over Motif's history has got to. See ``MotifImport``.
enum MotifImportState: Equatable {
    case idle
    case running
    case finished(MotifImport.Outcome)
    case failed(String)
}

/// The iPhone's tabs.
enum AppTab: String, Hashable {
    case summary, play, history, charts
    /// Search, at the tab bar's far end, as Music has it.
    case search

    init?(launchName: String?) {
        guard let launchName else { return nil }
        self.init(rawValue: launchName)
    }

    /// Where the app opens, as chosen in Settings: Summary or Play.
    static var opening: AppTab {
        OpeningTab.current.tab
    }

    var title: LocalizedStringKey {
        switch self {
        case .summary: "Summary"
        case .play: "Play"
        case .history: "History"
        case .charts: "Charts"
        case .search: "Search"
        }
    }

    var symbol: String {
        switch self {
        case .summary: "chart.bar.xaxis"
        case .play: "play.circle"
        case .history: "clock.arrow.circlepath"
        case .charts: "list.number"
        case .search: "magnifyingglass"
        }
    }
}

/// The tab Tracks opens to on iPhone, chosen in Settings.
enum OpeningTab: String, CaseIterable, Identifiable {
    case summary, play

    static let storageKey = "openingTab"

    /// Where Tracks opens until it's changed in Settings: Play, the heart of the app.
    static let standard: OpeningTab = .play

    var id: String { rawValue }

    var tab: AppTab {
        switch self {
        case .summary: .summary
        case .play: .play
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .summary: "Summary"
        case .play: "Play"
        }
    }

    static var current: OpeningTab {
        UserDefaults.standard.string(forKey: storageKey).flatMap(OpeningTab.init(rawValue:)) ?? standard
    }
}

/// The Mac sidebar: where to play from, your listening, and the library of the music source.
enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    /// The search page, at the top of the sidebar, as in Podcasts and TV.
    case search
    case listenNow
    case radio
    case summary
    case history
    case topSongs
    case topArtists
    case topAlbums
    /// What came into the library lately, newest first.
    case recentlyAdded
    case playlists
    case albums
    case artists
    case songs
    /// Your Music's downloads from your servers.
    case downloads
    /// Your Lidarr, once it's connected.
    case lidarr

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .search: "Search"
        case .listenNow: "Listen Now"
        case .radio: "Radio"
        case .summary: "Summary"
        case .history: "History"
        case .topSongs: "Top Songs"
        case .topArtists: "Top Artists"
        case .topAlbums: "Top Albums"
        case .recentlyAdded: "Recently Added"
        case .playlists: "Playlists"
        case .albums: "Albums"
        case .artists: "Artists"
        case .songs: "Songs"
        case .downloads: "Downloads"
        case .lidarr: "Lidarr"
        }
    }

    var symbol: String {
        switch self {
        case .search: "magnifyingglass"
        case .listenNow: "play.circle"
        case .radio: "dot.radiowaves.left.and.right"
        case .summary: "chart.bar.xaxis"
        case .history: "clock.arrow.circlepath"
        case .topSongs: "list.number"
        case .topArtists: "person.2"
        case .topAlbums: "rectangle.stack"
        case .recentlyAdded: "clock"
        case .playlists: "music.note.list"
        case .albums: "square.stack"
        case .artists: "music.microphone"
        case .songs: "music.note"
        case .downloads: "arrow.down.circle"
        case .lidarr: "tray.and.arrow.down"
        }
    }

    /// Playing, then your listening, or the other way round: whichever Tracks opens to comes
    /// first, as the iPhone's tabs do. ⌘1 onwards follow this order.
    static func leading(opening: OpeningTab) -> [SidebarItem] {
        let playing: [SidebarItem] = [.listenNow, .radio]
        let listening: [SidebarItem] = [.summary, .history, .topSongs, .topArtists, .topAlbums]
        return opening == .play ? playing + listening : listening + playing
    }

    /// The library of the music source, in Music's order: Apple Music's, or your own music's
    /// with what's downloaded and, once it's connected, Lidarr.
    static func library(for source: MusicSource, hasLidarr: Bool) -> [SidebarItem] {
        let shared: [SidebarItem] = [.recentlyAdded, .artists, .albums, .songs, .playlists]
        return switch source {
        case .appleMusic: shared
        case .yourMusic: shared + [.downloads] + (hasLidarr ? [.lidarr] : [])
        }
    }

    /// Where the window opens when nothing else asks: what Open To chose.
    static var opening: SidebarItem {
        OpeningTab.current == .play ? .listenNow : .summary
    }

    var chart: ChartKind? {
        switch self {
        case .topSongs: .songs
        case .topArtists: .artists
        case .topAlbums: .albums
        default: nil
        }
    }

    /// The sidebar row that shows a chart, for Summary's "See All".
    init(chart: ChartKind) {
        switch chart {
        case .songs: self = .topSongs
        case .artists: self = .topArtists
        case .albums: self = .topAlbums
        }
    }
}
