import Foundation
import Observation
import MusicKit
import TracksCore

/// Why Tracks suggests a song, in a line under it.
enum SuggestionReason: Hashable {
    /// A song by one of your artists you've never played.
    case moreFrom(String)
    /// A song by an artist like one of yours.
    case like(String)
    /// On a new release by this artist.
    case newRelease(String)
    /// High in Apple Music's charts.
    case popular
    case mood(Mood)

    var line: String {
        switch self {
        case .moreFrom(let artist): String(localized: "More from \(artist)")
        case .like(let artist): String(localized: "Because you like \(artist)")
        case .newRelease(let artist): String(localized: "New from \(artist)")
        case .popular: String(localized: "Popular on Apple Music")
        case .mood(let mood): String(localized: "For \(mood.title)")
        }
    }

    var symbol: String {
        switch self {
        case .moreFrom: "person.crop.circle"
        case .like: "sparkles"
        case .newRelease: "calendar"
        case .popular: "chart.line.uptrend.xyaxis"
        case .mood(let mood): mood.symbol
        }
    }
}

/// A song you've never played, and why it's suggested.
struct Suggestion: Identifiable, Equatable {
    let song: Song
    let reason: SuggestionReason

    var id: MusicItemID { song.id }
    var identity: String { HistoryImport.key(title: song.title, artistName: song.artistName) }
}

/// An artist you've never played, and which of yours they're like.
struct SuggestedArtist: Identifiable, Equatable {
    let artist: Artist
    /// Your artists this one is like, the one that led here first.
    var because: [String]

    var id: MusicItemID { artist.id }
    var genre: String? { artist.genreNames?.first { $0 != "Music" } }

    /// "Like Mara Solis", for a tile's one short line.
    var shortLine: String {
        String(localized: "Like \(because.first ?? artist.name)")
    }

    /// "Like Mara Solis", or "Like Mara Solis and Nova Harbor".
    var line: String {
        let names = because.prefix(2).formatted(.list(type: .and))
        return String(localized: "Like \(names)")
    }
}

/// Songs and artists you've never played that Tracks thinks you'll like. It starts from the
/// artists you play most and walks out to the artists like them, and on from those, so it
/// never runs out: every step out finds more.
@MainActor
@Observable
final class Discovery {
    /// Suggested songs as they're found: new songs by your artists among songs by artists
    /// like them, no artist twice in a row.
    private(set) var songs: [Suggestion] = []
    /// Every song by your own artists that Apple Music ranks among their best and you've never
    /// played.
    private(set) var fromYourArtists: [Suggestion] = []
    /// Suggested artists as they're found, the ones most like yours first.
    private(set) var artists: [SuggestedArtist] = []
    private(set) var isExpanding = false
    /// False once the walk has no artists left to visit.
    private(set) var canExpand = true
    /// True once suggestions have been worked out from your artists, even if there are none.
    private(set) var hasSeeded = false
    /// Counts steps out that got an answer, so a "load more" row asks again after each one,
    /// even one that found nothing new. A step that couldn't reach Apple Music doesn't count,
    /// so an offline list doesn't ask over and over.
    private(set) var expansions = 0
    /// The last step out couldn't reach Apple Music. Shelves offer Try Again rather than wait
    /// on it: asking again by themselves would ask over and over while offline.
    private(set) var expandFailed = false
    /// How many suggested songs the Suggested Songs shelf has opened up to so far, a page at a
    /// time as it's scrolled to its end. Keep Exploring carries on from the one after.
    var shelfReach = Discovery.shelfPage
    static let shelfPage = 16

    /// New albums and singles from your artists, and ones not out yet.
    private(set) var releases: [Release] = []
    private(set) var releasesState: PlayFeed.LoadState = .idle

    @ObservationIgnored private let feed: PlayFeed
    @ObservationIgnored private let player: PlayerModel
    @ObservationIgnored private let isDemo: Bool
    /// Artists still to visit, each with the artist of yours that led there.
    @ObservationIgnored private var frontier: [(artist: Artist, root: String)] = []
    @ObservationIgnored private var visited: Set<MusicItemID> = []
    @ObservationIgnored private var seenSongs: Set<String> = []
    /// Songs by your artists not yet in the stream, fed in among the others.
    @ObservationIgnored private var pendingYours: [Suggestion] = []
    /// Starts again from zero each time the suggestions do, so a late answer from an old
    /// walk is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var releasesLoaded: (at: Date, artists: [String])?
    /// Artists asked not to be suggested, folded, kept on this iPhone.
    @ObservationIgnored private var hiddenArtists: Set<String>
    #if DEBUG
    /// Where the next invented songs and artists start, so none shares an id with another.
    @ObservationIgnored private var demoSongOffset = 0
    @ObservationIgnored private var demoArtistOffset = 0
    #endif

