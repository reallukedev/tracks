import Foundation
import Synchronization

/// What Apple Music has said about who's on each song, by song identity, for crediting a song
/// outside the statistics: a menu's Go to Artist, a row's links. The statistics take the
/// same lists from ``ListeningHistory/songMetadata``; this keeps the rest of the app in step
/// with them without passing the history to every menu.
public final class CatalogCredits: Sendable {
    public static let shared = CatalogCredits()

    private let artists = Mutex<[String: [String]]>([:])

    public init() {}

    /// The names Apple Music gave for the song's artists, if it's been asked.
    public func artists(forSong identity: String) -> [String]? {
        artists.withLock { $0[identity] }
    }

    /// Takes the lists from every song looked up so far, replacing what was there.
    public func update(from metadata: [String: SongMetadata]) {
        var known: [String: [String]] = [:]
        for (identity, song) in metadata {
            if let names = song.artists, !names.isEmpty { known[identity] = names }
        }
        artists.withLock { $0 = known }
    }
}
