import Foundation
import Observation
import TracksCore

/// What your servers have to find: songs picked for you, their newest albums, their most
/// played, albums picked at random, and songs you've never heard for as long as you scroll.
@MainActor
@Observable
final class ServerDiscovery {
    /// An album on a server's shelf.
    struct Album: Identifiable, Hashable {
        let id: String
        let title: String
        let artist: String
        let artwork: LocalTrack.Artwork?
        let route: PlayRoute
    }

    struct Shelves {
        var newest: [Album] = []
        var mostPlayed: [Album] = []
        var random: [Album] = []
        var loadedAt = Date.distantPast
    }

    /// What one server finds for you, endlessly: songs you haven't heard, by the artists you
    /// play and ones like them, found an artist at a time as the shelves are scrolled. From a
    /// server like Octo, most are songs it finds for you to play and keep.
    nonisolated struct ForYou: Codable, Sendable {
        /// Picked for You: songs by artists you play or picked, yours and new ones together.
        var songs: [LocalTrack] = []
        /// Suggested Songs: songs by artists new to you.
        var suggested: [LocalTrack] = []
        /// Keep Exploring's: more by artists new to you, none of them on the shelves.
        var further: [LocalTrack] = []
        /// The artists it started from.
        var from: [String] = []
        /// Artists still to go on from: the ones it started from, then new ones it met on the way.
        var queue: [String] = []
        /// Artists gone on from already, folded.
        var asked: [String] = []
        /// Found for Picked for You, not shown yet: their covers are checked only as the shelf
        /// needs more, so a song that's never scrolled to costs the server nothing more.
        var waitingPicks: [LocalTrack] = []
        /// The same for Suggested Songs and Keep Exploring, which share them.
        var waitingOthers: [LocalTrack] = []
        var loadedAt = Date.distantPast
        /// Still checking covers for more to show: the shelves hold a place for them.
        var isFilling = false
        /// The artists you'd picked when it was made: changing them makes it again.
        var picked: [String]?

        enum CodingKeys: String, CodingKey { case songs, suggested, further, from, queue, asked, waitingPicks, waitingOthers, loadedAt, picked }

        /// Whether there's more to find: songs waiting to be shown, or artists to go on from.
        var canGoOn: Bool { !queue.isEmpty || !waitingPicks.isEmpty || !waitingOthers.isEmpty }
    }

    /// Which list a song found goes to.
    enum Shelf { case picks, suggested, further }

    private(set) var shelves: [String: Shelves] = [:]
    /// Kept between launches, so the last picks are there straight away while new ones come.
    private(set) var forYou: [String: ForYou] = [:] {
        didSet { if !isDemo { savedForYou.save(forYou) } }
    }
    @ObservationIgnored private let savedForYou = CacheFile<[String: ForYou]>("for-you")
    @ObservationIgnored private let isDemo: Bool
    /// Artists you picked for your servers to start from: what For You needs when there's no
    /// listening history or library to go on, and leads with when there is.
    private(set) var pickedArtists: [String] = UserDefaults.standard.stringArray(forKey: ServerDiscovery.pickedArtistsKey) ?? []
    /// Songs from your servers you've never played, found as you scroll.
    private(set) var exploring: [LocalTrack] = []
    /// Found for Keep Exploring and not shown yet: shown one at a time as it's scrolled.
    @ObservationIgnored private var exploringWaiting: [LocalTrack] = []
    private(set) var isExploring = false
    /// Counts steps, so a "load more" row asks again after each one.
    private(set) var explorations = 0

