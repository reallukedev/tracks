import Foundation
import Observation
import TracksCore

/// Your own music, as one library: the files on this iPhone and the songs on your servers,
/// downloaded or not. What the Play tab, Tracks Radio and the player use when Your Music is
/// the source.
@MainActor
@Observable
final class YourMusic {
    /// Everything: files, and every song on your servers.
    private(set) var index = LocalLibraryIndex.empty {
        didSet { indexRevision &+= 1 }
    }
    /// Bumped with each new ``index``, for pages that sort it off the main actor to know
    /// when to again.
    private(set) var indexRevision = 0
    private(set) var isScanning = false
    /// True once the files have been read at least once, so "none" can be told from "not yet".
    private(set) var hasScanned = false
    /// How many songs the last import brought in, for a moment's confirmation.
    private(set) var lastImport: FileScanner.ImportResult?

    let servers: MusicServers
    let downloads: Downloads
    let playlists: Playlists
    let network = NetworkStatus()
    /// What your servers have to find.
    @ObservationIgnored private(set) lazy var discover = ServerDiscovery(music: self, isDemo: isDemo)
    /// Your playlists and Apple Music's, together, when you choose.
    @ObservationIgnored private(set) lazy var playlistMerge = PlaylistMerge(music: self)
    /// Your Lidarr, for songs your servers don't have yet. Set by the app.
    @ObservationIgnored weak var lidarr: Lidarr?
    /// What's known of songs suggested from outside your music, one answer for each song, so
    /// a row redraws when its own song is answered rather than whenever any song is. An answer
    /// from an earlier look stays on screen while it's looked for again.
    @ObservationIgnored private var answers: [String: SongAnswer] = [:]
    /// Goes up whenever answers may have changed: a sync, a download, Lidarr connecting.
    /// Rows looking songs up include it in their task's id, so they look again.
    private(set) var availabilityGeneration = 0
    /// Songs found by searching a server, which its last sync didn't bring in.
    @ObservationIgnored private var foundOnServers: [String: LocalTrack] = [:]
    /// Songs being looked for, by song. See ``check(title:artist:album:)``.
    /// Smart playlists' songs as last matched, by playlist. See ``songs(in:facts:factsRevision:)``.
    @ObservationIgnored var smartPlaylistSongs: [UUID: SmartPlaylistSongs] = [:]
    @ObservationIgnored private var checks: [String: (generation: Int, task: Task<Void, Never>)] = [:]
    /// What each server said when asked for a song, by server and search. See ``songs(on:matching:)``.
    @ObservationIgnored private var serverAnswers: [String: ServerAnswer] = [:]
    /// Kept between launches, so songs looked for last time are answered straight away.
    @ObservationIgnored private let savedAnswers = CacheFile<[String: ServerAnswer]>("server-answers")

    nonisolated struct ServerAnswer: Codable, Sendable {
        let at: Date
        let songs: [SubsonicSong]
    }
    @ObservationIgnored private var serverQuestions: [String: Task<[SubsonicSong]?, Never>] = [:]

    @ObservationIgnored private var files: [String: FileScanner.CachedFile] = [:]
    /// Sample data, which has songs of its own and stands in for Apple Music too.
    @ObservationIgnored let isDemo: Bool
    @ObservationIgnored private var follower: Task<Void, Never>?

    init(isDemo: Bool) {
        self.isDemo = isDemo
        LibraryFolders.prepare()
        servers = MusicServers(isDemo: isDemo)
        downloads = Downloads(servers: servers)
        playlists = Playlists(isDemo: isDemo)
        servers.onStatusChange = { [weak self] in self?.forgetUnavailable() }
        servers.onKeptArrived = { [weak self] in self?.keptArrived($0) }
        downloads.onDownloaded = { [weak self] in self?.onReady?($0.identity) }
        downloads.onAsked = { [weak self] in self?.downloadsAsked($0) }
        #if DEBUG
        if isDemo { return }
        #endif
        serverAnswers = (savedAnswers.load() ?? [:]).filter { Date.now.timeIntervalSince($0.value.at) < Self.answersLast }
        // The files as last read, read off the main actor: a big folder takes a moment.
        loadingFiles = Task { [self] in
            files = await Self.loadFileCache()
            loadingFiles = nil
            await rebuild()
        }
        followServersAndDownloads()
        // Without this, a server out of reach at launch stayed so until pulled to refresh.
        network.onChange = { [weak self] in
            guard let self else { return }
            forgetUnavailable()
            Task { await self.servers.networkChanged() }
        }
    }

    /// The files on this iPhone.
    var fileTracks: [LocalTrack] { index.tracks.filter { !$0.isFromServer } }

    var hasMusic: Bool { !index.isEmpty || !servers.servers.isEmpty }

