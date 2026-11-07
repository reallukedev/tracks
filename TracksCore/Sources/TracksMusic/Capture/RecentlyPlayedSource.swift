import Foundation
import MusicKit
import TracksCore

/// Apple's recently played list, as songs Tracks can record.
///
/// The only way to recover listening from while the app wasn't running. On iOS that's most
/// of it: a backgrounded app is suspended within about 30 seconds, and no background mode
/// covers watching the music player.
public struct RecentlyPlayedSource: PlayedSongSource {
    public init() {}

    public func recentlyPlayed(limit: Int = 30) async throws -> [PlayedSong] {
        var request = MusicRecentlyPlayedRequest<Song>()
        request.limit = limit
        return try await request.response().items.map { song in
            PlayedSong(
                songID: song.id.rawValue,
                title: song.title,
                artistName: song.artistName,
                albumTitle: song.albumTitle,
                // MusicKit returns a private scheme for some items, which never loads.
                // See `ArtworkURL`.
                artworkURL: ArtworkURL.loadable(song.artwork?.url(width: 300, height: 300)?.absoluteString)
            )
        }
    }
}