    @ObservationIgnored private unowned let music: YourMusic
    @ObservationIgnored private var seen = Set<String>()
    @ObservationIgnored private var failuresInARow = 0
    /// A first load under way, per server: it clears itself as it ends.
    @ObservationIgnored private var forYouLoads: [String: (id: UUID, seeds: [String], task: Task<Void, Never>)] = [:]
    /// Going on from the next artist, per server: one at a time, cleared as it ends.
    @ObservationIgnored private var goingOn: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    /// Counts each time a shelf going on has had its answer, per server, even one that found
    /// nothing: a shelf whose end is still in view asks again after each.
    private(set) var answers: [String: Int] = [:]
    /// How often each server may be asked to go on: a few at once, then one every few
    /// seconds, however fast the shelves are scrolled.
    @ObservationIgnored private var budgets: [String: RequestBudget] = [:]
    /// Songs by an artist gone on from that the slower search found after the quick one, per
    /// server, with the artists the picks started from: they join the waiting lists when either
    /// shelf next goes on, unless the picks have been made again since.
    @ObservationIgnored private var lateFinds: [String: [(from: [String], artist: String, songs: [SubsonicSong])]] = [:]
    /// The slower searches still going, per server, oldest first.
    @ObservationIgnored private var lateSearches: [String: [(id: UUID, task: Task<Void, Never>)]] = [:]
    /// What the last load was told, for going on later: whether you've heard a song, and
    /// whether you know an artist.
    @ObservationIgnored private var heard: @MainActor (String) -> Bool = { _ in false }
    @ObservationIgnored private var knowsArtist: @MainActor (String) -> Bool = { _ in false }

    private static let pickedArtistsKey = "serverPickedArtists"

    init(music: YourMusic, isDemo: Bool) {
        self.music = music
        self.isDemo = isDemo
        if !isDemo {
            forYou = savedForYou.load() ?? [:]
            // So Tracks Radio can play last time's picks as new finds.
            music.remember(found: forYou.values.flatMap { $0.songs + $0.suggested + $0.further })
            // Covers from last time: from disk, or fetched again if the system cleared them.
            for picks in forYou.values {
                warmCovers(picks.songs)
                warmCovers(picks.suggested)
            }
        }
    }

    // MARK: - Shelves

    /// Loads a server's shelves, unless they were loaded in the last quarter of an hour.
    func loadShelves(for serverID: String, force: Bool = false) async {
        if !force, let loaded = shelves[serverID]?.loadedAt, Date.now.timeIntervalSince(loaded) < 15 * 60 { return }
        guard let client = music.servers.client(for: serverID) else {
            #if DEBUG
            fillDemoShelves(serverID)
            #endif
            return
        }
        async let newest = try? client.albums(.newest, size: 15)
        async let frequent = try? client.albums(.frequent, size: 15)
        async let random = try? client.albums(.random, size: 15)
        var result = Shelves()
        result.newest = (await newest ?? []).map { album(from: $0, serverID: serverID) }
        result.mostPlayed = (await frequent ?? []).map { album(from: $0, serverID: serverID) }
        result.random = (await random ?? []).map { album(from: $0, serverID: serverID) }
        result.loadedAt = .now
        shelves[serverID] = result
    }

    // MARK: - For You

    /// Starts what a server finds for you, unless it's under way: made again when asked, when
    /// your picked artists change, when it has nothing to show, or when it's a few hours old.
    /// Not for every song you play, though what you play moves the artists it starts from: that
    /// would ask the server for dozens of songs and covers every few minutes.
    /// - Parameters:
    ///   - heard: whether you've played a song, by its identity.
    ///   - knowsArtist: whether you play an artist, by name: their songs are Picked for You's,
    ///     everyone else's Suggested Songs'.
    ///   - played: the artists you play most, most first. None is fine: the artists you picked,
    ///     or your library's, start it instead.
    func loadForYou(
        for serverID: String,
        heard: @escaping @MainActor (String) -> Bool,
        knowsArtist: @escaping @MainActor (String) -> Bool,
        played: [String],
        force: Bool = false
    ) async {
        self.heard = heard
        let picked = pickedArtists
        let library = ServerMix.libraryArtists(music.index.tracks)
        let known = Set((picked + library).map(StatsCalculator.folded))
        self.knowsArtist = { known.contains(StatsCalculator.folded($0)) || knowsArtist($0) }
        if !force, let loaded = forYou[serverID], !loaded.songs.isEmpty || !loaded.suggested.isEmpty || loaded.isFilling,
           (loaded.picked ?? []) == picked,
           Date.now.timeIntervalSince(loaded.loadedAt) < Self.picksLast {
            return
        }
        guard music.servers.client(for: serverID) != nil else {
            #if DEBUG
            fillDemoForYou(serverID)
            #endif
            return
        }
        // Which of the artists past your top three it starts from changes each day; every one
        // you play is in the queue, so it goes on to them in time.
        let seeds = ServerMix.seeds(
            picked: picked,
            played: played,
            library: library,
            limit: 40,
            rotation: FreshShuffle.dailySeed(for: .now, salt: "for-you-seeds")
        )
        guard !seeds.isEmpty else {
            forYou[serverID] = ForYou(loadedAt: .now, picked: picked)
            return
        }
        // Already starting from the same artists: wait for it. Its own task, so the section
        // looking again as the page settles doesn't throw away what the server has half done.
        if let loading = forYouLoads[serverID], loading.seeds == seeds {
            await loading.task.value
            return
        }
        let id = UUID()
        let task = Task {
            defer { if forYouLoads[serverID]?.id == id { forYouLoads[serverID] = nil } }
            // What's on show stays until the new picks are ready; an empty shelf fills as they come.
            var fresh = ForYou(from: Array(seeds.prefix(ServerMix.seedCount)), queue: seeds, loadedAt: .now, picked: picked)
            let replaces = forYou[serverID].map { !$0.songs.isEmpty || !$0.suggested.isEmpty } ?? false
            if !replaces {
                fresh.isFilling = true
                forYou[serverID] = fresh
            }
            // Enough for each shelf's first columns, from as few artists as that takes. A column
            // at a time, each shelf in turn, Suggested Songs first as it leads the page: an
            // artist's songs go to both shelves, and neither waits while the other asks for more.
            for shelf in [Shelf.suggested, .picks, .suggested, .picks] {
                guard !Task.isCancelled else { break }
                fresh = await goOn(from: fresh, for: shelf, serverID: serverID, publishing: !replaces, want: SuggestionShelfPaging.rowsPerColumn)
            }
            // Replaced by a load from other artists, which owns the shelf now.
            guard !Task.isCancelled else { return }
            fresh.isFilling = false
            forYou[serverID] = fresh
        }
        // From other artists: the old load stops, rather than finishing over this one.
        forYouLoads[serverID]?.task.cancel()
        forYouLoads[serverID] = (id, seeds, task)
        await task.value
    }