    // MARK: - Playing

    /// Whether a song can play right now: a file or a download always; a server's song while
    /// its server can be reached.
    func isPlayable(_ track: LocalTrack) -> Bool {
        switch track.origin {
        case .file: return true
        case .server(let serverID, _):
            if downloads.isDownloaded(track.id) { return true }
            guard network.isOnline, servers.client(for: serverID) != nil else { return false }
            switch servers.status[serverID] {
            case .offline, .wrongPassword, .failed: return false
            case .online, .connecting, nil: return true
            }
        }
    }

    /// Every song that can play right now.
    var playableTracks: [LocalTrack] { index.tracks.filter(isPlayable) }

    /// Whether a mix's song can play right now, as ``track(for:)`` would find it. Quick enough
    /// to ask of every song Tracks Radio could pick: it goes by the id and name the mix has.
    func canPlay(_ song: MixSong) -> Bool {
        let exact = index.track(id: song.songID)
        if let exact, isPlayable(exact) { return true }
        let copies = index.tracks(withIdentity: song.songIdentity)
        guard exact == nil, copies.isEmpty else { return copies.contains(where: isPlayable) }
        return foundOnServers[song.songIdentity].map(isPlayable) ?? false
    }

    /// Whether a song is in your music, rather than found on a server that doesn't have it
    /// yet: a server like Octo plays those, but can't hand over their files until it's kept
    /// them.
    func isInYourMusic(_ track: LocalTrack) -> Bool {
        index.track(id: resolved(track).id) != nil
    }

    /// The song as it is in your music. A song a server found for you gets a new id once the
    /// server keeps it: this is that copy, where there is one, so the row found before it
    /// arrived shows its download and plays the file kept, not what was found.
    func resolved(_ track: LocalTrack) -> LocalTrack {
        guard case .server(let serverID, _) = track.origin, index.track(id: track.id) == nil else { return track }
        return index.tracks(withIdentity: track.identity).first { $0.serverID == serverID } ?? track
    }

    /// Where to play a song from, and how it reaches the player: the file, the download, or
    /// the server's stream at the quality set for the network it's on.
    func playback(for track: LocalTrack) -> (url: URL, playback: LocalPlayback)? {
        let track = resolved(track)
        switch track.origin {
        case .file(let path):
            return (LibraryFolders.music.appending(path: path), LocalPlayback(route: .file, original: track.format))
        case .server(let serverID, let songID):
            if let file = downloads.fileURL(for: track.id), let playback = downloads.playback(for: track.id) {
                return (file, playback)
            }
            guard network.isOnline, let client = servers.client(for: serverID) else { return nil }
            let setting = StreamQuality.streaming(onExpensiveNetwork: network.isExpensive)
            let playback = LocalPlayback(
                route: .stream(server: servers.server(serverID)?.name ?? "", network: setting.network, requestedBitRate: setting.quality.maxBitRate),
                original: track.format
            )
            return (client.streamURL(songID: songID, maxBitRate: setting.quality.maxBitRate), playback)
        }
    }

    /// How each song queued in the player is reaching it, by queue entry, for the quality
    /// badge. Kept by the player as it loads each song and hears what arrived.
    var playbacks: [String: LocalPlayback] = [:]

    #if DEBUG
    /// How a sample song would reach the player, for the demo's badge: sample songs have no
    /// file to play, so this is worked out as the player would, without the address.
    func demoPlayback(for track: LocalTrack) -> LocalPlayback {
        guard case .server(let serverID, _) = track.origin else { return LocalPlayback(route: .file, original: track.format) }
        if let playback = downloads.playback(for: track.id) { return playback }
        let setting = StreamQuality.streaming(onExpensiveNetwork: false)
        return LocalPlayback(
            route: .stream(server: servers.server(serverID)?.name ?? "", network: setting.network, requestedBitRate: nil),
            original: track.format
        )
    }
    #endif

    /// A cover's address: a saved picture, or the server's. A server's is always asked for at
    /// one size, drawn smaller where it's small: one download for every place it's shown, and
    /// a server like Octo, which looks each cover up elsewhere, asked once rather than per size.
    func artworkURL(_ artwork: LocalTrack.Artwork?) -> URL? {
        switch artwork {
        case .file(let name): LibraryFolders.artwork.appending(path: name)
        case .server(let serverID, let coverID): servers.client(for: serverID)?.coverArtURL(id: coverID, size: 600)
        case nil: nil
        }
    }

    /// An artist's picture: their server's, where one of your servers has it, otherwise the
    /// cover of one of their albums. Nil draws their initials.
    func artistPicture(for artist: LocalArtist) -> CoverArt? {
        artistPicture(named: artist.name) ?? artworkURL(artist.artwork).map { .url($0.absoluteString, seed: artist.name) }
    }