    private static let hiddenArtistsKey = "discoveryHiddenArtists"
    /// Artists visited in each step out.
    private static let stepSize = 6

    init(feed: PlayFeed, player: PlayerModel, isDemo: Bool) {
        self.feed = feed
        self.player = player
        self.isDemo = isDemo
        self.hiddenArtists = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenArtistsKey) ?? [])
    }

    /// Songs for Tracks Radio's new finds.
    var newFinds: [Song] {
        var seen = Set<MusicItemID>()
        return (songs + fromYourArtists).map(\.song).filter { seen.insert($0.id).inserted }
    }

    /// Why each of ``newFinds`` was suggested, as Tracks Radio says it, by song identity: an
    /// artist of yours, or one like yours. Suggestions for a mood or the charts are just new.
    var newFindReasons: [String: LiveMix.Reason] {
        var reasons: [String: LiveMix.Reason] = [:]
        for suggestion in songs + fromYourArtists {
            let identity = HistoryImport.key(title: suggestion.song.title, artistName: suggestion.song.artistName)
            guard reasons[identity] == nil else { continue }
            switch suggestion.reason {
            case .moreFrom, .newRelease: reasons[identity] = .newFromYourArtist
            case .like(let artist): reasons[identity] = .newFindLike(artist)
            case .popular, .mood: break
            }
        }
        return reasons
    }

    // MARK: - Walking out from your artists

    /// Starts again from your top artists. Called when they, or the explicit setting, change.
    func reseed() async {
        generation += 1
        // A step from the walk before is dropped when it answers; this one starts now.
        isExpanding = false
        frontier = []
        visited = []
        seenSongs = []
        pendingYours = []
        songs = []
        fromYourArtists = []
        artists = []
        canExpand = true
        expandFailed = false
        shelfReach = Self.shelfPage

        #if DEBUG
        if isDemo {
            seedDemo()
            return
        }
        #endif

        let lookups = feed.artistLookups
        guard !lookups.isEmpty else {
            // Nothing to start from yet, or ever: only "none" once the lookups have been tried.
            hasSeeded = feed.hasBuilt && feed.hasTriedArtistLookups
            canExpand = false
            return
        }
        for lookup in lookups { visited.insert(lookup.artist.id) }

        fromYourArtists = order(lookups.flatMap { lookup in
            fresh(lookup.topSongs).prefix(6).map { Suggestion(song: $0, reason: .moreFrom(lookup.name)) }
        })
        pendingYours = fromYourArtists

        // Like more of your artists ranks higher; ties go to the better-loved artist's.
        var score: [MusicItemID: (count: Int, first: Int, artist: Artist, because: [String])] = [:]
        for (rank, lookup) in lookups.enumerated() {
            for similar in lookup.similar where !visited.contains(similar.id) {
                let existing = score[similar.id]
                score[similar.id] = (
                    (existing?.count ?? 0) + 1,
                    existing?.first ?? rank,
                    similar,
                    (existing?.because ?? []) + [lookup.name]
                )
            }
        }
        let ranked = score.values.sorted { $0.count == $1.count ? $0.first < $1.first : $0.count > $1.count }
        // Artists you already play are walked through, to reach the ones past them you don't.
        let step = SuggestionWalk.step(
            from: ranked,
            id: { $0.artist.id },
            name: { $0.artist.name },
            visited: &visited,
            heard: feed.heardArtists,
            isLeftOut: isLeftOut
        )
        artists = step.new.map { SuggestedArtist(artist: $0.artist, because: $0.because) }
        frontier = step.walk.map { ($0.artist, $0.because.first ?? "") }
        hasSeeded = true

        // The first step out, so the shelf opens with songs by artists like yours.
        await expand()
    }

    /// Visits the next few artists on the walk: their best songs you've never played go into
    /// the stream, and the artists like them onto the walk and the suggested artists.
    func expand() async {
        guard hasSeeded, canExpand, !isExpanding else { return }
        let generation = generation
        isExpanding = true
        expandFailed = false
        // Only this walk's step says it's done: a reseed may have started another.
        defer { if generation == self.generation { isExpanding = false } }

        #if DEBUG
        if isDemo {
            expandDemo()
            return
        }
        #endif

        // A step can find nothing new (everyone visited, every song played): keep walking a
        // little further rather than leave the list waiting at its end.
        for _ in 0..<3 {
            let step = Array(frontier.prefix(Self.stepSize))
            frontier.removeFirst(step.count)
            var likes: [Suggestion] = []
            if !step.isEmpty {
                let found = await Self.visit(step.map(\.artist))
                guard generation == self.generation else { return }
                guard !found.isEmpty else {
                    // Apple Music couldn't be reached: keep these artists for the next try.
                    frontier.insert(contentsOf: step, at: 0)
                    expandFailed = true
                    return
                }
                for (artist, root) in step {
                    guard let visit = found[artist.id] else { continue }
                    likes += fresh(visit.topSongs).prefix(2).map { Suggestion(song: $0, reason: .like(root)) }
                    let next = SuggestionWalk.step(
                        from: visit.similar,
                        id: \.id,
                        name: \.name,
                        visited: &visited,
                        heard: feed.heardArtists,
                        isLeftOut: isLeftOut
                    )
                    frontier += next.walk.map { ($0, root) }
                    artists += next.new.map { SuggestedArtist(artist: $0, because: [root]) }
                }
            }
            // One of your artists' songs for every two by artists like them.
            let yours = Array(pendingYours.prefix(step.isEmpty ? 8 : max(1, likes.count / 2)))
            pendingYours.removeFirst(yours.count)
            let batch = order(likes + yours)
            songs += batch
            if frontier.isEmpty, pendingYours.isEmpty { canExpand = false }
            if !batch.isEmpty || !canExpand { break }
        }
        expansions += 1
    }

    /// Takes out songs you've played since they were suggested: they aren't new any more.
    func prune() {
        let blocked = player.signals.blocked
        // Heard now, or by someone just blocked.
        let gone = { (suggestion: Suggestion) in
            self.feed.facts[suggestion.identity] != nil || blocked.blocks(songBy: suggestion.song.artistName)
        }
        if songs.contains(where: gone) || fromYourArtists.contains(where: gone) || pendingYours.contains(where: gone) {
            songs.removeAll(where: gone)
            fromYourArtists.removeAll(where: gone)
            pendingYours.removeAll(where: gone)
        }
        if artists.contains(where: { blocked.contains(artist: $0.artist.name) }) {
            artists.removeAll { blocked.contains(artist: $0.artist.name) }
        }
        frontier.removeAll { blocked.contains(artist: $0.artist.name) }
    }

    /// Takes a song out of the suggestions, and has the mixes suggest it less.
    func dismiss(_ suggestion: Suggestion) {
        songs.removeAll { $0.id == suggestion.id }
        fromYourArtists.removeAll { $0.id == suggestion.id }
        pendingYours.removeAll { $0.id == suggestion.id }
        player.setSuggestLess(suggestion.identity, true)
    }

    /// Stops suggesting an artist, here and in future.
    func hide(_ artist: SuggestedArtist) {
        let key = StatsCalculator.folded(artist.artist.name)
        hiddenArtists.insert(key)
        UserDefaults.standard.set(Array(hiddenArtists), forKey: Self.hiddenArtistsKey)
        artists.removeAll { $0.id == artist.id }
        songs.removeAll { StatsCalculator.folded($0.song.artistName) == key }
        frontier.removeAll { $0.artist.id == artist.id }
        player.confirm(String(localized: "Tracks Won't Suggest \(artist.artist.name)"))
    }

    /// Songs worth suggesting: the version the explicit setting allows, never played, not
    /// asked to hear less of, and not already suggested.
    private func fresh(_ candidates: [Song]) -> [Song] {
        PlayPreferences.versions(of: candidates).filter { song in
            let identity = HistoryImport.key(title: song.title, artistName: song.artistName)
            return feed.facts[identity] == nil
                && !player.signals.excludes(identity, now: .now)
                && !hiddenArtists.contains(StatsCalculator.folded(song.artistName))
                && seenSongs.insert(identity).inserted
        }
    }

    /// An artist asked not to be suggested, or blocked: never suggested, and never walked to.
    private func isLeftOut(_ name: String) -> Bool {
        hiddenArtists.contains(StatsCalculator.folded(name)) || player.signals.blocked.contains(artist: name)
    }

    /// Spread out so no artist comes twice in a row, the same way all day.
    private func order(_ suggestions: [Suggestion]) -> [Suggestion] {
        FreshShuffle.order(
            suggestions,
            artist: { StatsCalculator.folded($0.song.artistName) },
            seed: FreshShuffle.dailySeed(for: .now, salt: "suggestions.\(songs.count)")
        )
    }

    private struct Visit: Sendable {
        let topSongs: [Song]
        let similar: [Artist]
    }

    /// Each artist's best songs and the artists like them, side by side.
    @concurrent
    private nonisolated static func visit(_ artists: [Artist]) async -> [MusicItemID: Visit] {
        await withTaskGroup(of: (MusicItemID, Visit)?.self) { group in
            for artist in artists {
                group.addTask {
                    guard let detailed = try? await artist.with([.topSongs, .similarArtists]) else { return nil }
                    return (artist.id, Visit(topSongs: Array(detailed.topSongs ?? []), similar: Array(detailed.similarArtists ?? [])))
                }
            }
            var found: [MusicItemID: Visit] = [:]
            for await result in group {
                if let (id, visit) = result { found[id] = visit }
            }
            return found
        }
    }

    // MARK: - New releases

    /// A new or upcoming release by one of your artists.
    struct Release: Identifiable, Equatable {
        enum Kind { case album, ep, single }

        let album: Album
        var id: MusicItemID { album.id }
        var date: Date? { album.releaseDate }
        var isUpcoming: Bool { (album.releaseDate ?? .distantPast) > .now }

        var kind: Kind {
            if album.isSingle == true || album.trackCount <= 3 { return .single }
            return album.trackCount <= 6 ? .ep : .album
        }
    }

    /// Looks up everything your top artists have put out in the last six months or have coming,
    /// once every few hours.
    func loadReleases(force: Bool = false) async {
        let names = feed.favoriteArtists.prefix(25).map(\.name)
        if !force, let loaded = releasesLoaded, loaded.artists == names,
           Date.now.timeIntervalSince(loaded.at) < 3 * 60 * 60 {
            return
        }
        #if DEBUG
        if isDemo {
            releases = DemoCatalog.releases(by: names)
            releasesState = .loaded
            return
        }
        #endif
        guard !isDemo, MusicAuthorization.currentStatus == .authorized, !names.isEmpty else {
            releasesState = .loaded
            return
        }
        if releases.isEmpty { releasesState = .loading }

        let artists = await feed.catalogArtists(named: Array(names))
        let albums = await Self.releases(of: artists)
        let cutoff = Date.now.addingTimeInterval(-183 * 24 * 60 * 60)
        var seen = Set<MusicItemID>()
        let recent = albums.filter { ($0.releaseDate ?? .distantPast) >= cutoff && seen.insert($0.id).inserted }
        releases = PlayPreferences.versions(of: recent)
            .map(Release.init)
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        // Nothing at all came back: most likely offline, so the next visit asks again.
        let failed = albums.isEmpty && releases.isEmpty
        releasesState = failed ? .failed : .loaded
        releasesLoaded = failed ? nil : (.now, names)
    }

    @concurrent
    private nonisolated static func releases(of artists: [Artist]) async -> [Album] {
        await withTaskGroup(of: [Album].self) { group in
            for artist in artists {
                group.addTask {
                    guard let detailed = try? await artist.with([.latestRelease, .singles, .fullAlbums]) else { return [] }
                    return [detailed.latestRelease].compactMap(\.self)
                        + Array(detailed.singles ?? [])
                        + Array(detailed.fullAlbums ?? [])
                }
            }
            var albums: [Album] = []
            for await found in group { albums += found }
            return albums
        }
    }

    // MARK: - Sample data

    #if DEBUG
    /// With sample data there's no Apple Music: invented songs and artists stand in, so the
    /// pages can be seen and screenshotted.
    private func seedDemo() {
        let roots = feed.favoriteArtists.prefix(6).map(\.name)
        guard !roots.isEmpty else {
            hasSeeded = feed.hasBuilt
            canExpand = false
            return
        }
        demoSongOffset = 0
        demoArtistOffset = 14
        fromYourArtists = DemoCatalog.songs(count: 12, offset: 500, artists: roots).map { Suggestion(song: $0, reason: .moreFrom($0.artistName)) }
        artists = DemoCatalog.artists(count: 14, offset: 0).enumerated().map { index, artist in
            SuggestedArtist(artist: artist, because: [roots[index % roots.count]] + (index % 3 == 0 ? [roots[(index + 1) % roots.count]] : []))
        }
        pendingYours = fromYourArtists
        hasSeeded = true
        expandDemo()
    }

    private func expandDemo() {
        let roots = feed.favoriteArtists.prefix(6).map(\.name)
        let offset = demoSongOffset
        demoSongOffset += 16
        let likes = DemoCatalog.songs(count: 16, offset: offset, artists: nil).enumerated().map { index, song in
            Suggestion(song: song, reason: .like(roots[index % max(1, roots.count)]))
        }
        let yours = Array(pendingYours.prefix(6))
        pendingYours.removeFirst(yours.count)
        songs += order(likes + yours)
        artists += DemoCatalog.artists(count: 8, offset: demoArtistOffset).map {
            SuggestedArtist(artist: $0, because: [roots[$0.name.count % max(1, roots.count)]])
        }
        demoArtistOffset += 8
        canExpand = demoSongOffset < 160
        expansions += 1
    }
    #endif
}