    /// Finds more for a shelf that's been scrolled to its end: shows the next songs already
    /// found, and goes on from the next artist only when those run out, as the server's budget
    /// allows. Up to `want` songs a call, each shown as its cover is there; the shelf asks
    /// again while its end is in view, and stops when it's scrolled away. A first load, or
    /// another shelf going on, is waited for first, rather than the call coming to nothing.
    func loadMore(for serverID: String, shelf: Shelf, want: Int = SuggestionShelfPaging.rowsPerColumn) async {
        while true {
            if let loading = forYouLoads[serverID] {
                await loading.task.value
            } else if let running = goingOn[serverID] {
                await running.task.value
            } else {
                break
            }
            guard !Task.isCancelled else { return }
        }
        // With no server to ask, going on would find nothing, and be asked again at once.
        guard var current = forYou[serverID], current.canGoOn, music.servers.client(for: serverID) != nil else { return }
        let id = UUID()
        let task = Task {
            defer {
                if goingOn[serverID]?.id == id { goingOn[serverID] = nil }
                answers[serverID, default: 0] += 1
            }
            current.isFilling = true
            forYou[serverID] = current
            current = await goOn(from: current, for: shelf, serverID: serverID, publishing: true, want: max(1, want))
            current.isFilling = false
            // Picks made while this went on, as when they were made again, win.
            guard forYou[serverID]?.from == current.from else { return }
            forYou[serverID] = current
        }
        goingOn[serverID] = (id, task)
        await task.value
    }

