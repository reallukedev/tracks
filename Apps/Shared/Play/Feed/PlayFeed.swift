import Foundation
import Observation
import MusicKit
import Intents
import TracksCore

/// Everything the Play page shows: mixes worked out from the history, and stations, recent
/// albums and recommendations from Apple Music.
@MainActor
@Observable
final class PlayFeed {
    /// The mixes, rebuilt as the history and the skip signals change.
    private(set) var mixes = MixBuilder.Output.empty
    /// Plays and first hearings by song, for counts beside songs everywhere on the tab.
    private(set) var facts: [String: SongFacts] = [:]
    /// Songs never played, by the artists played most lately, from Apple Music's catalog.
    private(set) var discover: [Song] = []
    /// The artists played most in the last six months, for Your Artists.
    private(set) var favoriteArtists: [FavoriteArtist] = []
    /// New albums and singles from them, newest first.
    private(set) var newReleases: [FeedItem] = []
    /// What Apple Music said about each of your top artists: their songs, latest release and
    /// artists like them. Where Suggested Songs and Suggested Artists start from.
    private(set) var artistLookups: [ArtistLookup] = [] {
        didSet { lookupsRevision += 1 }
    }
    private(set) var lookupsRevision = 0
    /// True once the history has been read and your artists looked up, or found to be none,
    /// so the suggestions can tell "not yet" from "nothing".
    private(set) var hasTriedArtistLookups = false
    /// Apple Music's chart playlists.
    private(set) var charts: [FeedItem] = []

    /// The artists Discover and New Releases draw from, most played first.
    /// Where suggestions start: the artists you play, the recent plays counting most, so what
    /// Tracks suggests moves with your taste rather than staying where it was months ago.
    var topArtists: [String] { Array(tasteArtists.prefix(10)) }
    /// The artists you play, most first, a play half as telling a month on: more than
    /// ``topArtists``, for a mix that wanders past the top of your taste.
    private(set) var tasteArtists: [String] = []
    /// False until the history has been read once, so the page can tell "loading" from "none".
    private(set) var hasBuilt = false
    /// The library revision the mixes were last built from.
    private(set) var builtRevision: Int?

    private(set) var liveStations: [FeedItem] = []
    private(set) var recentlyPlayed: [FeedItem] = []
    /// Apple Music's own picks, each with its title ("Made for You").
    private(set) var recommendations: [Recommendation] = []
    private(set) var appleMusicState: LoadState = .idle
    /// What the account can do, once known. Nil offline or before access is granted.
    private(set) var subscription: MusicSubscription?

    enum LoadState: Equatable {
        case idle, loading, loaded
        case failed
    }

    struct Recommendation: Identifiable {
        let id: String
        let title: String
        let items: [FeedItem]
    }

    @ObservationIgnored private let isDemo: Bool
    @ObservationIgnored private var lastLoaded: Date?
    /// Stations found by name, kept for the session: a name costs a search.
    @ObservationIgnored private var stationsByName: [String: MusicKit.Station] = [:]
    @ObservationIgnored private var missingStations: Set<String> = []
    @ObservationIgnored private var discoverLoaded: (at: Date, artists: Set<String>, allowsExplicit: Bool)?
    /// Every artist the history has, folded, so suggestions only offer new ones.
    @ObservationIgnored private(set) var heardArtists: Set<String> = []
    /// Catalog artists found by name, kept for the session.
    @ObservationIgnored private var catalogArtists: [String: Artist] = [:]

    init(isDemo: Bool) {
        self.isDemo = isDemo
    }

    // MARK: - From the history

    func rebuild(history: ListeningHistory, signals: ListeningSignals, revision: Int? = nil) async {
        let since = Date.now.addingTimeInterval(-180 * 24 * 60 * 60)
        let built = await OffMainActor.run {
            (
                MixBuilder.build(from: history, signals: signals),
                PlayFacts.songs(in: history),
                PlayFacts.favoriteArtists(in: history, since: since),
                Set(history.captures.flatMap(\.creditIdentities)),
                PlayFacts.favoriteArtists(in: history, since: since, limit: 13, halfLife: 30 * 24 * 60 * 60).map(\.name)
            )
        }
        // A newer history arrived while this one was built; its own rebuild will land.
        guard !Task.isCancelled else { return }
        // Blocked artists are no one's to suggest from: not Your Artists, and not where
        // Discover, New Releases and the suggestions look. Those reload as the artists change;
        // until then, theirs come out of what's already there.
        let blocked = signals.blocked
        mixes = built.0
        facts = built.1
        favoriteArtists = built.2.filter { !blocked.contains(artist: $0.name) }
        heardArtists = built.3
        tasteArtists = built.4.filter { !blocked.contains(artist: $0) }
        builtRevision = revision
        // A Discover song leaves once it's been played: it isn't new any more.
        discover.removeAll { facts[HistoryImport.key(title: $0.title, artistName: $0.artistName)] != nil || blocked.blocks(songBy: $0.artistName) }
        newReleases.removeAll { $0.subtitle.map(blocked.blocks(songBy:)) ?? false }
        if artistLookups.contains(where: { blocked.contains(artist: $0.name) }) {
            artistLookups.removeAll { blocked.contains(artist: $0.name) }
        }
        hasBuilt = true
        if isDemo { fillDemoStations() }
    }

