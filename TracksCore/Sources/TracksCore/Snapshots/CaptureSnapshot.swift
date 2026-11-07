import Foundation

/// An immutable, `Sendable` view of a ``Capture``.
///
/// SwiftData models aren't `Sendable`, so widgets, the menu bar, the Live Activity and the
/// probe get snapshots and re-fetch the model only when they need to write.
public struct CaptureSnapshot: Sendable, Identifiable, Hashable {
    public let id: String
    public let songID: String
    public let title: String
    public let artistName: String
    public let albumTitle: String?
    public let artworkURL: String?
    public let kind: CaptureKind
    public let capturedAt: Date
    public let isInPlaylist: Bool
    public let playedBackAt: Date?

    public init(
        id: String,
        songID: String,
        title: String,
        artistName: String,
        albumTitle: String? = nil,
        artworkURL: String? = nil,
        kind: CaptureKind,
        capturedAt: Date,
        isInPlaylist: Bool = false,
        playedBackAt: Date? = nil
    ) {
        self.id = id
        self.songID = songID
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.artworkURL = artworkURL
        self.kind = kind
        self.capturedAt = capturedAt
        self.isInPlaylist = isInPlaylist
        self.playedBackAt = playedBackAt
    }
}

public extension Capture {
    var snapshot: CaptureSnapshot {
        CaptureSnapshot(
            id: "\(persistentModelID.hashValue)",
            songID: songID,
            title: title,
            artistName: artistName,
            albumTitle: albumTitle,
            artworkURL: artworkURL,
            kind: kind,
            capturedAt: capturedAt,
            isInPlaylist: addedToPlaylistAt != nil,
            playedBackAt: playedBackAt
        )
    }
}