    /// Adds up to `want` songs to one shelf, each shown as soon as its cover is there. From songs
    /// already found where there are any; otherwise it goes on from the next artist in the queue
    /// first: a few of their songs, songs like them, and the new artists those bring, who join
    /// the end of the queue so it never runs dry. Songs by artists you know wait for Picked for
    /// You, with any of theirs you have and haven't heard; the rest wait for Suggested Songs and
    /// Keep Exploring. Covers are checked for as many songs as are still wanted, a few at once,
    /// and songs whose covers the server couldn't find are left out: the server is only asked
    /// about songs about to show.
    private func goOn(from start: ForYou, for shelf: Shelf, serverID: String, publishing: Bool, want: Int = columnSize) async -> ForYou {
        var feed = start
        var shown = 0
        // Going on from at most two artists a call, so songs without covers can't keep it asking.
        var goneOn = 0
        while shown < want, !Task.isCancelled {
            for find in lateFinds.removeValue(forKey: serverID) ?? [] where find.from == feed.from {
                add(find.songs, from: find.artist, includingYours: false, to: &feed, serverID: serverID)
            }
            let waiting = shelf == .picks ? feed.waitingPicks : feed.waitingOthers
            guard !waiting.isEmpty else {
                // With no artist to go on from, or none the budget allows yet, a slower search
                // still going brings songs sooner: its songs join the lists as it ends.
                if let oldest = lateSearches[serverID]?.first {
                    let budgetSpent = await budget(for: serverID).timeUntilNext > 0
                    if budgetSpent || feed.queue.isEmpty || goneOn >= 2 {
                        await oldest.task.value
                        continue
                    }
                }
                guard goneOn < 2, !feed.queue.isEmpty else { break }
                feed = await findMore(feed, serverID: serverID)
                goneOn += 1
                continue
            }
            let batch = Array(waiting.prefix(want - shown))
            if shelf == .picks { feed.waitingPicks.removeFirst(batch.count) } else { feed.waitingOthers.removeFirst(batch.count) }
            let found = await withCovers(batch)
            switch shelf {
            case .picks: feed.songs += found
            case .suggested: feed.suggested += found
            case .further: feed.further += found
            }
            shown += found.count
            if publishing, !found.isEmpty { forYou[serverID] = feed }
        }
        if publishing { forYou[serverID] = feed }
        return feed
    }

    /// Songs each shelf starts with: a column of four, twice.
    private static let columnSize = 8

    /// Goes on from the next artist in the queue, as the server's budget allows, adding what's
    /// found to the waiting lists. Nothing is asked of the server's covers here.
    private func findMore(_ start: ForYou, serverID: String) async -> ForYou {
        var feed = start
        guard let client = music.servers.client(for: serverID) else { return feed }
        let budget = budget(for: serverID)
        // The next artist not yet gone on from.
        var artist: String?
        while artist == nil, !feed.queue.isEmpty {
            let next = feed.queue.removeFirst()
            if !feed.asked.contains(StatsCalculator.folded(next)) { artist = next }
        }
        guard let artist, (try? await budget.wait()) != nil else { return feed }
        feed.asked.append(StatsCalculator.folded(artist))

        let found = await songs(startingFrom: artist, for: feed.from, serverID: serverID, client: client)
        add(found, from: artist, includingYours: true, to: &feed, serverID: serverID)
        return feed
    }

    /// Adds songs found going on from an artist to the waiting lists, leaving out ones you've
    /// heard or that are there already, and queues the new artists among them.
    /// - Parameter includingYours: add a few of the artist's songs you have and haven't heard
    ///   too, so what you have comes up with what's new.
    private func add(_ found: [SubsonicSong], from artist: String, includingYours: Bool, to feed: inout ForYou, serverID: String) {
        var seen = Set((feed.songs + feed.suggested + feed.further + feed.waitingPicks + feed.waitingOthers).map(\.identity))
        let candidates = found.map { track(from: $0, serverID: serverID) }
            .filter { !heard($0.identity) && seen.insert($0.identity).inserted }
        let yours = !includingYours ? [] : music.index.tracks
            .filter { StatsCalculator.folded($0.artist) == StatsCalculator.folded(artist) && !heard($0.identity) && seen.insert($0.identity).inserted }
            .prefix(3)
        // New artists to go on from later.
        for song in candidates where !knowsArtist(song.artist) {
            let key = StatsCalculator.folded(song.artist)
            if !feed.asked.contains(key), !feed.queue.contains(where: { StatsCalculator.folded($0) == key }), feed.queue.count < 200 {
                feed.queue.append(song.artist)
            }
        }
        music.remember(found: candidates)

        let onlyYours = SuggestionMode.current == .onlyYours
        var picks: (owned: [LocalTrack], new: [LocalTrack]) = (Array(yours), [])
        var discovered: [LocalTrack] = []
        for song in candidates {
            if onlyYours, !music.isInYourMusic(song) { continue }
            if knowsArtist(song.artist) {
                if music.isInYourMusic(song) { picks.owned.append(song) } else { picks.new.append(song) }
            } else {
                discovered.append(song)
            }
        }
        feed.waitingPicks += ServerMix.blend(owned: picks.owned, new: picks.new)
        feed.waitingOthers += FreshShuffle.order(discovered, artist: \.artistKey, seed: FreshShuffle.dailySeed(for: .now, salt: "for-you-\(artist)"))
    }

