import Foundation
import Observation
import TracksCore

/// Your music servers: the ones you've connected, whether each can be reached, and the songs
/// on each, synced so Tracks Radio, the mixes and search can reach every one of them.
@MainActor
@Observable
final class MusicServers {
    enum Status: Equatable {
        case connecting
        case online
        case offline
        case wrongPassword
        case failed(String)
    }

    private(set) var servers: [SubsonicServer] = []
    private(set) var status: [String: Status] = [:]
    /// Every song on each server, as of its last sync.
    private(set) var catalogs: [String: [LocalTrack]] = [:] {
        didSet { catalogRevision &+= 1 }
    }
    /// Bumped whenever ``catalogs`` changes, so following it doesn't mean comparing them.
    private(set) var catalogRevision = 0
    /// Each server's artists, by folded name: their id there, for artists like them, and their
    /// picture's cover id, for artist pages and circles. A server not asked yet isn't here.
    private(set) var artists: [String: [String: ServerArtistRef]] = [:]
    private(set) var syncing: Set<String> = []
    private(set) var lastSynced: [String: Date] = [:]
    /// Servers not told when a song plays from them. Everyone else's are, so the server's own
    /// counts stay right.
    private(set) var quietServers: Set<String> = Set(UserDefaults.standard.stringArray(forKey: MusicServers.quietKey) ?? [])
    /// Songs you've asked each server to keep, until a sync brings them in. A server like Octo
    /// fetches the file first, which takes minutes.
    private(set) var kept: [String: ServerKeeps] = MusicServers.loadKept()

    @ObservationIgnored private var clients: [String: SubsonicClient] = [:]
    /// Searches that make a server like Octo look songs up elsewhere go through here, a few at
    /// a time: asked for dozens at once, Octo's own lookups are refused and everything slows.
    @ObservationIgnored let lookups = AsyncLimiter(limit: 3)
    /// Called when a server's reachability or songs change, so suggestions are judged again.
    @ObservationIgnored var onStatusChange: (() -> Void)?
    /// Called with songs asked for that a sync has brought in.
    @ObservationIgnored var onKeptArrived: (([LocalTrack]) -> Void)?
    @ObservationIgnored private var syncTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var keepFollowUps: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let isDemo: Bool
    /// Reading the saved songs at launch, off the main actor: a big library takes a moment.
    /// Connecting and syncing wait for it.
    @ObservationIgnored private var loading: Task<Void, Never>?

    private static let storageKey = "musicServers"
    private static let quietKey = "musicServersNotToldOfPlays"
    private static let keptKey = "musicServersKeptSongs"
    /// Songs asked for at a time while syncing.
    nonisolated private static let pageSize = 500
    /// Syncing stops here, far past any library a phone should hold at once.
    nonisolated private static let catalogLimit = 60_000

    init(isDemo: Bool) {
        self.isDemo = isDemo
        guard !isDemo else { return }
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([SubsonicServer].self, from: data) {
            servers = saved
        }
        #if DEBUG
        let test = addTestServer()
        #endif
        for server in servers {
            if let password = ServerKeychain.password(for: server.id) {
                clients[server.id] = SubsonicClient(server: server, password: password)
            }
        }
        let ids = servers.map(\.id)
        loading = Task { [self] in
            let saved = await Self.loadSaved(ids)
            for (id, catalog, artists) in saved where servers.contains(where: { $0.id == id }) {
                // A sync that landed first is newer.
                if catalogs[id] == nil, !catalog.isEmpty { catalogs[id] = catalog }
                if self.artists[id] == nil, let artists { self.artists[id] = artists }
            }
            loading = nil
        }
        #if DEBUG
        // An unsigned build has no keychain.
        if let test { clients[test.server.id] = SubsonicClient(server: test.server, password: test.password) }
        #endif
    }

