import Foundation
import MediaPlayer
import MusicKit
import Observation
import TracksCore

/// Offline Mode: Play shows only songs downloaded to this iPhone, which play without a
/// connection. On when turned on in Settings, and by itself whenever there's no connection.
enum OfflineMode {
    static let storageKey = "playOfflineMode"
}

/// A song from the Apple Music library that's downloaded to this iPhone.
struct OfflineSong: Identifiable, Hashable {
    let id: String
    let title: String
    let artistName: String
    let albumTitle: String?
    let cover: CoverArt
    let isExplicit: Bool
    /// When it was added to the library, for Recently Added.
    let dateAdded: Date
    /// The library song, to play. Nil with sample data, which plays by name.
    let song: Song?

    /// The key Tracks’ history groups plays by.
    var identity: String { HistoryImport.key(title: title, artistName: artistName) }
}

extension Array where Element == OfflineSong {
    /// These songs for the player: library songs, or with sample data, songs by name.
    func request(startingAt start: Int = 0) -> PlayRequest {
        let songs = compactMap(\.song)
        if !isEmpty, songs.count == count { return .songs(songs, startingAt: start) }
        let history = map { HistorySong(songID: $0.id, title: $0.title, artistName: $0.artistName, albumTitle: $0.albumTitle) }
        return .history(history, startingAt: start)
    }
}

/// The songs in the Apple Music library that are downloaded to this iPhone.
///
/// Apple doesn't let other apps download Apple Music songs, but Music does, and once a song
/// is on this iPhone Tracks’ player plays it without a connection. With Automatic Downloads
/// on in Settings › Apps › Music, songs added to the library from Tracks download too.
@MainActor
@Observable
final class DownloadedSongs {
    /// Newest to the library first.
    private(set) var songs: [OfflineSong] = []
    private(set) var hasLoaded = false
    private(set) var isLoading = false

    @ObservationIgnored private let isDemo: Bool
    /// With sample data: songs from the sample history stand in for downloads.
    @ObservationIgnored private let demoSongs: () -> [MixSong]
    @ObservationIgnored private var libraryObserver: NSObjectProtocol?
    @ObservationIgnored private var reload: Task<Void, Never>?

    init(isDemo: Bool, demoSongs: @escaping () -> [MixSong]) {
        self.isDemo = isDemo
        self.demoSongs = demoSongs
    }

    /// Downloaded songs by the key the history groups plays by.
    var byIdentity: [String: OfflineSong] {
        Dictionary(songs.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Loads once, and again whenever the library changes: a download finishing, or one
    /// removed in Music.
    func loadIfNeeded() async {
        startWatching()
        // Sample data's stand-ins come from the sample mixes, which may not be built yet.
        guard !hasLoaded || isDemo && songs.isEmpty, !isLoading else { return }
        await load()
    }

    func load() async {
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        #if DEBUG
        if isDemo {
            songs = demoDownloads()
            return
        }
        #endif
        guard !isDemo, MusicAuthorization.currentStatus == .authorized else {
            songs = []
            return
        }
        let onDevice = await Self.onDevice()
        guard !onDevice.isEmpty else {
            songs = []
            return
        }
        let found = await Self.librarySongs(for: onDevice)
        songs = onDevice.compactMap { item in
            guard let song = found.byID[item.id] ?? found.byKey[item.key] else { return nil }
            return OfflineSong(
                id: song.id.rawValue,
                title: song.title,
                artistName: song.artistName,
                albumTitle: song.albumTitle,
                cover: song.artwork.map(CoverArt.artwork) ?? .url(nil, seed: song.albumTitle ?? song.title),
                isExplicit: song.isExplicit,
                dateAdded: item.dateAdded,
                song: song
            )
        }
    }

    private func startWatching() {
        guard libraryObserver == nil, !isDemo else { return }
        MPMediaLibrary.default().beginGeneratingLibraryChangeNotifications()
        libraryObserver = NotificationCenter.default.addObserver(forName: .MPMediaLibraryDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Changes come in bursts while songs download: look once they settle.
                self?.reload?.cancel()
                self?.reload = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    await self?.load()
                }
            }
        }
    }

    // MARK: - Finding them

    /// A song on this iPhone, as the media library knows it.
    private struct OnDevice: Sendable {
        /// The library song's id: MusicKit's library ids are the media library's persistent ids.
        let id: MusicItemID
        /// Title and artist, for finding it by name if the id doesn't match.
        let key: String
        let dateAdded: Date
    }

    /// Every song in the library stored on this iPhone, newest to the library first. The media
    /// library is the only place that says which songs are downloaded.
    @concurrent
    private nonisolated static func onDevice() async -> [OnDevice] {
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(MPMediaPropertyPredicate(value: false, forProperty: MPMediaItemPropertyIsCloudItem))
        return (query.items ?? [])
            .map { item in
                OnDevice(
                    id: MusicItemID(String(item.persistentID)),
                    key: HistoryImport.key(title: item.title ?? "", artistName: item.artist ?? ""),
                    dateAdded: item.dateAdded
                )
            }
            .sorted { $0.dateAdded > $1.dateAdded }
    }

    /// The library songs for those on this iPhone, by id and by title and artist. By id first,
    /// a few hundred at a time; any left over are found by name in the whole library.
    private static func librarySongs(for items: [OnDevice]) async -> (byID: [MusicItemID: Song], byKey: [String: Song]) {
        var byID: [MusicItemID: Song] = [:]
        var byKey: [String: Song] = [:]
        var foundKeys = Set<String>()
        let ids = items.map(\.id)
        for start in stride(from: 0, to: ids.count, by: 300) {
            let chunk = Array(ids[start..<min(start + 300, ids.count)])
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.id, memberOf: chunk)
            request.limit = chunk.count
            guard let response = try? await request.response() else { continue }
            for song in response.items {
                byID[song.id] = song
                foundKeys.insert(HistoryImport.key(title: song.title, artistName: song.artistName))
            }
        }

        let missing = Set(items.filter { byID[$0.id] == nil && !foundKeys.contains($0.key) }.map(\.key))
        guard !missing.isEmpty else { return (byID, byKey) }
        var request = MusicLibraryRequest<Song>()
        request.limit = 500
        var batch = try? await request.response().items
        var remaining = missing
        while let current = batch, !remaining.isEmpty {
            for song in current {
                let key = HistoryImport.key(title: song.title, artistName: song.artistName)
                if remaining.remove(key) != nil { byKey[key] = song }
            }
            batch = current.hasNextBatch ? try? await current.nextBatch() : nil
        }
        return (byID, byKey)
    }

    // MARK: - Sample data

    #if DEBUG
    /// With sample data, the sample history's songs stand in for downloads.
    private func demoDownloads() -> [OfflineSong] {
        var seen = Set<String>()
        return demoSongs()
            .filter { seen.insert($0.songIdentity).inserted }
            .prefix(80)
            .map { song in
                OfflineSong(
                    id: song.songID.isEmpty ? song.songIdentity : song.songID,
                    title: song.title,
                    artistName: song.artistName,
                    albumTitle: song.albumTitle,
                    cover: .url(song.artworkURL, seed: song.albumTitle ?? song.title),
                    isExplicit: false,
                    dateAdded: song.lastHeard,
                    song: nil
                )
            }
            .sorted { $0.dateAdded > $1.dateAdded }
    }
    #endif
}