    private func budget(for serverID: String) -> RequestBudget {
        if let budget = budgets[serverID] { return budget }
        let budget = RequestBudget(capacity: 3, interval: 8)
        budgets[serverID] = budget
        return budget
    }

    /// How long picks stand before they're made again on their own.
    private static let picksLast: TimeInterval = 6 * 60 * 60

    /// Whether a song has a cover to show. A server like Octo sends a stand-in for one it
    /// couldn't find, and a song shown with it looks unfinished: those are left out. A song
    /// from this iPhone always has one, its own or a generated one.
    private func hasCover(_ song: LocalTrack) async -> Bool {
        guard case .server = song.artwork, let url = music.artworkURL(song.artwork) else { return !song.isFromServer }
        return await ArtworkImages.shared.hasCover(url)
    }

    /// The songs with covers to show, in order, checked a few at once: covers on disk answer at
    /// once, and a server's are still fetched one at a time by ``ArtworkImages``.
    private func withCovers(_ songs: [LocalTrack]) async -> [LocalTrack] {
        let checks = songs.indices.map { index -> (index: Int, url: URL?, otherwise: Bool) in
            let song = songs[index]
            guard case .server = song.artwork, let url = music.artworkURL(song.artwork) else { return (index, nil, !song.isFromServer) }
            return (index, url, false)
        }
        let kept = await SuggestionPaging.kept(checks) { check in
            guard let url = check.url else { return check.otherwise }
            return await ArtworkImages.shared.hasCover(url)
        }
        return kept.map { songs[$0.index] }
    }

    /// Fetches the first of a list's covers now, the ones on screen when it appears; the rest
    /// come as their rows do, so a server finding covers elsewhere isn't asked for dozens at once.
    func warmCovers(_ songs: [LocalTrack]) {
        let urls = songs.prefix(8).compactMap { music.artworkURL($0.artwork) }
        guard !urls.isEmpty else { return }
        Task(priority: .utility) { await ArtworkImages.shared.warm(urls) }
    }

    /// A few of an artist's own songs, then songs like the first: the server's search finds
    /// the artist, and its similar songs, which a server like Octo gets from Last.fm, go on
    /// from there.
    /// - Parameter from: the artists the picks started from, so songs found after this returns
    ///   go to the picks they were found for.
    private func songs(startingFrom artist: String, for from: [String], serverID: String, client: SubsonicClient) async -> [SubsonicSong] {
        let key = StatsCalculator.folded(artist)
        let isTheirs = { (song: SubsonicSong) in StatsCalculator.folded(song.artist ?? "") == key }
        // The library's matches first, which Octo answers at once; asked for more, it spends
        // seconds finding songs elsewhere. With the artist in the library, that search goes on
        // while these show, and its songs follow them; without, it's waited for.
        var found = await music.serverSongs(on: serverID, matching: artist, count: MusicServers.quickSearchSize) ?? []
        if found.contains(where: isTheirs) {
            let id = UUID()
            let search = Task { [weak self, music] in
                let more = await music.serverSongs(on: serverID, matching: artist, count: YourMusic.artistSongCount)
                guard let self else { return }
                lateSearches[serverID]?.removeAll { $0.id == id }
                guard let more else { return }
                lateFinds[serverID, default: []].append((from, artist, Array(more.filter(isTheirs).prefix(4))))
            }
            lateSearches[serverID, default: []].append((id, search))
        } else {
            guard let more = await music.serverSongs(on: serverID, matching: artist, count: YourMusic.artistSongCount) else { return [] }
            found = more
        }
        let theirs = found.filter(isTheirs)
        guard let start = theirs.first ?? found.first else { return [] }
        let like = (try? await music.servers.lookups.run { try await client.similarSongs(to: start.id, count: 15) }) ?? []
        return Array(theirs.prefix(4)) + like
    }

    /// Chooses the artists For You starts from. Each server picks again when next shown, as
    /// what it started from no longer matches.
    func setPickedArtists(_ artists: [String]) {
        pickedArtists = artists
        UserDefaults.standard.set(artists, forKey: Self.pickedArtistsKey)
    }

    // MARK: - Moods