    #if DEBUG
    /// `-TracksTestServer "http://127.0.0.1:4533|user|password|Name"`: connects a test server at
    /// launch, for UI checks against a local server without typing into the form.
    private func addTestServer() -> (server: SubsonicServer, password: String)? {
        guard let value = UserDefaults.standard.string(forKey: "TracksTestServer") else { return nil }
        let parts = value.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, let url = URL(string: parts[0]) else { return nil }
        let id = "test-server"
        let server = SubsonicServer(id: id, name: parts.count > 3 ? parts[3] : "Test Server", url: url, username: parts[1], salt: "testsalt")
        ServerKeychain.setPassword(parts[2], for: id)
        if let index = servers.firstIndex(where: { $0.id == id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        save()
        return (server, parts[2])
    }
    #endif

    func client(for serverID: String) -> SubsonicClient? { clients[serverID] }

    /// Whether a server hears about the songs played from it.
    func reportsPlays(to serverID: String) -> Bool { !quietServers.contains(serverID) }

    func setReportsPlays(_ reports: Bool, to serverID: String) {
        if reports { quietServers.remove(serverID) } else { quietServers.insert(serverID) }
        UserDefaults.standard.set(Array(quietServers), forKey: Self.quietKey)
    }

    func server(_ id: String) -> SubsonicServer? { servers.first { $0.id == id } }

    var onlineServers: [SubsonicServer] { servers.filter { status[$0.id] == .online } }

    // MARK: - Connecting

    /// Checks a server and, if it answers, keeps it and its password.
    func add(_ server: SubsonicServer, password: String) async throws {
        let client = SubsonicClient(server: server, password: password)
        try await client.ping()
        ServerKeychain.setPassword(password, for: server.id)
        clients[server.id] = client
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        status[server.id] = .online
        save()
        await sync(server.id)
    }

    func remove(_ serverID: String) {
        servers.removeAll { $0.id == serverID }
        clients[serverID] = nil
        status[serverID] = nil
        catalogs[serverID] = nil
        kept[serverID] = nil
        saveKept()
        keepFollowUps.removeValue(forKey: serverID)?.cancel()
        setReportsPlays(true, to: serverID)
        ServerKeychain.removePassword(for: serverID)
        try? FileManager.default.removeItem(at: Self.catalogURL(serverID))
        try? FileManager.default.removeItem(at: Self.artistsURL(serverID))
        artists[serverID] = nil
        save()
    }

    /// Checks every server, and syncs the ones not synced today.
    func connectAll() async {
        await withTaskGroup(of: Void.self) { group in
            for server in servers {
                group.addTask { await self.connect(server.id) }
            }
        }
    }

    /// Checks servers again once the connection comes back or moves: ones out of reach are
    /// tried again, and ones that answered are asked quietly whether they still do, so a
    /// server reachable only at home shows as out of reach once you've left, and back again
    /// when you're home. Servers not checked yet this launch are left to that.
    func networkChanged() async {
        await withTaskGroup(of: Void.self) { group in
            for server in servers where clients[server.id] != nil {
                switch status[server.id] {
                case .online: group.addTask { await self.recheck(server.id) }
                case .offline, .failed: group.addTask { await self.connect(server.id) }
                case .connecting, .wrongPassword, nil: break
                }
            }
        }
    }

    /// Asks a server that answered before whether it still does, without showing it as
    /// connecting meanwhile.
    private func recheck(_ serverID: String) async {
        guard let client = clients[serverID] else { return }
        let next: Status
        do {
            try await client.ping()
            return
        } catch SubsonicError.wrongCredentials {
            next = .wrongPassword
        } catch let error as SubsonicError {
            next = .failed(Self.describe(error))
        } catch {
            next = .offline
        }
        // Checked again, or removed, meanwhile.
        guard status[serverID] == .online else { return }
        status[serverID] = next
        onStatusChange?()
    }

    func connect(_ serverID: String) async {
        await loading?.value
        guard let client = clients[serverID] else {
            status[serverID] = .wrongPassword
            return
        }
        status[serverID] = .connecting
        do {
            try await client.ping()
            status[serverID] = .online
            let synced = lastSynced[serverID] ?? catalogDate(serverID)
            if catalogs[serverID]?.isEmpty != false || kept[serverID]?.isEmpty == false
                || Date.now.timeIntervalSince(synced ?? .distantPast) > 24 * 60 * 60 {
                await sync(serverID)
            } else if artists[serverID] == nil {
                // Synced before its artists were kept.
                await syncArtists(serverID)
            }
        } catch SubsonicError.wrongCredentials {
            status[serverID] = .wrongPassword
        } catch let error as SubsonicError {
            status[serverID] = .failed(Self.describe(error))
        } catch {
            status[serverID] = .offline
        }
        onStatusChange?()
    }

    /// Pages through every song on the server. Songs keep the date they were first seen, so
    /// Recently Added means recently added to the server.
    func sync(_ serverID: String) async {
        // Its saved songs first, so their dates added aren't lost.
        await loading?.value
        // One already running is waited for, so whoever asked sees its songs when it returns.
        if let running = syncTasks[serverID] {
            await running.value
            return
        }
        let task = Task { await performSync(serverID) }
        syncTasks[serverID] = task
        await task.value
        syncTasks[serverID] = nil
        onStatusChange?()
    }

    private func performSync(_ serverID: String) async {
        guard let client = clients[serverID] else { return }
        syncing.insert(serverID)
        defer { syncing.remove(serverID) }
        let known = Dictionary((catalogs[serverID] ?? []).map { ($0.id, $0.addedAt) }, uniquingKeysWith: { first, _ in first })
        let isFirstSync = known.isEmpty
        var songs: [SubsonicSong] = []
        var searchFailed = false
        do {
            while songs.count < Self.catalogLimit {
                let page = try await client.search("", artists: 0, albums: 0, songs: Self.pageSize, songOffset: songs.count)
                songs += page.songs
                if page.songs.count < Self.pageSize { break }
            }
        } catch {
            searchFailed = true
        }
        // Older servers answer an empty search with nothing, or refuse it: walk the albums.
        // A search that failed partway is only some of the songs, so it's walked too.
        if songs.isEmpty || searchFailed {
            guard let walked = try? await Self.songsByAlbum(client) else {
                // Keep what was there; a failed sync mustn't empty the library.
                return
            }
            songs = walked
        }
        // Removed while it synced: nothing to keep.
        guard clients[serverID] != nil else { return }
        let now = Date.now
        let tracks = songs.map { song in
            // When the server added it, where it says, so Recently Added is the server's own
            // from the first sync. Otherwise when this sync first saw it; on a first sync
            // there's no telling, and the server's order stands.
            song.track(on: serverID, addedAt: song.createdDate ?? known[LocalTrack.id(for: .server(serverID: serverID, songID: song.id))] ?? (isFirstSync ? .distantPast : now))
        }
        catalogs[serverID] = tracks
        lastSynced[serverID] = now
        Task.detached(priority: .utility) { Self.saveCatalog(tracks, serverID) }
        settleKept(serverID, synced: tracks)
        // Its artists' pictures after the songs are safe.
        await syncArtists(serverID)
    }

    // MARK: - Searching and keeping

    /// How many songs a quick search asks for. Octo keeps its first 12 for the library's own
    /// matches, so asking for no more than that answers from the library alone, at once,
    /// without it finding songs for you.
    static let quickSearchSize = 12
    /// How many songs a full search asks for: all Octo finds. It finds 60 for any search of
    /// more than 12 however many are asked for, and only on the first page, so asking for fewer
    /// would save it nothing and lose the rest. It takes Octo several seconds.
    static let fullSearchSize = 60
    /// How many of the library's matches each page after the first asks for.
    static let searchPageSize = 30

    /// Songs on your servers for a search, asked of each server rather than looked up in its
    /// last sync. A server like Octo answers a full search with songs it can find for you as
    /// well as the ones it has, and plays them straight away.
    /// - Parameter isFull: ask for the songs a server can find too, which is slow on Octo;
    ///   otherwise only for the ones it has.
    func search(_ query: String, isFull: Bool) async -> ServerSearchPage {
        await search(query, from: Dictionary(uniqueKeysWithValues: onlineServers.map { ($0.id, 0) }), size: isFull ? Self.fullSearchSize : Self.quickSearchSize)
    }

    /// Albums and artists on your servers for a search, with ones a server like Octo finds
    /// elsewhere. Quick even on Octo: no songs are asked for, so it doesn't go finding those.
    func searchAlbumsAndArtists(_ query: String) async -> (albums: [ServerDiscovery.Album], artists: [ServerArtist]) {
        let asked = onlineServers.compactMap { server in clients[server.id].map { (server.id, $0) } }
        let answers = await withTaskGroup(of: (String, SubsonicSearchResult?).self) { group in
            for (serverID, client) in asked {
                group.addTask { [lookups] in
                    (serverID, try? await lookups.run { try await client.search(query, artists: 6, albums: 12, songs: 0) })
                }
            }
            var answers: [String: SubsonicSearchResult] = [:]
            for await (serverID, result) in group { answers[serverID] = result }
            return answers
        }
        var albums: [ServerDiscovery.Album] = []
        var artists: [ServerArtist] = []
        for (serverID, _) in asked {
            guard let result = answers[serverID] else { continue }
            albums += result.albums.map { ServerDiscovery.Album($0, serverID: serverID) }
            artists += result.artists.map { ServerArtist($0, serverID: serverID) }
        }
        return (albums, artists)
    }

    /// The next page of a search: more of the library's matches, from the servers that had more.
    func search(_ query: String, after page: ServerSearchPage) async -> ServerSearchPage {
        await search(query, from: page.next, size: Self.searchPageSize)
    }

    private func search(_ query: String, from offsets: [String: Int], size: Int) async -> ServerSearchPage {
        let asked = onlineServers.compactMap { server in
            clients[server.id].flatMap { client in offsets[server.id].map { (server.id, client, $0) } }
        }
        let answers = await withTaskGroup(of: (String, [SubsonicSong]?).self) { group in
            for (serverID, client, offset) in asked {
                group.addTask { [lookups] in
                    (serverID, try? await lookups.run { try await client.search(query, artists: 0, albums: 0, songs: size, songOffset: offset).songs })
                }
            }
            var answers: [String: [SubsonicSong]] = [:]
            for await (serverID, songs) in group { answers[serverID] = songs }
            return answers
        }
        // In the order the servers were added, so results don't reshuffle between searches.
        var page = ServerSearchPage()
        for (serverID, _, offset) in asked {
            // One that couldn't be asked has nothing more to give this search.
            guard let songs = answers[serverID] else { continue }
            page.tracks += songs.map { $0.track(on: serverID) }
            // Octo's finds come on the first page only; the library's own matches go on under
            // them, 12 of them on Octo's first page, as many as were asked for on others'.
            let library = songs.filter { $0.isExternal != true }.count
            if offset == 0 ? library >= Self.quickSearchSize : library == size {
                page.next[serverID] = offset + library
            }
        }
        return page
    }

    /// Stars a song on its server, which a server like Octo takes as "get me this": it fetches
    /// the file into the library. Syncs every half minute at first, then every two, for twenty
    /// minutes or until it's in: Octo usually has a song within a few minutes.
    func keep(_ track: LocalTrack) async throws {
        guard case .server(let serverID, let songID) = track.origin, let client = clients[serverID] else { return }
        try await client.star(songID: songID)
        kept[serverID, default: ServerKeeps()].ask(for: track.identity)
        saveKept()
        keepFollowUps[serverID]?.cancel()
        keepFollowUps[serverID] = Task { [weak self] in
            var waited: TimeInterval = 0
            while waited < 20 * 60 {
                let step: TimeInterval = waited < 5 * 60 ? 30 : 120
                try? await Task.sleep(for: .seconds(step))
                waited += step
                guard !Task.isCancelled, let self, self.kept[serverID]?.isEmpty == false else { return }
                await self.sync(serverID)
            }
        }
    }

    /// Whether a song has been asked for and its server hasn't got it yet.
    func isWaitingToKeep(_ track: LocalTrack) -> Bool {
        guard case .server(let serverID, _) = track.origin else { return false }
        return kept[serverID]?.isWaiting(for: track.identity) == true
    }

    private func settleKept(_ serverID: String, synced tracks: [LocalTrack]) {
        guard var waiting = kept[serverID] else { return }
        let arrived = tracks.filter { waiting.isWaiting(for: $0.identity) }
        if !arrived.isEmpty { onKeptArrived?(arrived) }
        waiting.settle(arrived: Set(tracks.map(\.identity)))
        kept[serverID] = waiting.isEmpty ? nil : waiting
        saveKept()
    }

    /// Every album's songs, a few albums at a time.
    @concurrent
    nonisolated private static func songsByAlbum(_ client: SubsonicClient) async throws -> [SubsonicSong] {
        var albums: [SubsonicAlbum] = []
        while albums.count < catalogLimit / 10 {
            let page = try await client.albums(.alphabeticalByName, size: pageSize, offset: albums.count)
            albums += page
            if page.count < pageSize { break }
        }
        var songs: [SubsonicSong] = []
        for batch in stride(from: 0, to: albums.count, by: 8).map({ Array(albums[$0..<min($0 + 8, albums.count)]) }) {
            try await withThrowingTaskGroup(of: [SubsonicSong].self) { group in
                for album in batch {
                    // An album the server can't give is skipped; a lost connection fails the
                    // walk, so part of the library isn't kept as all of it.
                    group.addTask {
                        do { return try await client.album(id: album.id).songs }
                        catch let error as URLError { throw error }
                        catch { return [] }
                    }
                }
                for try await found in group { songs += found }
            }
        }
        return songs
    }

    static func describe(_ error: SubsonicError) -> String {
        switch error {
        case .wrongCredentials: String(localized: "The username or password is wrong.")
        case .incompatible: String(localized: "This server is too old for Tracks.")
        case .notFound: String(localized: "The server couldn't find that.")
        case .server(_, let message): message.isEmpty ? String(localized: "The server couldn't answer.") : message
        case .notSubsonic: String(localized: "That address doesn't look like a music server. Check it's the address you use in your browser.")
        case .http(let status): String(localized: "The server answered with an error (\(status)).")
        }
    }

    // MARK: - Storage

    private func save() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func saveKept() {
        guard !isDemo, let data = try? JSONEncoder().encode(kept) else { return }
        UserDefaults.standard.set(data, forKey: Self.keptKey)
    }

    private static func loadKept() -> [String: ServerKeeps] {
        guard let data = UserDefaults.standard.data(forKey: keptKey) else { return [:] }
        return (try? JSONDecoder().decode([String: ServerKeeps].self, from: data)) ?? [:]
    }

    /// Asks a server for its artists, for their pictures and ids. One request, however many.
    private func syncArtists(_ serverID: String) async {
        guard let client = clients[serverID], let found = try? await client.artists() else { return }
        var refs: [String: ServerArtistRef] = [:]
        for artist in found {
            refs[StatsCalculator.folded(artist.name)] = ServerArtistRef(id: artist.id, cover: artist.coverArt.flatMap { $0.isEmpty ? nil : $0 })
        }
        guard clients[serverID] != nil else { return }
        artists[serverID] = refs
        if let data = try? JSONEncoder().encode(refs) {
            try? data.write(to: Self.artistsURL(serverID), options: .atomic)
        }
    }

    nonisolated private static func artistsURL(_ serverID: String) -> URL {
        LibraryFolders.index.appending(path: "server-\(serverID)-artists.json")
    }

    @concurrent
    nonisolated private static func loadSaved(_ ids: [String]) async -> [(String, [LocalTrack], [String: ServerArtistRef]?)] {
        ids.map { ($0, loadCatalog($0), loadArtists($0)) }
    }

    nonisolated private static func loadArtists(_ serverID: String) -> [String: ServerArtistRef]? {
        guard let data = try? Data(contentsOf: artistsURL(serverID)) else { return nil }
        return try? JSONDecoder().decode([String: ServerArtistRef].self, from: data)
    }

    nonisolated private static func catalogURL(_ serverID: String) -> URL {
        LibraryFolders.index.appending(path: "server-\(serverID).json")
    }

    nonisolated private static func loadCatalog(_ serverID: String) -> [LocalTrack] {
        guard let data = try? Data(contentsOf: catalogURL(serverID)) else { return [] }
        return (try? JSONDecoder().decode([LocalTrack].self, from: data)) ?? []
    }

    nonisolated private static func saveCatalog(_ tracks: [LocalTrack], _ serverID: String) {
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        try? data.write(to: catalogURL(serverID), options: .atomic)
    }

    private func catalogDate(_ serverID: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: Self.catalogURL(serverID).path(percentEncoded: false)))?[.modificationDate] as? Date
    }

    #if DEBUG
    /// A pretend server, for sample data.
    func fillDemo(_ tracks: [LocalTrack], server: SubsonicServer) {
        servers = [server]
        status[server.id] = .online
        catalogs[server.id] = tracks
    }
    #endif
}

/// An artist as a server knows them: their id there, and their picture's cover id if it has one.
nonisolated struct ServerArtistRef: Codable, Sendable, Hashable {
    let id: String
    let cover: String?
}

/// A page of a search of your servers, and where each server's next one starts.
struct ServerSearchPage {
    var tracks: [LocalTrack] = []
    /// How far into each server's library matches the next page starts, for the servers that
    /// may have more.
    var next: [String: Int] = [:]

    var hasMore: Bool { !next.isEmpty }
}