    /// An artist on a server that isn't in your music: the picture that server has.
    func artistPicture(for artist: ServerArtist) -> CoverArt? {
        artistPicture(named: artist.name) ?? artworkURL(artist.artwork).map { .url($0.absoluteString, seed: artist.name) }
    }

    /// The picture one of your servers has of an artist, by name.
    func artistPicture(named name: String) -> CoverArt? {
        let key = StatsCalculator.folded(name)
        for server in servers.servers {
            guard let cover = servers.artists[server.id]?[key]?.cover,
                  let url = servers.client(for: server.id)?.coverArtURL(id: cover, size: 600) else { continue }
            return .url(url.absoluteString, seed: name)
        }
        return nil
    }

    /// An artist of yours as one of your servers knows them, online, to ask it about them.
    func serverArtist(named name: String) -> (serverID: String, artistID: String)? {
        let key = StatsCalculator.folded(name)
        for server in servers.onlineServers {
            if let ref = servers.artists[server.id]?[key] { return (server.id, ref.id) }
        }
        return nil
    }

    /// The song in your music a history song stands for, if it's here and can play.
    func track(for song: HistorySong) -> LocalTrack? {
        // Played from here, by its own id: found without working out its name again, which is
        // slow to do for every song a mix could pick.
        if let exact = index.track(id: song.songID), isPlayable(exact) { return exact }
        let identity = HistoryImport.key(title: song.title, artistName: song.artistName)
        guard let track = index.track(forSongID: song.songID, identity: identity) else {
            // Found on a server by searching, when it was suggested.
            return foundOnServers[identity].flatMap { isPlayable($0) ? $0 : nil }
        }
        if isPlayable(track) { return track }
        // A server's copy out of reach: a file of the same song will do.
        return index.tracks(withIdentity: identity).first(where: isPlayable)
    }

    // MARK: - Songs from outside

    /// What's known so far of a song suggested from Apple Music's catalog: in your music, in
    /// Lidarr, or not to be had. ``check(title:artist:album:)`` finds out.
    func availability(title: String, artist: String) -> SongAvailability {
        let identity = HistoryImport.key(title: title, artistName: artist)
        if let track = track(for: HistorySong(songID: "", title: title, artistName: artist)) { return .playable(track) }
        guard let stored = answer(for: identity).state else { return .checking }
        // Found to play once, but not now: offline, or its server out of reach.
        if case .playable(let track) = stored, !isPlayable(track) { return .unavailable }
        return stored
    }

    /// A song's answer, made the first time it's asked about.
    private func answer(for identity: String) -> SongAnswer {
        if let answer = answers[identity] { return answer }
        let answer = SongAnswer()
        answers[identity] = answer
        return answer
    }

    /// Keeps what a look found, redrawing the song's rows only if it's news.
    private func record(_ state: SongAvailability, for identity: String, generation: Int) {
        let answer = answer(for: identity)
        answer.generation = generation
        if answer.state != state { answer.state = state }
    }

    /// Looks up the first few of a list at once, for Only Music I Have, which shows only what's
    /// known to be yours.
    func check(_ songs: [(title: String, artist: String, album: String?)]) async {
        await withTaskGroup(of: Void.self) { group in
            for (offset, song) in songs.enumerated() {
                // A handful at a time, so a long list doesn't ask everything at once.
                if offset >= 6 { await group.next() }
                group.addTask { await self.check(title: song.title, artist: song.artist, album: song.album) }
            }
        }
    }

    /// Whether a "not here" answer can be trusted: no server still connecting, and Lidarr, if
    /// it's set up, answering with its artists known.
    private var canSayUnavailable: Bool {
        let serversSettled = !servers.servers.contains { servers.status[$0.id] == .connecting || servers.status[$0.id] == nil && servers.client(for: $0.id) != nil }
        guard let lidarr, lidarr.isSetUp else { return serversSettled }
        switch lidarr.status {
        case .connected: return serversSettled && lidarr.isReady
        case .off, .connecting: return false
        case .wrongKey, .failed: return serversSettled
        }
    }