    /// Songs for each mood from your servers, and when they were found: songs like ones that
    /// suit it, by way of the server's similar songs. Your music's songs have genres to go by,
    /// but a server like Octo's finds often don't, so they're found by likeness instead.
    private(set) var moodFinds: [Mood: (at: Date, songs: [LocalTrack])] = [:]

    /// Finds songs for a mood on your first server that answers, unless it was done in the
    /// last few hours: a few like each of the first songs that suit it, asked for as the
    /// server's budget allows, leaving out ones you've heard and ones without covers.
    /// - Parameter seeds: songs that suit the mood, the most telling first.
    func loadFinds(for mood: Mood, seeds: [(title: String, artist: String)], heard: (String) -> Bool) async {
        if let known = moodFinds[mood], Date.now.timeIntervalSince(known.at) < Self.picksLast { return }
        guard let server = music.servers.onlineServers.first, let client = music.servers.client(for: server.id) else { return }
        let budget = budgets[server.id] ?? RequestBudget(capacity: 3, interval: 8)
        budgets[server.id] = budget
        var found: [LocalTrack] = []
        for seed in seeds.prefix(2) {
            guard !Task.isCancelled, (try? await budget.wait()) != nil else { break }
            guard let answer = await music.serverSongs(on: server.id, matching: "\(seed.title) \(seed.artist)"),
                  let match = ServerSongMatcher.bestMatch(title: seed.title, artist: seed.artist, in: answer)
            else { continue }
            let like = (try? await music.servers.lookups.run { try await client.similarSongs(to: match.id, count: 15) }) ?? []
            found += like.map { track(from: $0, serverID: server.id) }
        }
        var seen = Set<String>()
        let fresh = FreshShuffle.order(
            found.filter { !heard($0.identity) && seen.insert($0.identity).inserted },
            artist: \.artistKey,
            seed: FreshShuffle.dailySeed(for: .now, salt: "mood-\(mood.rawValue)")
        )
        // Covers one at a time, each song shown as its cover is there, until a dozen are. Dated
        // only once it's done, so one left half done is looked for again next time.
        var songs: [LocalTrack] = []
        for song in fresh where songs.count < 12 {
            guard !Task.isCancelled else { break }
            guard await hasCover(song) else { continue }
            songs.append(song)
            music.remember(found: [song])
            moodFinds[mood] = (.distantPast, songs)
        }
        guard !Task.isCancelled else { return }
        moodFinds[mood] = (.now, songs)
    }

    /// New albums picked at random, for the shelf's refresh button.
    func shuffleRandom(for serverID: String) async {
        guard let client = music.servers.client(for: serverID),
              let albums = try? await client.albums(.random, size: 15)
        else { return }
        shelves[serverID, default: Shelves()].random = albums.map { album(from: $0, serverID: serverID) }
    }

    private func album(from album: SubsonicAlbum, serverID: String) -> Album {
        Album(album, serverID: serverID)
    }

    // MARK: - Handpicked

