import SwiftUI
import MusicKit
import TracksCore
import TracksMusic

/// One part of a song's info on its way: still coming, here (nil when there's nothing to
/// say), or out of reach because the device is offline.
enum SongInfoPart<Value: Equatable>: Equatable {
    case loading
    case loaded(Value?)
    case offline

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    var isLoading: Bool { self == .loading }
}

/// Your history with a song: its profile, when in the day you play it, and the songs you've
/// played from its album and by its artist.
struct SongInfoHistory: Equatable {
    var profile: SongProfile?
    var dayParts: [DayPartPlays]?
    /// Most played first, this song among them.
    var albumSongs: [SongTally] = []
    /// Most played first, without this song.
    var artistSongs: [SongTally] = []
}

/// A song beside the one shown: on its album, or among its artist's best known.
struct RelatedSong: Identifiable, Equatable {
    let subject: SongInfoSubject
    var trackNumber: Int?
    var duration: TimeInterval?
    var isExplicit = false

    var id: String { subject.identity }
}

/// The album's songs and the artist's top songs, as Apple Music or your own library has them.
struct SongRelated: Equatable {
    var album: [RelatedSong] = []
    var topSongs: [RelatedSong] = []
}

/// Gathers a song's info from its sources, nearest first: your history at once, then Apple
/// Music or your own file, then MusicBrainz and Last.fm once the song has been on the page a
/// moment. Answers are kept for the session, and the network's on disk too, so a song opened
/// again shows at once.
@MainActor
@Observable
final class SongInfoModel {
    private(set) var history: SongInfoPart<SongInfoHistory> = .loading
    private(set) var about: SongInfoPart<SongAbout> = .loading
    private(set) var related: SongInfoPart<SongRelated> = .loading
    private(set) var credits: SongInfoPart<SongCredits> = .loading
    private(set) var versions: SongInfoPart<SongVersions> = .loading
    private(set) var lastFM: SongInfoPart<LastFMTrackInfo> = .loading
    /// The song in Apple Music, once found, for its actions.
    private(set) var catalogSong: Song?

    /// What the page needs before it starts asking the network: a song skipped past at once
    /// costs MusicBrainz and Last.fm nothing.
    static let settleDelay: Duration = .milliseconds(350)

    var isOffline: Bool { credits == .offline || versions == .offline || lastFM == .offline }

    /// Whether Last.fm has anything to say here: only with an account connected, as the
    /// privacy policy promises.
    static var asksLastFM: Bool {
        #if DEBUG
        if DemoMode.isRequestedAtLaunch { return SongInfoSamples.showsLastFM }
        #endif
        return LastFMSessionStore.current != nil && LastFMClient.configured() != nil
    }

    // MARK: - History

    func loadHistory(of subject: SongInfoSubject, library: Library) async {
        let history = library.history
        let identity = subject.identity
        let albumTitle = subject.albumTitle
        let next = await OffMainActor.run {
            Self.history(of: identity, albumTitle: albumTitle, in: history)
        }
        guard !Task.isCancelled else { return }
        // Before the library's first read, "never played" would be a guess.
        if next.profile != nil || library.isLoaded, self.history != .loaded(next) {
            self.history = .loaded(next)
        }
    }

    nonisolated static func history(of identity: String, albumTitle: String?, in history: ListeningHistory) -> SongInfoHistory {
        let profile = StatsCalculator.songProfile(id: identity, history: history)
        var found = SongInfoHistory(profile: profile, dayParts: profile.flatMap { SongDayParts.split($0.plays) })
        guard let profile else { return found }
        let album = albumTitle ?? profile.song.albumTitle
        if let album, !album.isEmpty {
            let id = "\(StatsCalculator.folded(album))\u{1F}\(profile.artistID)"
            found.albumSongs = StatsCalculator.albumProfile(id: id, history: history)?.songs ?? []
        }
        found.artistSongs = (StatsCalculator.artistProfile(id: profile.artistID, history: history)?.songs ?? [])
            .filter { $0.id != identity }
        return found
    }

