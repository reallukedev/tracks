import CoreSpotlight
import Foundation
import TracksCore

/// Puts your most played artists, albums and songs in Spotlight, so searching the phone or
/// the Mac for one finds its page in Tracks. The index stays on this device.
@MainActor
enum HistorySpotlight {
    /// Enough to cover what someone would search for, few enough to index in a moment.
    static let artistLimit = 200
    static let albumLimit = 200
    static let songLimit = 500

    private static let indexedAtKey = "spotlightIndexedAt"
    /// New favourites take a while to become favourites, so a few times a day is plenty.
    private static let interval: TimeInterval = 6 * 60 * 60

    /// Indexes once the history has loaded, and again every few hours for as long as Tracks
    /// stays open (the Mac app can run for weeks). Never per song: one pass replaces the lot,
    /// so its cost doesn't depend on how much is played between passes. Waits a little
    /// first, so it doesn't compete with launch.
    static func indexWhenDue(defaults: UserDefaults = .standard) {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        // Lives as long as the process, like the app model that starts it.
        Task(priority: .utility) {
            try? await Task.sleep(for: .seconds(20))
            while true {
                let last = Date(timeIntervalSince1970: defaults.double(forKey: indexedAtKey))
                let wait = interval - Date.now.timeIntervalSince(last)
                if wait > 0 {
                    try? await Task.sleep(for: .seconds(wait + 1))
                    continue
                }
                await index(defaults: defaults)
                // A failed pass waits the full interval rather than retrying in a loop.
                defaults.set(Date.now.timeIntervalSince1970, forKey: indexedAtKey)
            }
        }
    }

    /// One pass: the history's search index is built off the main actor and let go a minute
    /// later (`HistoryCatalog`), so nothing big is kept between passes.
    private static func index(defaults: UserDefaults) async {
        guard let index = await HistoryCatalog.index() else { return }
        let artists = index.topArtists(limit: artistLimit).map(ListenedArtistEntity.init)
        let albums = index.topAlbums(limit: albumLimit).map(ListenedAlbumEntity.init)
        let songs = index.topSongs(limit: songLimit).map(ListenedSongEntity.init)
        let spotlight = CSSearchableIndex.default()
        // Replaced whole, so songs forgotten or merged since don't linger. A failure is
        // tried again at the next pass.
        try? await spotlight.deleteAppEntities(ofType: ListenedArtistEntity.self)
        try? await spotlight.deleteAppEntities(ofType: ListenedAlbumEntity.self)
        try? await spotlight.deleteAppEntities(ofType: ListenedSongEntity.self)
        try? await spotlight.indexAppEntities(artists, priority: 3)
        try? await spotlight.indexAppEntities(albums, priority: 2)
        try? await spotlight.indexAppEntities(songs, priority: 1)
    }
}
