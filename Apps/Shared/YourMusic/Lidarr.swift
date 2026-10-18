import Foundation
import Observation
import TracksCore

/// Your Lidarr: where it is, whether it answers, how it files what Tracks asks for, and what
/// it follows, has and is fetching.
@MainActor
@Observable
final class Lidarr {
    enum Status: Equatable {
        case off
        case connecting
        case connected(version: String)
        case wrongKey
        case failed(String)
    }

    private(set) var server: LidarrServer?
    private(set) var status: Status = .off
    private(set) var qualityProfiles: [LidarrProfile] = []
    private(set) var metadataProfiles: [LidarrProfile] = []
    private(set) var rootFolders: [LidarrRootFolder] = []
    /// Every artist Lidarr follows, as of the last look.
    private(set) var artists: [LidarrArtist] = []
    private(set) var queue: [LidarrQueueItem] = []
    private(set) var missing: [LidarrAlbum] = []
    private(set) var upcoming: [LidarrAlbum] = []

    // How it files what Tracks adds, kept on this iPhone.
    var qualityProfileID: Int? { didSet { save(qualityProfileID, Self.qualityKey) } }
    var metadataProfileID: Int? { didSet { save(metadataProfileID, Self.metadataKey) } }
    var rootFolderPath: String? { didSet { UserDefaults.standard.set(rootFolderPath, forKey: Self.rootKey) } }
    var monitor: LidarrAddOptions.Monitor = .all { didSet { UserDefaults.standard.set(monitor.rawValue, forKey: Self.monitorKey) } }
    var searchesNow = true { didSet { UserDefaults.standard.set(searchesNow, forKey: Self.searchKey) } }

    @ObservationIgnored private(set) var client: LidarrClient?
    @ObservationIgnored private var albumsByArtist: [Int: (at: Date, albums: [LidarrAlbum])] = [:]
    @ObservationIgnored private var tracksByArtist: [Int: (at: Date, tracks: [LidarrTrack])] = [:]
    @ObservationIgnored private var albumRequests: [Int: Task<[LidarrAlbum], Never>] = [:]
    @ObservationIgnored private var trackRequests: [Int: Task<[LidarrTrack], Never>] = [:]
    @ObservationIgnored private var artistsLoadedAt: Date?
    /// Goes up with each connection, so an answer from the Lidarr before is dropped.
    @ObservationIgnored private var generation = 0
    private(set) var hasLoadedArtists = false
    /// Called when what Lidarr can say about songs changes: connected, disconnected, its
    /// artists known. Set by the app, so suggestions are judged again.
    @ObservationIgnored var onChange: (() -> Void)?

    private static let serverKey = "lidarrServer"
    private static let keychainAccount = "lidarr"
    private static let qualityKey = "lidarrQualityProfile"
    private static let metadataKey = "lidarrMetadataProfile"
    private static let rootKey = "lidarrRootFolder"
    private static let monitorKey = "lidarrMonitor"
    private static let searchKey = "lidarrSearchesNow"

    init(isDemo: Bool) {
        let defaults = UserDefaults.standard
        qualityProfileID = defaults.object(forKey: Self.qualityKey) as? Int
        metadataProfileID = defaults.object(forKey: Self.metadataKey) as? Int
        rootFolderPath = defaults.string(forKey: Self.rootKey)
        monitor = defaults.string(forKey: Self.monitorKey).flatMap(LidarrAddOptions.Monitor.init(rawValue:)) ?? .all
        searchesNow = defaults.object(forKey: Self.searchKey) as? Bool ?? true
        guard !isDemo,
              let data = defaults.data(forKey: Self.serverKey),
              let saved = try? JSONDecoder().decode(LidarrServer.self, from: data),
              let key = ServerKeychain.password(for: Self.keychainAccount)
        else { return }
        server = saved
        client = LidarrClient(server: saved, apiKey: key)
    }

    var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    /// Whether Lidarr is set up at all, reachable or not.
    var isSetUp: Bool { client != nil }

    /// What Tracks sends with an artist it adds. Nil until Lidarr's folders and profiles are known.
    var addOptions: LidarrAddOptions? {
        guard let quality = qualityProfileID ?? qualityProfiles.first?.id,
              let metadata = metadataProfileID ?? metadataProfiles.first?.id,
              let root = rootFolderPath ?? rootFolders.first?.path
        else { return nil }
        return LidarrAddOptions(qualityProfileID: quality, metadataProfileID: metadata, rootFolderPath: root, monitor: monitor, searchNow: searchesNow)
    }

    // MARK: - Connecting

    /// Checks an address and key, and keeps them if Lidarr answers.
    func connect(to server: LidarrServer, apiKey: String) async throws {
        let client = LidarrClient(server: server, apiKey: apiKey)
        let status = try await client.status()
        ServerKeychain.setPassword(apiKey, for: Self.keychainAccount)
        if let data = try? JSONEncoder().encode(server) { UserDefaults.standard.set(data, forKey: Self.serverKey) }
        generation += 1
        forgetCollection()
        artists = []
        artistsLoadedAt = nil
        hasLoadedArtists = false
        self.server = server
        self.client = client
        self.status = .connected(version: status.version)
        onChange?()
        await loadSettings()
        await refreshArtists(force: true)
    }