    // MARK: - Everything else

    /// Starts from what's already known about the song, so a song opened again doesn't show
    /// its placeholders for a frame.
    func reset(for subject: SongInfoSubject) {
        let cached = SongInfoMemory.shared
        let catalog = cached.catalog[subject.identity]
        catalogSong = subject.song ?? catalog?.song
        about = catalog.map { .loaded($0.about) } ?? .loading
        related = catalog.map { .loaded($0.related) } ?? .loading
        credits = cached.credits[subject.identity].map(SongInfoPart.loaded) ?? .loading
        versions = cached.versions[subject.identity].map(SongInfoPart.loaded) ?? .loading
        lastFM = !Self.asksLastFM ? .loaded(nil) : cached.lastFM[subject.identity].map(SongInfoPart.loaded) ?? .loading
        history = .loading
    }

    func loadDetails(of subject: SongInfoSubject, model: AppModel) async {
        let memory = SongInfoMemory.shared
        if about.isLoading || related.isLoading {
            let found = await SongInfoSources.catalog(for: subject, model: model)
            guard !Task.isCancelled else { return }
            memory.catalog[subject.identity] = found
            catalogSong = found.song ?? catalogSong
            about = .loaded(found.about)
            related = .loaded(found.related)
        }
        let needsCredits = credits.isLoading || versions.isLoading
        let needsLastFM = lastFM.isLoading
        guard needsCredits || needsLastFM else { return }
        try? await Task.sleep(for: Self.settleDelay)
        guard !Task.isCancelled else { return }

        async let musicBrainz: Void = needsCredits ? loadMusicBrainz(of: subject, model: model) : ()
        async let lastFMLookup = needsLastFM ? SongInfoSources.lastFM(for: subject, model: model) : nil
        let foundLastFM = await lastFMLookup
        await musicBrainz
        guard !Task.isCancelled else { return }
        if let foundLastFM {
            lastFM = foundLastFM
            if case .loaded(let value) = foundLastFM { memory.lastFM[subject.identity] = value }
        }
    }

    /// Credits first, then the versions of the composition they lead to, which MusicBrainz's
    /// pace puts a second behind.
    private func loadMusicBrainz(of subject: SongInfoSubject, model: AppModel) async {
        let memory = SongInfoMemory.shared
        if credits.isLoading {
            let found = await SongInfoSources.credits(for: subject, isrc: about.value?.isrc, length: about.value?.length, model: model)
            guard !Task.isCancelled else { return }
            credits = found
            if case .loaded(let value) = found { memory.credits[subject.identity] = value }
        }
        guard versions.isLoading else { return }
        switch credits {
        case .offline:
            versions = .offline
        case .loaded(let found):
            guard let found, let workID = found.workIDs.first else {
                versions = .loaded(nil)
                memory.versions[subject.identity] = .some(nil)
                return
            }
            let next = await SongInfoSources.versions(for: subject, workID: workID, credits: found, model: model)
            guard !Task.isCancelled else { return }
            versions = next
            if case .loaded(let value) = next { memory.versions[subject.identity] = value }
        case .loading:
            break
        }
    }

    /// Try Again, after the connection comes back.
    func retry() {
        if credits == .offline { credits = .loading }
        if versions == .offline { versions = .loading }
        if lastFM == .offline { lastFM = .loading }
    }
}

/// What's been found this session, by song.
@MainActor
final class SongInfoMemory {
    static let shared = SongInfoMemory()

    struct Catalog {
        let song: Song?
        let about: SongAbout?
        let related: SongRelated?
    }

    var catalog: [String: Catalog] = [:]
    var credits: [String: SongCredits?] = [:]
    var versions: [String: SongVersions?] = [:]
    var lastFM: [String: LastFMTrackInfo?] = [:]
}