    /// Looks for a song: in your music, then on each server, then in Lidarr.
    func check(title: String, artist: String, album: String?) async {
        let identity = HistoryImport.key(title: title, artistName: artist)
        let generation = availabilityGeneration
        guard answer(for: identity).generation != generation else { return }
        #if DEBUG
        if isDemo {
            // Sample data has no server or Lidarr to ask: a mix of answers, the same each time.
            let samples: [SongAvailability] = [.inLidarr(album: album ?? title), .comingFromLidarr, .unavailable, .unavailable]
            record(samples[abs(GeneratedCover.hash(identity)) % samples.count], for: identity, generation: generation)
            return
        }
        #endif
        if let track = track(for: HistorySong(songID: "", title: title, artistName: artist)) {
            record(.playable(track), for: identity, generation: generation)
            return
        }
        // Its own task, so a row that stops looking, as every row does when a server connects
        // or a sync ends, doesn't leave the song unanswered; a second look waits for the first.
        if let running = checks[identity] {
            await running.task.value
            // Begun before a server or Lidarr came along, its answer may be out of date.
            if running.generation != availabilityGeneration {
                await check(title: title, artist: artist, album: album)
            }
            return
        }
        let running = Task {
            await lookFor(title: title, artist: artist, album: album, identity: identity, generation: generation)
            checks[identity] = nil
        }
        checks[identity] = (generation, running)
        await running.value
    }

    private func lookFor(title: String, artist: String, album: String?, identity: String, generation: Int) async {
        // A server that couldn't answer, or a look given up on, says nothing about whether it
        // has the song: only a real "no" from every server makes one unavailable.
        var couldNotAsk = false
        for server in servers.onlineServers {
            // The artist's songs first: suggestions come a few to an artist, and one answer,
            // shared with Picked for You, settles them all. Then the song itself.
            let byArtist = await serverSongs(on: server.id, matching: artist, count: Self.artistSongCount)
            var match = byArtist.flatMap { ServerSongMatcher.bestMatch(title: title, artist: artist, in: $0) }
            if match == nil {
                let bySong = await serverSongs(on: server.id, matching: "\(title) \(artist)")
                match = bySong.flatMap { ServerSongMatcher.bestMatch(title: title, artist: artist, in: $0) }
                if byArtist == nil, bySong == nil { couldNotAsk = true }
            }
            if let match {
                let track = index.track(id: LocalTrack.id(for: .server(serverID: server.id, songID: match.id))) ?? match.track(on: server.id)
                foundOnServers[identity] = track
                record(.playable(track), for: identity, generation: generation)
                return
            }
        }
        switch await lidarr?.state(ofSong: title, by: artist, album: album) ?? .none {
        case .collected(let album): record(.inLidarr(album: album), for: identity, generation: generation)
        case .wanted: record(.comingFromLidarr, for: identity, generation: generation)
        case .none:
            // Only once everything that could say otherwise has answered; until then the last
            // answer stays, and the next look, when they have, settles it.
            if canSayUnavailable, !couldNotAsk { record(.unavailable, for: identity, generation: generation) }
        }
    }

    /// How long a server's answer stands. A song it gets later is found anyway: it's in your
    /// music once a sync brings it in, and that's looked at first.
    private static let answersLast: TimeInterval = 12 * 60 * 60

    /// A server's songs for a search: what it said in the last twelve hours, or what it says now,
    /// asked a few at a time. Nil when it couldn't answer or the look was given up on.
    ///
    /// Remembered because songs are looked for again after every sync and download, and a
    /// server like Octo takes seconds to answer each, looking every song up on Last.fm,
    /// Deezer and YouTube; asked for dozens at once, it's turned away by Deezer and slows to
    /// a crawl.
    /// Songs asked for when searching by an artist: enough that a server like Octo, which keeps
    /// the first twelve for what the library has, hands back dozens of the artist's songs.
    static let artistSongCount = 50

    func serverSongs(on serverID: String, matching query: String, count: Int = 20) async -> [SubsonicSong]? {
        let key = "\(serverID)\u{1F}\(count)\u{1F}\(query)"
        if let answer = serverAnswers[key], Date.now.timeIntervalSince(answer.at) < Self.answersLast {
            return answer.songs
        }
        // Already being asked: a row that looks again, as every row does when a server
        // connects or a sync ends, waits for that answer rather than asking afresh.
        if let asking = serverQuestions[key] { return await asking.value }
        guard let client = servers.client(for: serverID) else { return nil }
        let lookups = servers.lookups
        // Its own task, so a row that stops looking doesn't take the answer with it: Octo
        // would have done the work for nothing, and the next look would ask again.
        let asking = Task { () -> [SubsonicSong]? in
            // At least twenty, so a server like Octo has room beside the library's matches for
            // songs it can find: it keeps the first twelve for what the library has.
            try? await lookups.run { try await client.search(query, artists: 0, albums: 0, songs: count).songs }
        }
        serverQuestions[key] = asking
        let found = await asking.value
        serverQuestions[key] = nil
        if let found {
            // Out-of-date answers go too, or a Mac left running for weeks keeps every search.
            serverAnswers = serverAnswers.filter { Date.now.timeIntervalSince($0.value.at) < Self.answersLast }
            serverAnswers[key] = ServerAnswer(at: .now, songs: found)
            if !isDemo { savedAnswers.save(serverAnswers) }
        }
        return found
    }