    func facts(for track: PlayerTrack?) -> SongFacts? {
        track.flatMap { facts[$0.songIdentity] }
    }

    // MARK: - From Apple Music

    /// Follows the account's subscription, which can start or lapse while Tracks is open.
    func followSubscription() async {
        guard !isDemo else { return }
        for await update in MusicSubscription.subscriptionUpdates {
            subscription = update
            #if os(iOS)
            // Siri weighs this when it picks an app for "play music" without being told one.
            let context = INMediaUserContext()
            context.subscriptionStatus = update.canPlayCatalogContent ? .subscribed : .notSubscribed
            context.becomeCurrent()
            #endif
        }
    }

    /// True when the account is known to be unable to play Apple Music's catalog.
    var cannotPlayCatalog: Bool {
        subscription.map { !$0.canPlayCatalogContent } ?? false
    }

    /// Loads the Apple Music shelves, unless they were loaded in the last few minutes.
    func loadAppleMusic(force: Bool = false) async {
        guard !isDemo else { return }
        guard MusicAuthorization.currentStatus == .authorized else {
            appleMusicState = .idle
            return
        }
        if !force, let lastLoaded, Date.now.timeIntervalSince(lastLoaded) < 5 * 60 { return }
        if appleMusicState != .loaded { appleMusicState = .loading }

        async let live = loadLiveStations()
        async let recent = loadRecentlyPlayed()
        async let picks = loadRecommendations()
        async let chartItems = loadCharts()
        let (liveItems, recentItems, pickGroups, chartPlaylists) = await (live, recent, picks, chartItems)
        charts = chartPlaylists ?? charts

        liveStations = liveItems
        recentlyPlayed = recentItems ?? recentlyPlayed
        if let pickGroups {
            recommendations = await appleMusicPicks(from: pickGroups, besides: recentlyPlayed)
        }
        // Nothing at all came back: most likely offline.
        let gotSomething = !liveItems.isEmpty || recentItems != nil || pickGroups != nil
        appleMusicState = gotSomething ? .loaded : .failed
        if gotSomething { lastLoaded = .now }
    }

    private func loadLiveStations() async -> [FeedItem] {
        let found = await stations(named: AppleMusicStations.live, mustBeLive: true)
        return AppleMusicStations.live.compactMap { name in
            // The LIVE badge says what a subtitle would.
            found[name].map { FeedItem(station: $0, subtitle: "") }
        }
    }

    /// Stations by exact name, from the session's cache or a search. Radio stations can't be
    /// looked up by name any other way, and the history only knows names.
    private func stations(named names: [String], mustBeLive: Bool) async -> [String: MusicKit.Station] {
        var found: [String: MusicKit.Station] = [:]
        var wanted: [String] = []
        for name in names {
            if let cached = stationsByName[name] {
                found[name] = cached
            } else if !missingStations.contains(name) {
                wanted.append(name)
            }
        }
        let looked = await Self.search(wanted, mustBeLive: mustBeLive)
        for (name, result) in looked {
            switch result {
            case .found(let station):
                stationsByName[name] = station
                found[name] = station
            case .none:
                missingStations.insert(name)
            case .failed:
                // Offline, most likely. Asked again next time.
                break
            }
        }
        return found
    }

    private enum StationSearch: Sendable {
        case found(MusicKit.Station)
        case none
        case failed
    }

    /// Side by side rather than one after another.
    @concurrent
    private nonisolated static func search(_ names: [String], mustBeLive: Bool) async -> [String: StationSearch] {
        await withTaskGroup(of: (String, StationSearch).self) { group in
            for name in names {
                group.addTask { (name, await searchOne(name, mustBeLive: mustBeLive)) }
            }
            var results: [String: StationSearch] = [:]
            for await (name, result) in group { results[name] = result }
            return results
        }
    }

