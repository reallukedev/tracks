import Foundation

/// The `userInfo` keys Music.app actually posts on macOS 27.
///
/// Found by disassembling `/System/Applications/Music.app` on macOS 27 (Music 1.7.0): these
/// sixteen strings sit together in the notification-posting function. `Store URL`,
/// `Album Artist`, `Location`, `Rating`, `Play Count` and `Track ID` belong to the iTunes
/// Library XML exporter and are never posted, so there's no catalog ID to read.
public enum PlayerInfoKey {
    public static let playerState = "Player State"
    public static let name = "Name"
    public static let artist = "Artist"
    public static let album = "Album"
    public static let genre = "Genre"
    public static let composer = "Composer"
    public static let grouping = "Grouping"
    public static let description = "Description"
    public static let year = "Year"
    public static let trackNumber = "Track Number"
    public static let trackCount = "Track Count"
    public static let discNumber = "Disc Number"
    public static let discCount = "Disc Count"
    /// Milliseconds.
    public static let totalTime = "Total Time"
    public static let persistentID = "PersistentID"
    public static let libraryPersistentID = "Library PersistentID"

    public static let all: [String] = [
        playerState, name, artist, album, genre, composer, grouping, description,
        year, trackNumber, trackCount, discNumber, discCount, totalTime,
        persistentID, libraryPersistentID,
    ]
}

/// Distributed notification names Music.app posts.
///
/// Music posts every event twice, once under each name, with identical `userInfo`.
/// Observe only one, or every track is captured twice.
public enum MusicNotificationName {
    public static let preferred = "com.apple.Music.playerInfo"
    /// The legacy alias. Don't observe it as well.
    public static let legacyDuplicate = "com.apple.iTunes.playerInfo"
}