/// Where each part of a song's info comes from.
enum SongInfoSources {
    /// "Tracks/1.0 ( https://github.com/reallukedev/tracks )", as MusicBrainz asks a client to
    /// name itself.
    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "Tracks/\(version) ( https://github.com/reallukedev/tracks )"
    }()

    // MARK: Apple Music, or your own file

    static func catalog(for subject: SongInfoSubject, model: AppModel) async -> SongInfoMemory.Catalog {
        if let local = subject.local ?? model.yourMusic.index.tracks(withIdentity: subject.identity).first {
            return .init(song: nil, about: SongAbout(track: local), related: related(for: local, in: model.yourMusic.index))
        }
        guard let song = await catalogSong(for: subject, isDemo: model.isDemoLaunch) else {
            return .init(song: nil, about: nil, related: nil)
        }
        let about = SongAbout(song: song)
        let related = model.isDemoLaunch ? nil : await related(for: song)
        return .init(song: song, about: about, related: related)
    }

    /// The song in Apple Music's catalog with how it's mastered, its album and its artist: by
    /// its id, or found by name for a song known only that way. Nil without access, or for a
    /// song that isn't there.
    private static func catalogSong(for subject: SongInfoSubject, isDemo: Bool) async -> Song? {
        #if DEBUG
        if isDemo {
            try? await SongInfoSamples.wait()
            guard !SongInfoSamples.uncataloged.contains(subject.identity) else { return nil }
            return AboutSamples.song(title: subject.title, artist: subject.artistName, album: subject.albumTitle)
        }
        #endif
        guard !isDemo, MusicAuthorization.currentStatus == .authorized else { return nil }
        var id = subject.catalogID ?? subject.song?.id.rawValue
        if id == nil {
            let query = CatalogQuery(title: subject.title, artistName: subject.artistName, albumTitle: subject.albumTitle)
            id = try? await CatalogLookup().resolve(query)?.id
        }
        guard let id else { return nil }
        var request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
        request.properties = [.audioVariants, .albums, .artists]
        return try? await request.response().items.first
    }

    /// The song's album, in order, and its artist's top songs, asked for together.
    private static func related(for song: Song) async -> SongRelated? {
        async let albumTracks = tracks(of: song)
        async let artistTop = topSongs(of: song)
        let (tracks, top) = await (albumTracks, artistTop)
        let album: [RelatedSong] = tracks.map { tracks in
            tracks.compactMap { track in
                guard case .song(let song) = track else { return nil }
                return RelatedSong(subject: SongInfoSubject(song), trackNumber: song.trackNumber, duration: song.duration, isExplicit: song.contentRating == .explicit)
            }
        } ?? []
        let identity = HistoryImport.key(title: song.title, artistName: song.artistName)
        let topSongs: [RelatedSong] = top.map { songs in
            songs.filter { HistoryImport.key(title: $0.title, artistName: $0.artistName) != identity }
                .prefix(SongRelated.topSongCount)
                .map { RelatedSong(subject: SongInfoSubject($0), duration: $0.duration, isExplicit: $0.contentRating == .explicit) }
        } ?? []
        let related = SongRelated(album: album.count > 1 ? album : [], topSongs: topSongs)
        return related.album.isEmpty && related.topSongs.isEmpty ? nil : related
    }

    private static func tracks(of song: Song) async -> MusicItemCollection<Track>? {
        guard let album = song.albums?.first else { return nil }
        return try? await album.with([.tracks]).tracks
    }

    private static func topSongs(of song: Song) async -> MusicItemCollection<Song>? {
        guard let artist = song.artists?.first else { return nil }
        return try? await artist.with([.topSongs]).topSongs
    }

    /// The rest of a file's album, as your library orders it.
    private static func related(for track: LocalTrack, in index: LocalLibraryIndex) -> SongRelated? {
        guard let album = index.album(id: track.albumKey), album.tracks.count > 1 else { return nil }
        return SongRelated(album: album.tracks.map { song in
            RelatedSong(subject: SongInfoSubject(song), trackNumber: song.trackNumber, duration: song.duration)
        })
    }

    // MARK: MusicBrainz

    static func credits(for subject: SongInfoSubject, isrc: String?, length: TimeInterval?, model: AppModel) async -> SongInfoPart<SongCredits> {
        #if DEBUG
        if model.isDemoLaunch {
            do { try await SongInfoSamples.wait() } catch { return .offline }
            return .loaded(SongInfoSamples.credits(for: subject))
        }
        #endif
        let key = "mb2|\(isrc ?? subject.identity)"
        if case .hit(let saved) = await SongInfoCache.shared.value(SongCredits.self, for: key, lifetime: .credits) {
            return .loaded(saved)
        }
        let client = MusicBrainzClient(userAgent: userAgent)
        do {
            let found = try await client.credits(isrc: isrc, title: subject.title, artistName: subject.artistName, duration: length)
            let kept = found?.isEmpty == false ? found : nil
            await SongInfoCache.shared.store(kept, for: key)
            return .loaded(kept)
        } catch {
            return isOffline(error) ? .offline : .loaded(nil)
        }
    }

    static func versions(for subject: SongInfoSubject, workID: String, credits: SongCredits, model: AppModel) async -> SongInfoPart<SongVersions> {
        #if DEBUG
        if model.isDemoLaunch {
            do { try await SongInfoSamples.wait() } catch { return .offline }
            return .loaded(SongInfoSamples.versions(for: subject))
        }
        #endif
        let key = "mb-work|\(workID)|\(subject.identity)"
        if case .hit(let saved) = await SongInfoCache.shared.value(SongVersions.self, for: key, lifetime: .credits) {
            return .loaded(merged(saved, remixes: credits.remixes))
        }
        let client = MusicBrainzClient(userAgent: userAgent)
        do {
            let found = try await client.versions(workID: workID, title: subject.title, artistName: subject.artistName, excluding: [credits.recordingID])
            let kept = found?.isEmpty == false ? found : nil
            await SongInfoCache.shared.store(kept, for: key)
            return .loaded(merged(kept, remixes: credits.remixes))
        } catch {
            return isOffline(error) ? .offline : .loaded(merged(nil, remixes: credits.remixes))
        }
    }

    /// The recording's remixes among the composition's versions, each once.
    private static func merged(_ versions: SongVersions?, remixes: [RecordingLink]) -> SongVersions? {
        var merged = versions ?? SongVersions()
        let known = Set(merged.versions.map(\.recordingID))
        merged.versions += remixes.filter { !known.contains($0.recordingID) }
        return merged.isEmpty ? nil : merged
    }

    // MARK: Last.fm

    static func lastFM(for subject: SongInfoSubject, model: AppModel) async -> SongInfoPart<LastFMTrackInfo> {
        #if DEBUG
        if model.isDemoLaunch {
            do { try await SongInfoSamples.wait() } catch { return .offline }
            return .loaded(SongInfoSamples.lastFM(for: subject, history: model.library.history))
        }
        #endif
        guard let session = LastFMSessionStore.current, let client = LastFMClient.configured() else { return .loaded(nil) }
        let key = "lastfm|\(session.username)|\(subject.identity)"
        if case .hit(let saved) = await SongInfoCache.shared.value(LastFMTrackInfo.self, for: key, lifetime: .lastFM) {
            return .loaded(saved)
        }
        do {
            async let info = client.trackInfo(title: subject.title, artistName: subject.artistName, username: session.username)
            async let similar = client.similarTracks(title: subject.title, artistName: subject.artistName)
            var found = try await info
            found?.similar = ((try? await similar) ?? []).filter {
                HistoryImport.key(title: $0.title, artistName: $0.artistName) != subject.identity
            }
            let kept = found?.isEmpty == false ? found : nil
            await SongInfoCache.shared.store(kept, for: key)
            return .loaded(kept)
        } catch {
            return isOffline(error) ? .offline : .loaded(nil)
        }
    }

    static func isOffline(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .cannotFindHost, .cannotConnectToHost, .timedOut, .internationalRoamingOff]
            .contains(error.code)
    }
}

extension SongRelated {
    /// An artist's best known, after the song itself.
    static let topSongCount = 5
}