    func disconnect() {
        ServerKeychain.removePassword(for: Self.keychainAccount)
        UserDefaults.standard.removeObject(forKey: Self.serverKey)
        server = nil
        client = nil
        status = .off
        artists = []
        queue = []
        missing = []
        upcoming = []
        generation += 1
        forgetCollection()
        artistsLoadedAt = nil
        hasLoadedArtists = false
        onChange?()
    }

    /// Checks Lidarr answers, and reads what it needs to add artists.
    func check() async {
        guard let client else { return }
        status = .connecting
        do {
            let answer = try await client.status()
            status = .connected(version: answer.version)
            await loadSettings()
            await refreshArtists()
        } catch LidarrError.wrongKey {
            status = .wrongKey
        } catch let error as LidarrError {
            status = .failed(Self.describe(error))
        } catch {
            status = .failed(String(localized: "Can't be reached."))
        }
        onChange?()
    }

    private func loadSettings() async {
        guard let client else { return }
        async let quality = try? client.qualityProfiles()
        async let metadata = try? client.metadataProfiles()
        async let folders = try? client.rootFolders()
        qualityProfiles = await quality ?? qualityProfiles
        metadataProfiles = await metadata ?? metadataProfiles
        rootFolders = await folders ?? rootFolders
    }

    // MARK: - What it follows and has

    func refreshArtists(force: Bool = false) async {
        guard let client else { return }
        if !force, let artistsLoadedAt, Date.now.timeIntervalSince(artistsLoadedAt) < 10 * 60 { return }
        let generation = generation
        guard let found = try? await client.artists(), generation == self.generation else { return }
        artists = found.sorted { $0.artistName.localizedStandardCompare($1.artistName) == .orderedAscending }
        artistsLoadedAt = .now
        let wasLoaded = hasLoadedArtists
        hasLoadedArtists = true
        // Songs judged before Lidarr's artists were known are judged again.
        if !wasLoaded { onChange?() }
    }

    /// Whether Lidarr can answer for a song: connected, and its artists known. Until then a
    /// song mustn't be called unavailable on its word.
    var isReady: Bool { isConnected && hasLoadedArtists }

    /// The artist Lidarr follows by this name, if it does.
    func artist(named name: String) -> LidarrArtist? {
        let wanted = StatsCalculator.folded(name)
        return artists.first { StatsCalculator.folded($0.artistName) == wanted }
    }

    /// Whether Lidarr follows this artist: by MusicBrainz's id, so two artists sharing a name
    /// are told apart.
    func follows(_ artist: LidarrArtist) -> Bool {
        artists.contains { $0.foreignArtistId == artist.foreignArtistId }
    }

    /// An artist's albums, looked up at most every few minutes, one request at a time however
    /// many rows ask.
    func albums(of artistID: Int, force: Bool = false) async -> [LidarrAlbum] {
        if !force, let cached = albumsByArtist[artistID], Date.now.timeIntervalSince(cached.at) < 5 * 60 { return cached.albums }
        if let running = albumRequests[artistID] { return await running.value }
        guard let client else { return albumsByArtist[artistID]?.albums ?? [] }
        let generation = generation
        let request = Task { (try? await client.albums(ofArtist: artistID)) }
        albumRequests[artistID] = Task { await request.value ?? [] }
        defer { albumRequests[artistID] = nil }
        guard let albums = await request.value, generation == self.generation else { return albumsByArtist[artistID]?.albums ?? [] }
        albumsByArtist[artistID] = (.now, albums)
        return albums
    }

    /// Every track of an artist's, with whether Lidarr has its file: one request for the lot.
    private func tracks(ofArtist artistID: Int) async -> [LidarrTrack] {
        if let cached = tracksByArtist[artistID], Date.now.timeIntervalSince(cached.at) < 2 * 60 { return cached.tracks }
        if let running = trackRequests[artistID] { return await running.value }
        guard let client else { return [] }
        let generation = generation
        let request = Task { (try? await client.tracks(ofArtist: artistID)) }
        trackRequests[artistID] = Task { await request.value ?? [] }
        defer { trackRequests[artistID] = nil }
        guard let tracks = await request.value, generation == self.generation else { return tracksByArtist[artistID]?.tracks ?? [] }
        tracksByArtist[artistID] = (.now, tracks)
        return tracks
    }

    /// What Lidarr knows of a song: whether its file is in the collection, or it's on its way.
    enum SongState: Equatable {
        /// The file is in Lidarr's collection.
        case collected(album: String)
        /// Lidarr follows the album and is looking for it.
        case wanted
        /// Lidarr doesn't have it and isn't looking.
        case none
    }