    /// Songs your first server that answers calls like the picks, for Handpicked: straight
    /// from the server for picks that live on it, by way of the song it matches for the rest.
    /// A few picks at a time as the server's budget allows, and whatever's back within a few
    /// seconds, so the station doesn't keep you waiting.
    func similar(to picks: [LocalTrack]) async -> [LocalTrack] {
        guard let server = music.servers.onlineServers.first, let client = music.servers.client(for: server.id) else { return [] }
        let budget = budgets[server.id] ?? RequestBudget(capacity: 3, interval: 8)
        budgets[server.id] = budget
        let search = Task { @MainActor [music] () -> [LocalTrack] in
            var found: [LocalTrack] = []
            for pick in picks.prefix(4) {
                guard !Task.isCancelled, (try? await budget.wait()) != nil else { break }
                let id: String? = if case .server(let serverID, let songID) = pick.origin, serverID == server.id {
                    songID
                } else {
                    await music.serverSongs(on: server.id, matching: "\(pick.title) \(pick.artist)")
                        .flatMap { ServerSongMatcher.bestMatch(title: pick.title, artist: pick.artist, in: $0) }?.id
                }
                guard let id else { continue }
                let like = (try? await music.servers.lookups.run { try await client.similarSongs(to: id, count: 20) }) ?? []
                found += like.map { self.track(from: $0, serverID: server.id) }
            }
            return found
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(6))
            search.cancel()
        }
        defer { timeout.cancel() }
        var seen = Set<String>()
        return await search.value.filter { seen.insert($0.identity).inserted }
    }

    /// A server song as it is in the library, where it's been synced, with its download.
    private func track(from song: SubsonicSong, serverID: String) -> LocalTrack {
        music.index.track(id: LocalTrack.id(for: .server(serverID: serverID, songID: song.id))) ?? song.track(on: serverID)
    }

    // MARK: - Exploring

    /// Songs you've never played, one more from a server picked at random: from the last lot
    /// found, or a new lot when those run out.
    func exploreMore(heard: (String) -> Bool) async {
        while let next = exploringWaiting.first {
            exploringWaiting.removeFirst()
            if !heard(next.identity) {
                exploring.append(next)
                return
            }
        }
        guard !isExploring else { return }
        isExploring = true
        defer { isExploring = false }
        let online = music.servers.onlineServers
        #if DEBUG
        if online.contains(where: { music.servers.client(for: $0.id) == nil }) {
            exploreDemo(heard: heard)
            return
        }
        #endif
        guard let server = online.randomElement(), let client = music.servers.client(for: server.id) else { return }
        // Each pass counts, so the row asking for more asks again; passes that find nothing
        // new, or nothing at all, count toward giving up, so a small library doesn't ask forever.
        defer { explorations += 1 }
        guard let songs = try? await client.randomSongs(count: 40) else {
            failuresInARow += 1
            return
        }
        let fresh = songs
            .map { track(from: $0, serverID: server.id) }
            .filter { !heard($0.identity) && seen.insert($0.identity).inserted }
        if let first = fresh.first { exploring.append(first) }
        exploringWaiting += fresh.dropFirst()
        failuresInARow = fresh.isEmpty ? failuresInARow + 1 : 0
    }

    /// Whether there's any point asking for more: a server to ask, and it's been answering.
    var canExploreMore: Bool {
        !music.servers.onlineServers.isEmpty && failuresInARow < 3
    }

    // MARK: - Sample data

    #if DEBUG
    private func fillDemoShelves(_ serverID: String) {
        let albums = LocalLibraryIndex(tracks: music.servers.catalogs[serverID] ?? []).albums
        func shelf(_ list: [LocalAlbum]) -> [Album] {
            list.prefix(12).map { Album(id: $0.id, title: $0.title, artist: $0.artist, artwork: $0.artwork, route: .localAlbum($0.id)) }
        }
        var result = Shelves()
        result.newest = shelf(albums.sorted { $0.addedAt > $1.addedAt })
        result.mostPlayed = shelf(albums.reversed())
        result.random = shelf(albums.shuffled())
        result.loadedAt = .now
        shelves[serverID] = result
    }

    private func fillDemoForYou(_ serverID: String) {
        let songs = Array((music.servers.catalogs[serverID] ?? []).shuffled().prefix(16))
        forYou[serverID] = ForYou(songs: songs, from: Array(music.index.artists.prefix(3).map(\.name)), loadedAt: .now)
    }

    private func exploreDemo(heard: (String) -> Bool) {
        let fresh = music.index.tracks.shuffled().filter { seen.insert($0.id).inserted }.prefix(20)
        exploring += fresh
        explorations += 1
        if fresh.isEmpty { failuresInARow = 3 }
    }
    #endif
}

extension ServerDiscovery.Album {
    /// An album on a server, opened from there.
    init(_ album: SubsonicAlbum, serverID: String) {
        self.init(
            id: "\(serverID):\(album.id)",
            title: album.name,
            artist: album.artist ?? "",
            artwork: album.coverArt.map { .server(serverID: serverID, coverID: $0) },
            route: .serverAlbum(serverID: serverID, albumID: album.id)
        )
    }
}

/// An artist on a server, found by searching it: from its library, or one a server like Octo
/// finds elsewhere.
struct ServerArtist: Identifiable, Hashable {
    let serverID: String
    let artistID: String
    let name: String
    let artwork: LocalTrack.Artwork?

    var id: String { "\(serverID):\(artistID)" }

    init(_ artist: SubsonicArtist, serverID: String) {
        self.serverID = serverID
        artistID = artist.id
        name = artist.name
        artwork = artist.coverArt.map { .server(serverID: serverID, coverID: $0) }
    }
}