    /// Brings a song Lidarr has into your music: syncs your servers, which play Lidarr's
    /// library, then downloads it. Returns what to tell the person.
    func getFromLidarr(title: String, artist: String) async -> String {
        for server in servers.onlineServers {
            await servers.sync(server.id)
        }
        await rebuild()
        let identity = HistoryImport.key(title: title, artistName: artist)
        guard let track = track(for: HistorySong(songID: "", title: title, artistName: artist)) else {
            // Still in Lidarr, still to be downloaded: the row keeps its button to try again.
            return String(localized: "Your Server Doesn't Have It Yet")
        }
        record(.playable(track), for: identity, generation: availabilityGeneration)
        if track.isFromServer, !downloads.isDownloaded(track.id) {
            downloads.download([track])
            return String(localized: "Downloading \u{201C}\(title)\u{201D}")
        }
        return String(localized: "\u{201C}\(title)\u{201D} Is in Your Music")
    }

    /// Downloads an album Lidarr has filed: found among your server's songs, after a sync if
    /// the last one missed it. Returns what to tell the person.
    func downloadFromCollection(album title: String, by artist: String) async -> String {
        func find() -> [LocalTrack] {
            let artistKey = StatsCalculator.folded(artist)
            let theirs = index.albums.filter { StatsCalculator.folded($0.artist) == artistKey }
            // The album of that very title; only failing that, one that differs by an edition,
            // so "Nevermind" doesn't bring "Nevermind (Remastered)" with it.
            let exact = StatsCalculator.folded(title)
            let key = LidarrClient.albumKey(title)
            let album = theirs.first { StatsCalculator.folded($0.title) == exact }
                ?? theirs.first { LidarrClient.albumKey($0.title) == key }
            return (album?.tracks ?? []).filter(\.isFromServer)
        }
        var tracks = find()
        if tracks.isEmpty {
            for server in servers.onlineServers { await servers.sync(server.id) }
            await rebuild()
            tracks = find()
        }
        guard !tracks.isEmpty else {
            return String(localized: "Your Server Doesn't Have It Yet")
        }
        let missing = tracks.filter { !downloads.isDownloaded($0.id) }
        guard !missing.isEmpty else { return String(localized: "Already Downloaded") }
        downloads.download(missing)
        return String(localized: "Downloading \u{201C}\(title)\u{201D}")
    }

    /// Songs your servers have for a search that aren't in your music yet: ones newer than the
    /// last sync, and, from a full search of a server like Octo, ones it can find and play for
    /// you. Full answers are kept for ten minutes, so going back to a search doesn't ask again.
    func searchServers(_ query: String, isFull: Bool) async -> ServerSearchPage {
        let key = StatsCalculator.folded(query.trimmingCharacters(in: .whitespaces))
        if isFull, let answer = fullSearchAnswers[key], answer.at.timeIntervalSinceNow > -10 * 60 {
            var page = answer.page
            page.tracks = index.notIncluded(page.tracks)
            return page
        }
        var page = newToYou(await servers.search(query, isFull: isFull))
        // Servers answer in their own order, "Café Night" before "Café": closest first.
        page.tracks = LocalLibraryIndex.ranked(page.tracks, for: query)
        // Not an empty answer, which is also what a server that couldn't be reached gives.
        if isFull, !page.tracks.isEmpty, !Task.isCancelled {
            if fullSearchAnswers.count >= 30 {
                fullSearchAnswers = fullSearchAnswers.filter { $0.value.at.timeIntervalSinceNow > -10 * 60 }
            }
            fullSearchAnswers[key] = (page, .now)
        }
        return page
    }

    /// Albums and artists your servers have for a search that aren't in your music yet: the
    /// ones in it show from the library.
    func searchServerAlbumsAndArtists(_ query: String) async -> (albums: [ServerDiscovery.Album], artists: [ServerArtist]) {
        let found = await servers.searchAlbumsAndArtists(query)
        var seenAlbums = Set<String>()
        var seenArtists = Set<String>()
        let albums = found.albums.filter { album in
            let key = StatsCalculator.folded(album.artist) + "\u{1F}" + StatsCalculator.folded(album.title)
            return index.album(id: key) == nil && seenAlbums.insert(key).inserted
        }
        let artists = found.artists.filter { artist in
            let key = StatsCalculator.folded(artist.name)
            return index.artist(id: key) == nil && seenArtists.insert(key).inserted
        }
        return (albums, artists)
    }

    /// The next page of a search of your servers.
    func searchServers(_ query: String, after page: ServerSearchPage) async -> ServerSearchPage {
        var next = newToYou(await servers.search(query, after: page))
        next.tracks = LocalLibraryIndex.ranked(next.tracks, for: query)
        return next
    }