    private nonisolated static func searchOne(_ name: String, mustBeLive: Bool) async -> StationSearch {
        var request = MusicCatalogSearchRequest(term: name, types: [MusicKit.Station.self])
        request.limit = 10
        guard let response = try? await request.response() else { return .failed }
        let wanted = StatsCalculator.folded(name)
        let match = response.stations.first {
            StatsCalculator.folded($0.name) == wanted && (!mustBeLive || $0.isLive)
        }
        return match.map(StationSearch.found) ?? .none
    }

    private func loadRecentlyPlayed() async -> [FeedItem]? {
        var request = MusicRecentlyPlayedContainerRequest()
        request.limit = 15
        guard let response = try? await request.response() else { return nil }
        var seen = Set<String>()
        return FeedItem.versions(response.items.compactMap(FeedItem.init(recent:)).filter { seen.insert($0.id).inserted })
    }

    private func loadRecommendations() async -> [Recommendation]? {
        var request = MusicPersonalRecommendationsRequest()
        request.limit = 12
        guard let response = try? await request.response() else { return nil }
        return response.recommendations.compactMap { recommendation in
            let items = FeedItem.versions(recommendation.items.compactMap(FeedItem.init(recommended:)))
            guard !items.isEmpty, let title = recommendation.title, !title.isEmpty else { return nil }
            return Recommendation(id: recommendation.id.rawValue, title: title, items: items)
        }
    }

    /// Apple Music's picks, three rows of them: its recommendations less the ones Play already
    /// shows (its own Recently Played), topped up with the most played albums if it gave fewer.
    private func appleMusicPicks(from recommendations: [Recommendation], besides recent: [FeedItem]) async -> [Recommendation] {
        let recentIDs = Set(recent.map(\.id))
        var rows = recommendations.filter { row in
            let repeats = row.items.filter { recentIDs.contains($0.id) }.count
            return repeats * 2 < row.items.count && !StatsCalculator.folded(row.title).contains("recently played")
        }
        if rows.count < Self.pickRows, let albums = await loadTopAlbums(), !albums.isEmpty {
            rows.append(Recommendation(id: "tracks.topAlbums", title: String(localized: "Top Albums on Apple Music"), items: albums))
        }
        return Array(rows.prefix(Self.pickRows))
    }

    static let pickRows = 3

    private func loadTopAlbums() async -> [FeedItem]? {
        var request = MusicCatalogChartsRequest(kinds: [.mostPlayed], types: [Album.self])
        request.limit = 20
        guard let chart = try? await request.response().albumCharts.first else { return nil }
        return PlayPreferences.versions(of: Array(chart.items)).map(FeedItem.init(album:))
    }

    // MARK: - From your artists

    /// Looks up the artists you play most, once each: songs of theirs you've never played
    /// (Discover), their new releases, and artists like them for the suggestions.
    /// Kept for six hours, or until those artists or the explicit setting change.
    func loadFromYourArtists(force: Bool = false) async {
        defer { if hasBuilt { hasTriedArtistLookups = true } }
        guard !isDemo, MusicAuthorization.currentStatus == .authorized, !topArtists.isEmpty else { return }
        let allowsExplicit = PlayPreferences.allowsExplicit
        if !force, let loaded = discoverLoaded, loaded.artists == Set(topArtists), loaded.allowsExplicit == allowsExplicit,
           Date.now.timeIntervalSince(loaded.at) < 6 * 60 * 60 {
            return
        }
        let names = topArtists
        let lookups = await Self.lookUp(names, known: catalogArtists)
        guard !Task.isCancelled else { return }
        // Nothing at all most likely means offline: try again next time rather than keep it.
        guard !lookups.isEmpty else { return }
        for lookup in lookups { catalogArtists[lookup.name] = lookup.artist }

        let heard = Set(facts.keys)
        // Two of your artists can share a song or an album, and a shelf shows each once.
        var seenSongs = Set<MusicItemID>()
        let unheard = lookups.flatMap { lookup in
            lookup.topSongs
                .filter { !heard.contains(HistoryImport.key(title: $0.title, artistName: $0.artistName)) }
                .prefix(4)
        }
        .filter { seenSongs.insert($0.id).inserted }
        discover = FreshShuffle.order(
            PlayPreferences.versions(of: unheard, allowsExplicit: allowsExplicit),
            artist: { StatsCalculator.folded($0.artistName) },
            seed: FreshShuffle.dailySeed(for: .now, salt: "discover")
        )

        // Out in the last three months, newest first.
        let cutoff = Date.now.addingTimeInterval(-90 * 24 * 60 * 60)
        var seenAlbums = Set<MusicItemID>()
        let releases = lookups.compactMap(\.latestRelease)
            .filter { ($0.releaseDate ?? .distantPast) >= cutoff && seenAlbums.insert($0.id).inserted }
            .sorted { ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) }
        newReleases = PlayPreferences.versions(of: releases, allowsExplicit: allowsExplicit).map(FeedItem.init(album:))

