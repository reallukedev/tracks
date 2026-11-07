import Foundation

/// What's audible right now.
///
/// Not a ``CaptureSnapshot``: a song is playing from its first second but only becomes a
/// capture after the minimum listening time, and the menu bar shows what's on.
public struct NowPlaying: Sendable, Equatable {
    public let title: String
    public let artistName: String
    public let albumTitle: String?
    public let artworkURL: String?

    public init(title: String, artistName: String, albumTitle: String? = nil, artworkURL: String? = nil) {
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.artworkURL = artworkURL
    }
}