    /// A page of search results with what's in your music already left out, remembered so
    /// playing one is kept in your history as this song, as a suggestion found on a server is.
    private func newToYou(_ page: ServerSearchPage) -> ServerSearchPage {
        var page = page
        page.tracks = index.notIncluded(page.tracks)
        for track in page.tracks { foundOnServers[track.identity] = track }
        return page
    }

    /// The last full searches of your servers, by what was searched for.
    @ObservationIgnored private var fullSearchAnswers: [String: (page: ServerSearchPage, at: Date)] = [:]

    /// A song started playing. With Automatic Downloads on, one from a server comes down to
    /// this iPhone: one in your music straight away, one found for you by asking its server to
    /// keep it first, and downloading it when a sync brings it in.
    func didStartPlaying(_ track: LocalTrack) {
        guard AutomaticDownloads.isOn, !isDemo, track.isFromServer else { return }
        let track = resolved(track)
        if isInYourMusic(track) {
            guard !downloads.isDownloaded(track.id), !downloads.isDownloading(track.id) else { return }
            downloads.download([track])
        } else if !servers.isWaitingToKeep(track) {
            Task { _ = try? await servers.keep(track) }
        }
    }

    /// Songs asked for that a sync brought in: the player hears, in case it's waiting on one,
    /// and with Automatic Downloads on, or for Tracks Radio, they come down.
    private func keptArrived(_ tracks: [LocalTrack]) {
        onSongsArrived?(tracks)
        let missing = tracks.filter { !downloads.isDownloaded($0.id) && !downloads.isDownloading($0.id) }
        let forRadio = missing.filter { readyingForRadio.contains($0.identity) }
        let wanted = AutomaticDownloads.isOn ? missing.filter { !readyingForRadio.contains($0.identity) } : []
        readyingForRadio.subtract(tracks.map(\.identity))
        downloadForRadio(forRadio)
        downloads.download(wanted)
    }

    /// Downloads songs Tracks Radio is getting ready, which stay the radio's: with Delete After
    /// Playing on, they go once they've played.
    private func downloadForRadio(_ tracks: [LocalTrack]) {
        guard !tracks.isEmpty else { return }
        isDownloadingForRadio = true
        defer { isDownloadingForRadio = false }
        downloads.download(tracks)
    }

    @ObservationIgnored private var isDownloadingForRadio = false

    /// A download asked for by anything but Tracks Radio is one you want: it stays, even once
    /// the radio has played the song.
    private func downloadsAsked(_ tracks: [LocalTrack]) {
        guard !isDownloadingForRadio else { return }
        let identities = Set(tracks.map(\.identity))
        guard !radioOnly.isDisjoint(with: identities) else { return }
        radioOnly.subtract(identities)
        saveRadioOnly()
    }

    /// Songs being got ready, for Tracks Radio or a playlist merged with Apple Music: downloaded
    /// when they arrive, whatever the setting.
    @ObservationIgnored private var readyingForRadio: Set<String> = []
    /// Songs, by identity, downloaded only for Tracks Radio to play: with Delete After Playing
    /// on, their downloads go once they've played. Kept between launches.
    private(set) var radioOnly: Set<String> = Set(UserDefaults.standard.stringArray(forKey: YourMusic.radioOnlyKey) ?? [])
    static let radioOnlyKey = "radioOnlyDownloads"

    /// Songs a server found for you, so the player can play them by name, as Tracks Radio does
    /// with Picked for You's.
    func remember(found tracks: [LocalTrack]) {
        for track in tracks where index.track(id: track.id) == nil {
            foundOnServers[track.identity] = track
        }
    }

    /// Picked for You's songs from every server that aren't in your music yet: new finds for
    /// Tracks Radio.
    var serverFinds: [LocalTrack] {
        discover.forYou.values.flatMap { $0.songs + $0.suggested + $0.further }.filter { $0.isFromServer && !isInYourMusic($0) }
    }

    /// Called with songs asked for that a sync has brought in. Set by the player.
    @ObservationIgnored var onSongsArrived: (([LocalTrack]) -> Void)?
    /// Called with a song's identity once it's downloaded. Set by the player, for Tracks Radio.
    @ObservationIgnored var onReady: ((String) -> Void)?

    /// Asks a song's server to keep it, for a song found by searching. Returns what to tell
    /// the person.
    func keep(_ track: LocalTrack) async -> String {
        do {
            try await servers.keep(track)
            return String(localized: "Adding \u{201C}\(track.title)\u{201D} to Your Music")
        } catch {
            return String(localized: "Couldn't Reach Your Server")
        }
    }

    /// Forgets what couldn't be found, to look again: after a sync, or a change in Lidarr.
    func forgetUnavailable() {
        availabilityGeneration += 1
    }