        artistLookups = lookups

        discoverLoaded = (.now, Set(names), allowsExplicit)
    }

    /// The catalog artist for a name from the history, looked up once per session. Nil when
    /// Apple Music has no artist by exactly that name, or can't be reached.
    /// Catalog artists for several names at once: the ones already known, and the rest looked
    /// up side by side. In the order given, less any Apple Music doesn't have.
    func catalogArtists(named names: [String]) async -> [Artist] {
        guard !isDemo, MusicAuthorization.currentStatus == .authorized else { return [] }
        let wanted = names.filter { catalogArtists[$0] == nil }
        let found = await Self.catalogArtists(named: wanted)
        for (name, artist) in found { catalogArtists[name] = artist }
        return names.compactMap { catalogArtists[$0] }
    }

    @concurrent
    private nonisolated static func catalogArtists(named names: [String]) async -> [String: Artist] {
        await withTaskGroup(of: (String, Artist?).self) { group in
            for name in names {
                group.addTask { (name, await catalogArtist(named: name)) }
            }
            var found: [String: Artist] = [:]
            for await (name, artist) in group { found[name] = artist }
            return found
        }
    }

    func catalogArtist(named name: String) async -> Artist? {
        if let known = catalogArtists[name] { return known }
        guard !isDemo, MusicAuthorization.currentStatus == .authorized else { return nil }
        let found = await Self.catalogArtist(named: name)
        if let found { catalogArtists[name] = found }
        return found
    }

    struct ArtistLookup: Sendable {
        let name: String
        let artist: Artist
        let topSongs: [Song]
        let latestRelease: Album?
        let similar: [Artist]
    }

    /// Each artist with their top songs, latest release and similar artists, side by side,
    /// in the order given.
    @concurrent
    private nonisolated static func lookUp(_ names: [String], known: [String: Artist]) async -> [ArtistLookup] {
        await withTaskGroup(of: (Int, ArtistLookup?).self) { group in
            for (rank, name) in names.enumerated() {
                let cached = known[name]
                group.addTask {
                    let found: Artist? = if let cached { cached } else { await catalogArtist(named: name) }
                    guard let artist = found,
                          let detailed = try? await artist.with([.topSongs, .latestRelease, .similarArtists])
                    else { return (rank, nil) }
                    return (rank, ArtistLookup(
                        name: name,
                        artist: artist,
                        topSongs: Array(detailed.topSongs ?? []),
                        latestRelease: detailed.latestRelease,
                        similar: Array(detailed.similarArtists ?? [])
                    ))
                }
            }
            var byRank: [Int: ArtistLookup] = [:]
            for await (rank, lookup) in group { byRank[rank] = lookup }
            return byRank.keys.sorted().compactMap { byRank[$0] }
        }
    }

    /// The catalog artist with exactly this name, if there is one.
    private nonisolated static func catalogArtist(named name: String) async -> Artist? {
        var request = MusicCatalogSearchRequest(term: name, types: [Artist.self])
        request.limit = 5
        guard let response = try? await request.response() else { return nil }
        let wanted = StatsCalculator.folded(name)
        return response.artists.first { StatsCalculator.folded($0.name) == wanted }
    }

    /// Apple Music's chart playlists: "Top 100: Global", then the city charts, or the most
    /// played playlists where the storefront has neither.
    private func loadCharts() async -> [FeedItem]? {
        var request = MusicCatalogChartsRequest(kinds: [.dailyGlobalTop, .cityTop, .mostPlayed], types: [Playlist.self])
        request.limit = 12
        guard let response = try? await request.response() else { return nil }
        let charts = response.playlistCharts
        let ranked = charts.filter { $0.kind != .mostPlayed }.sorted { $0.kind == .dailyGlobalTop && $1.kind != .dailyGlobalTop }
        let chosen = ranked.contains { !$0.items.isEmpty } ? ranked : charts.filter { $0.kind == .mostPlayed }
        var seen = Set<MusicItemID>()
        return chosen.flatMap(\.items)
            .filter { seen.insert($0.id).inserted }
            .prefix(12)
            .map(FeedItem.init(playlist:))
    }

    // MARK: - Sample data

    /// With sample data, the radio shelf shows made-up live stations that play sample songs.
    private func fillDemoStations() {
        liveStations = AppleMusicStations.live.prefix(4).map {
            FeedItem(demoStation: $0, subtitle: nil, isLive: true)
        }
        appleMusicState = .loaded
    }
}
