import Foundation
import Observation
import MusicKit
import TracksCore
import TracksMusic

/// Keeps your Tracks playlists and your Apple Music playlists together, when you choose to.
/// Playlists with the same name are merged, and each side gets the other's that it doesn't
/// have. Each time Tracks opens: songs added in Apple Music are found in your music, or on your
/// server, which a server like Octo fetches, and are downloaded; songs added in Tracks are added
/// in Apple Music; songs taken out in Apple Music come out here too. Apple Music doesn't let
/// apps take songs out, so ones taken out here stay there, and aren't brought back.
@MainActor
@Observable
final class PlaylistMerge {
    static let storageKey = "mergesAppleMusicPlaylists"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: storageKey) }

    private(set) var isMerging = false
    private(set) var lastMerged: Date? = UserDefaults.standard.object(forKey: PlaylistMerge.mergedAtKey) as? Date {
        didSet { UserDefaults.standard.set(lastMerged, forKey: Self.mergedAtKey) }
    }
    /// What stopped the last merge, to say in Settings.
    private(set) var problem: String?
    /// Songs from Apple Music left to look for, a merge taking so many at a time.
    private(set) var leftToFind = 0

    @ObservationIgnored private weak var music: YourMusic?
    /// Your server is asked for one song at a time, a couple a few seconds.
    @ObservationIgnored private let budget = RequestBudget(capacity: 2, interval: 3)
    private static let mergedAtKey = "playlistsMergedAt"
    /// At most this many songs looked for on your server, and added in Apple Music, each merge,
    /// so a big library comes over through a few openings rather than all at once.
    private static let findsPerMerge = 30
    private static let addsPerMerge = 30

    init(music: YourMusic) {
        self.music = music
    }

    /// Merges if it's on and Apple Music is allowed, without asking for it.
    func mergeIfOn() async {
        guard Self.isOn, MusicAuthorization.currentStatus == .authorized else { return }
        await merge()
    }

    /// Turns merging on: asks for Apple Music if it hasn't been, then merges. Returns whether
    /// it could be turned on.
    func turnOn() async -> Bool {
        var status = MusicAuthorization.currentStatus
        if status == .notDetermined { status = await MusicAuthorization.request() }
        guard status == .authorized else {
            problem = String(localized: "Tracks isn't allowed to use Apple Music. Allow it in Settings › Apps › Tracks.")
            return false
        }
        UserDefaults.standard.set(true, forKey: Self.storageKey)
        await merge()
        return true
    }

    func turnOff() {
        UserDefaults.standard.set(false, forKey: Self.storageKey)
        problem = nil
        leftToFind = 0
    }

    func merge() async {
        guard let music, !isMerging else { return }
        isMerging = true
        defer { isMerging = false }
        do {
            let apple = try await libraryPlaylists()
            var finds = Self.findsPerMerge
            var adds = Self.addsPerMerge
            var left = 0
            for (id, playlist) in try await pair(apple, in: music) {
                left += try await merge(id, with: playlist, in: music, finds: &finds, adds: &adds)
            }
            leftToFind = left
            lastMerged = .now
            problem = nil
        } catch {
            problem = String(localized: "Couldn't reach Apple Music. Tracks tries again next time it opens.")
        }
    }

    // MARK: - Pairing

    /// Each Tracks playlist you fill yourself with its Apple Music playlist: the one it's merged
    /// with, one of the same name, or a new one; and each Apple Music playlist left, with a new
    /// Tracks one. Ones unmerged, or deleted on one side, are left out.
    private func pair(_ apple: [Playlist], in music: YourMusic) async throws -> [(UUID, Playlist)] {
        let playlists = music.playlists
        let byID = Dictionary(apple.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
        var paired: [(UUID, Playlist)] = []
        var taken = Set<String>()

        for playlist in playlists.fillable where !playlists.unmerged.contains(playlist.id.uuidString) {
            if let link = playlist.appleMusic {
                if let found = byID[link.playlistID] {
                    paired.append((playlist.id, found))
                    taken.insert(link.playlistID)
                } else {
                    // Deleted in Apple Music: it stays here, merged no more.
                    playlists.unmerge([playlist.id.uuidString])
                    playlists.update(playlist.id, touches: false) { $0.appleMusic = nil }
                }
                continue
            }
            let name = StatsCalculator.folded(playlist.name)
            let found = apple.first {
                !taken.contains($0.id.rawValue) && !playlists.unmerged.contains($0.id.rawValue) && StatsCalculator.folded($0.name) == name
            }
            let partner: Playlist
            if let found {
                partner = found
            } else {
                guard let created = try await Self.createPlaylist(named: playlist.name) else { continue }
                partner = created
            }
            link(playlist.id, to: partner, in: playlists)
            paired.append((playlist.id, partner))
            taken.insert(partner.id.rawValue)
        }

        for partner in apple where !taken.contains(partner.id.rawValue) && !playlists.unmerged.contains(partner.id.rawValue) {
            let made = playlists.create(name: partner.name)
            link(made.id, to: partner, in: playlists)
            paired.append((made.id, partner))
        }
        return paired
    }

    private func link(_ id: UUID, to partner: Playlist, in playlists: Playlists) {
        playlists.update(id, touches: false) {
            $0.appleMusic = TracksPlaylist.AppleMusicLink(playlistID: partner.id.rawValue, name: partner.name)
        }
    }

    /// Your own Apple Music playlists: not Apple's, not ones made for you, and not Heard on
    /// Radio, which Tracks fills from the radio.
    private func libraryPlaylists() async throws -> [Playlist] {
        var request = MusicLibraryRequest<Playlist>()
        request.limit = 100
        var batch = try await request.response().items
        var all = Array(batch)
        while batch.hasNextBatch, let next = try await batch.nextBatch() {
            all += next
            batch = next
        }
        let radio = CaptureSettings().playlistID
        return all.filter { playlist in
            guard playlist.id.rawValue != radio else { return false }
            switch playlist.kind {
            case .editorial, .external, .personalMix, .replay: return false
            default: return true
            }
        }
    }

    // MARK: - Merging one

    /// A song in an Apple Music playlist.
    private struct AppleSong {
        let identity: String
        let title: String
        let artist: String
        let album: String?
        let duration: TimeInterval?
    }

    /// Brings one pair together. Returns how many songs from Apple Music are still to be looked
    /// for, the merge's share of looking having run out.
    private func merge(_ id: UUID, with partner: Playlist, in music: YourMusic, finds: inout Int, adds: inout Int) async throws -> Int {
        let songs = try await tracks(of: partner).map { track in
            AppleSong(
                identity: HistoryImport.key(title: track.title, artistName: track.artistName),
                title: track.title,
                artist: track.artistName,
                album: track.albumTitle,
                duration: track.duration
            )
        }
        guard let playlist = music.playlists.playlist(id: id), var link = playlist.appleMusic else { return 0 }
        let inApple = Set(songs.map(\.identity))
        var ledger = AppleMusicMergeLedger(link: link, here: playlist.identities, inApple: inApple)

        // Taken out in Apple Music since the last merge: out of here too.
        let takenOut = ledger.takeOut(keeping: inApple)
        if !takenOut.isEmpty {
            music.playlists.update(id) { $0.entries.removeAll { takenOut.contains($0.track.identity) } }
        }

        // Added in Apple Music since: found in your music or on your server. One seen before
        // and not here was taken out here, and stays out.
        var here = music.playlists.playlist(id: id)?.identities ?? []
        var found: [LocalTrack] = []
        var left = 0
        for song in songs where ledger.isNew(apple: song.identity, here: here) {
            switch await find(song, in: music, finds: &finds) {
            case .found(let track):
                found.append(track)
                here.insert(song.identity)
                ledger.found(apple: song.identity, here: track.identity)
            case .notFound:
                ledger.missing(apple: song.identity)
            case .later:
                left += 1
            }
        }
        if !found.isEmpty { music.playlists.add(found, to: id) }

        // Added here since: added in Apple Music too.
        let current = music.playlists.playlist(id: id)?.entries ?? []
        for entry in current {
            let identity = entry.track.identity
            guard ledger.needsAdding(here: identity, inApple: inApple) else { continue }
            guard adds > 0 else { break }
            adds -= 1
            do {
                if let added = try await add(entry.track, to: partner) {
                    ledger.added(here: identity, apple: added)
                } else {
                    ledger.notInCatalog(here: identity)
                }
            } catch {
                // Not reached this time, so it's tried again next merge.
            }
        }
        ledger.settle(here: Set(current.map(\.track.identity)), inApple: inApple)

        link = ledger.written(to: link)
        link.name = partner.name
        link.mergedAt = .now
        music.playlists.update(id, touches: false) { $0.appleMusic = link }

        // Its songs to hear with no connection, as a playlist kept in Apple Music would be.
        let playlistSongs = (music.playlists.playlist(id: id)?.entries ?? []).map { music.current($0.track) }
        let toDownload = playlistSongs.filter {
            $0.isFromServer && music.isInYourMusic($0) && !music.downloads.isDownloaded($0.id) && !music.downloads.isDownloading($0.id)
        }
        music.downloads.download(toDownload)
        return left
    }

    private func tracks(of playlist: Playlist) async throws -> [Track] {
        guard var batch = try await playlist.with([.tracks]).tracks else { return [] }
        var all = Array(batch)
        while batch.hasNextBatch, let next = try await batch.nextBatch() {
            all += next
            batch = next
        }
        return all
    }

    private enum Finding {
        case found(LocalTrack)
        /// A server was asked and didn't have it.
        case notFound
        /// Not looked for this time: no server to ask, or the merge's share used up.
        case later
    }

    /// A song from Apple Music in your music, or on a server: one a server found for you is
    /// kept there, which a server like Octo takes as "get me this", and downloaded once it's in.
    private func find(_ song: AppleSong, in music: YourMusic, finds: inout Int) async -> Finding {
        let yours = music.index.tracks(withIdentity: song.identity)
        if let track = yours.first(where: music.isPlayable) ?? yours.first { return .found(track) }
        let servers = music.servers.onlineServers
        guard !servers.isEmpty, finds > 0 else { return .later }
        finds -= 1
        var asked = false
        for server in servers {
            guard (try? await budget.wait()) != nil,
                  let answer = await music.serverSongs(on: server.id, matching: "\(song.title) \(song.artist)")
            else { continue }
            asked = true
            guard let match = ServerSongMatcher.bestMatch(title: song.title, artist: song.artist, in: answer) else { continue }
            let track = music.resolved(match.track(on: server.id))
            music.remember(found: [track])
            if !music.isInYourMusic(track) { music.keepAndDownload(track) }
            return .found(track)
        }
        return asked ? .notFound : .later
    }

    /// Adds a song to an Apple Music playlist, found in Apple Music's catalog by its name.
    /// Returns the song's identity as Apple Music has it.
    private func add(_ track: LocalTrack, to partner: Playlist) async throws -> String? {
        let query = CatalogQuery(title: track.title, artistName: track.artist, duration: track.duration, albumTitle: track.album)
        guard let candidate = try await CatalogLookup().resolve(query) else { return nil }
        let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(candidate.id))
        guard let song = try await request.response().items.first else { return nil }
        #if os(iOS)
        _ = try await MusicLibrary.shared.add(song, to: partner)
        #else
        try await MusicKitPlaylistWriter().addSongs(ids: [song.id.rawValue], toPlaylist: partner.id.rawValue)
        #endif
        return HistoryImport.key(title: candidate.title, artistName: candidate.artistName)
    }

    /// A new Apple Music playlist to merge with. MusicKit makes it on iPhone; on the Mac, which
    /// can't, Apple Music is asked directly and the playlist read back from the library. Nil
    /// while the library hasn't caught up with it yet: the next merge pairs the two by name.
    private static func createPlaylist(named name: String) async throws -> Playlist? {
        let description = String(localized: "Merged with Tracks")
        #if os(iOS)
        return try await MusicLibrary.shared.createPlaylist(name: name, description: description)
        #else
        let id = try await MusicKitPlaylistWriter().createPlaylist(name: name, description: description)
        var request = MusicLibraryRequest<Playlist>()
        request.filter(matching: \.id, equalTo: MusicItemID(id))
        return try await request.response().items.first
        #endif
    }
}