    // MARK: - Files

    /// Reads the Music folder again: new files in, removed ones out, changed ones re-read.
    func scan() async {
        guard !isDemo else { return }
        // One already running may have listed the folder before a new file landed: it goes
        // round again when it's done.
        guard !isScanning else {
            needsRescan = true
            return
        }
        isScanning = true
        defer { isScanning = false }
        await loadingFiles?.value
        repeat {
            needsRescan = false
            let scanned = await FileScanner.scan(previous: files)
            files = scanned
            await rebuild()
            hasScanned = true
            let snapshot = scanned
            Task.detached(priority: .utility) { FileScanner.saveCache(snapshot) }
        } while needsRescan
    }

    @ObservationIgnored private var needsRescan = false
    @ObservationIgnored private var clearImport: Task<Void, Never>?

    /// Copies songs in from Files, then reads them.
    func importItems(_ urls: [URL]) async {
        let result = await FileScanner.importItems(urls)
        await scan()
        // Said once the songs are in the library, not before.
        lastImport = result
        // A newer import's confirmation gets its own four seconds.
        clearImport?.cancel()
        clearImport = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            lastImport = nil
        }
    }

    /// Deletes a file from this iPhone.
    func deleteFile(_ track: LocalTrack) {
        guard case .file(let path) = track.origin else { return }
        try? FileManager.default.removeItem(at: LibraryFolders.music.appending(path: path))
        files[path] = nil
        Task { await rebuild() }
        let snapshot = files
        Task.detached(priority: .utility) { FileScanner.saveCache(snapshot) }
    }

    /// Bytes the files take up.
    var fileBytes: Int64 { files.values.map(\.size).reduce(0, +) }

    // MARK: - Keeping the index

    @ObservationIgnored private var loadingFiles: Task<Void, Never>?
    @ObservationIgnored private var rebuilding: Task<Void, Never>?
    @ObservationIgnored private var rebuildsAgain = false

    /// Builds the index again, off the main actor, from the songs as they are now. Asked while
    /// one is building, it builds once more after it, for everyone who asked in between, so a
    /// burst of downloads finishing is a couple of builds, not one each. Returns once the
    /// index has what was there when it was asked.
    private func rebuild() async {
        rebuildsAgain = true
        if rebuilding == nil {
            rebuilding = Task { [self] in
                while rebuildsAgain {
                    rebuildsAgain = false
                    let (files, catalogs, downloaded) = (files.values.map(\.track), servers.catalogs, downloads.tracks)
                    index = await Self.makeIndex(files: files, catalogs: catalogs, downloaded: downloaded)
                    // Songs that weren't here may be now.
                    forgetUnavailable()
                }
                rebuilding = nil
            }
        }
        await rebuilding?.value
    }

    @concurrent
    nonisolated private static func makeIndex(files: [LocalTrack], catalogs: [String: [LocalTrack]], downloaded: [LocalTrack]) async -> LocalLibraryIndex {
        let serverTracks = catalogs.values.flatMap(\.self)
        // A download whose server is gone still plays.
        let known = Set(serverTracks.map(\.id))
        let orphans = downloaded.filter { !known.contains($0.id) }
        return LocalLibraryIndex(tracks: files + serverTracks + orphans)
    }

    @concurrent
    nonisolated private static func loadFileCache() async -> [String: FileScanner.CachedFile] {
        FileScanner.loadCache()
    }

    private func followServersAndDownloads() {
        // Holds self only for each rebuild: held across the loop, which never ends, the task
        // and the model would keep each other alive.
        follower = Task { [weak self, servers, downloads] in
            let changes = Observations {
                SourceKey(catalogs: servers.catalogRevision, downloads: downloads.items.count)
            }
            for await _ in changes {
                guard let self else { return }
                await self.rebuild()
            }
        }
    }

    private struct SourceKey: Equatable {
        let catalogs: Int
        let downloads: Int
    }

    // MARK: - Sample data

    #if DEBUG
    /// With sample data: the sample history's songs as your files, half of them hi-res, and a
    /// pretend server with the rest.
    func fillDemo(from history: ListeningHistory) {
        var seen = Set<String>()
        let songs = history.captures.reversed().filter { seen.insert($0.songIdentity).inserted }
        let formats = [
            AudioFormat(codec: "FLAC", sampleRate: 96_000, bitDepth: 24),
            AudioFormat(codec: "FLAC", sampleRate: 44_100, bitDepth: 16),
            AudioFormat(codec: "ALAC", sampleRate: 48_000, bitDepth: 24),
            AudioFormat(codec: "MP3", bitRate: 320),
        ]
        let tracks = songs.enumerated().map { index, capture in
            LocalTrack(
                origin: index % 3 == 2 ? .server(serverID: "demo", songID: "\(index)") : .file(path: "\(capture.artistName)/\(capture.albumTitle ?? "Singles")/\(capture.title).flac"),
                title: capture.title,
                artist: capture.artistName,
                album: capture.albumTitle,
                trackNumber: index % 12 + 1,
                year: 2015 + index % 10,
                genre: history.songMetadata[capture.songIdentity]?.genre,
                duration: 180 + Double(index % 7) * 17,
                format: formats[index % formats.count],
                addedAt: Date.now.addingTimeInterval(-Double(index) * 36_000)
            )
        }
        let server = SubsonicServer(id: "demo", name: "Home Server", url: URL(string: "https://music.example.com")!, username: "demo")
        servers.fillDemo(tracks.filter(\.isFromServer), server: server)
        index = LocalLibraryIndex(tracks: tracks)
        hasScanned = true
    }
    #endif
}