    func state(ofSong title: String, by artistName: String, album albumTitle: String?) async -> SongState {
        guard isConnected else { return .none }
        let artist = LidarrClient.artistCandidates(artistName).lazy.compactMap { self.artist(named: $0) }.first
        guard let artistID = artist?.id else { return .none }
        async let albumList = albums(of: artistID)
        async let trackList = tracks(ofArtist: artistID)
        let (albums, tracks): ([LidarrAlbum], [LidarrTrack]) = await (albumList, trackList)
        let wantedTitle = StatsCalculator.folded(title)
        let byID: [Int: LidarrAlbum] = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let matches = tracks.filter { StatsCalculator.folded($0.title) == wantedTitle }
        if let track = matches.first(where: \.hasFile) {
            return .collected(album: track.albumId.flatMap { byID[$0]?.title } ?? albumTitle ?? title)
        }
        let isWanted = matches.contains { track in track.albumId.flatMap { byID[$0]?.monitored } == true }
        return isWanted ? .wanted : .none
    }

    /// Forgets what Lidarr had, after asking it for more.
    private func forgetCollection() {
        albumsByArtist = [:]
        tracksByArtist = [:]
    }

    /// The queue, what's wanted and what's coming, for the Lidarr page.
    func refreshActivity() async {
        guard let client else { return }
        async let queue = try? client.queue()
        async let missing = try? client.missing()
        async let upcoming = try? client.calendar(from: .now, to: .now.addingTimeInterval(120 * 24 * 60 * 60))
        self.queue = await queue ?? self.queue
        self.missing = await missing ?? self.missing
        self.upcoming = (await upcoming ?? self.upcoming).sorted { ($0.releaseDate ?? .distantFuture) < ($1.releaseDate ?? .distantFuture) }
    }

    // MARK: - Asking for music

    /// Adds the very artist chosen from Lidarr's search. Returns what to tell the person.
    func add(_ artist: LidarrArtist) async -> String {
        guard let client, let options = addOptions else { return Self.notReady }
        guard !follows(artist) else { return String(localized: "Lidarr Already Follows \(artist.artistName)") }
        do {
            _ = try await client.add(artist, options: options)
            await refreshArtists(force: true)
            onChange?()
            return String(localized: "Lidarr Is Following \(artist.artistName)")
        } catch let error as LidarrError {
            return Self.describe(error)
        } catch {
            return String(localized: "Couldn't Reach Lidarr")
        }
    }

    /// Follows an artist, as the settings say. Returns what to tell the person.
    func follow(artistNamed name: String) async -> String {
        guard let client, let options = addOptions else { return Self.notReady }
        do {
            let (_, isNew) = try await client.follow(artistNamed: name, options: options)
            await refreshArtists(force: true)
            onChange?()
            return isNew ? String(localized: "Lidarr Is Following \(name)") : String(localized: "Lidarr Already Follows \(name)")
        } catch let error as LidarrError {
            return Self.describe(error)
        } catch {
            return String(localized: "Couldn't Reach Lidarr")
        }
    }

    /// Asks for one album. Returns what to tell the person.
    func request(album title: String, by artist: String) async -> String {
        guard let client, let options = addOptions else { return Self.notReady }
        do {
            let album = try await client.request(album: title, by: artist, options: options)
            forgetCollection()
            await refreshArtists(force: true)
            onChange?()
            return String(localized: "Lidarr Is Getting \u{201C}\(album.title)\u{201D}")
        } catch let error as LidarrError {
            return Self.describe(error)
        } catch {
            return String(localized: "Couldn't Reach Lidarr")
        }
    }

    /// Asks Lidarr to look for albums it follows but doesn't have.
    func search(albums ids: [Int]) async -> String {
        guard let client else { return Self.notReady }
        do {
            try await client.search(albums: ids)
            forgetCollection()
            return String(localized: "Lidarr Is Looking")
        } catch {
            return String(localized: "Couldn't Reach Lidarr")
        }
    }

    func searchMissing(of artistID: Int) async -> String {
        guard let client else { return Self.notReady }
        do {
            try await client.search(artist: artistID)
            forgetCollection()
            return String(localized: "Lidarr Is Looking for What's Missing")
        } catch {
            return String(localized: "Couldn't Reach Lidarr")
        }
    }

    private static let notReady = String(localized: "Set Up Lidarr in Settings First")

    static func describe(_ error: LidarrError) -> String {
        switch error {
        case .wrongKey: String(localized: "Lidarr didn't accept the API key.")
        case .rejected(let reason): reason
        case .notLidarr: String(localized: "That address doesn't look like Lidarr. It usually ends in :8686.")
        case .http(let status): String(localized: "Lidarr answered with an error (\(status)).")
        }
    }

    private func save(_ value: Int?, _ key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }

    #if DEBUG
    /// A pretend Lidarr for sample data: it follows the sample artists.
    func fillDemo(artists names: [String]) {
        status = .connected(version: "2.0")
        hasLoadedArtists = true
        artists = names.enumerated().map { index, name in
            LidarrArtist(id: index + 1, artistName: name, foreignArtistId: "demo-\(index)", monitored: true)
        }
    }
    #endif
}