// MARK: - Tracks Radio

extension YourMusic: RadioDownloads {
    var downloadsFirst: Bool { PlayPreferences.radioDownloadsFirst }

    func isReady(_ song: HistorySong) -> Bool {
        guard let track = track(for: song).map(resolved) else { return false }
        return !track.isFromServer || downloads.isDownloaded(track.id)
    }

    func prepare(_ song: HistorySong) {
        guard !isDemo, let track = track(for: song).map(resolved), track.isFromServer else { return }
        if isInYourMusic(track) {
            guard !downloads.isDownloaded(track.id), !downloads.isDownloading(track.id) else { return }
            noteRadioOnly(track.identity)
            downloadForRadio([track])
        } else {
            noteRadioOnly(track.identity)
            readyingForRadio.insert(track.identity)
            guard !servers.isWaitingToKeep(track) else { return }
            Task { _ = try? await servers.keep(track) }
        }
    }

    /// Asks a song's server to keep it, and downloads it once it's in: for a song an Apple Music
    /// playlist brings into one of yours.
    func keepAndDownload(_ track: LocalTrack) {
        guard !isDemo else { return }
        readyingForRadio.insert(track.identity)
        guard !servers.isWaitingToKeep(track) else { return }
        Task { _ = try? await servers.keep(track) }
    }

    func finishedPlaying(_ song: HistorySong) -> Bool {
        let identity = HistoryImport.key(title: song.title, artistName: song.artistName)
        guard PlayPreferences.radioDeletesAfterPlaying, radioOnly.contains(identity) else { return false }
        // One you've put in a playlist since is one you want.
        guard !playlists.all.contains(where: { $0.identities.contains(identity) }) else {
            keep(song)
            return false
        }
        let ids = index.tracks(withIdentity: identity).map(\.id).filter { downloads.isDownloaded($0) || downloads.isDownloading($0) }
        guard !ids.isEmpty else { return false }
        downloads.remove(Set(ids))
        return true
    }

    func keep(_ song: HistorySong) {
        let identity = HistoryImport.key(title: song.title, artistName: song.artistName)
        radioOnly.remove(identity)
        saveRadioOnly()
        guard let track = track(for: song).map(resolved), track.isFromServer else { return }
        if isInYourMusic(track) {
            guard !downloads.isDownloaded(track.id), !downloads.isDownloading(track.id) else { return }
            downloads.download([track])
        } else {
            keepAndDownload(track)
        }
    }

    /// Whether a song was downloaded only to play on Tracks Radio, and goes after it plays.
    func isRadioOnly(_ track: LocalTrack) -> Bool {
        PlayPreferences.radioDeletesAfterPlaying && radioOnly.contains(track.identity)
    }

    private func noteRadioOnly(_ identity: String) {
        radioOnly.insert(identity)
        saveRadioOnly()
    }

    private func saveRadioOnly() {
        UserDefaults.standard.set(Array(radioOnly), forKey: Self.radioOnlyKey)
    }

    func decline(_ song: HistorySong) {
        let identity = HistoryImport.key(title: song.title, artistName: song.artistName)
        readyingForRadio.remove(identity)
        let copies = index.tracks(withIdentity: identity).map(\.id)
        let downloading = copies.filter(downloads.isDownloading)
        if !downloading.isEmpty { downloads.cancel(Set(downloading)) }
        // No longer the radio's: a download of it you make later is yours, and stays.
        guard radioOnly.remove(identity) != nil else { return }
        saveRadioOnly()
        // One already here only for the radio to play goes, as it would have once played,
        // unless you've put it in a playlist since.
        guard PlayPreferences.radioDeletesAfterPlaying,
              !playlists.all.contains(where: { $0.identities.contains(identity) })
        else { return }
        let downloaded = copies.filter(downloads.isDownloaded)
        if !downloaded.isEmpty { downloads.remove(Set(downloaded)) }
    }
}
