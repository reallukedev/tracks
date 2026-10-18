import Foundation

/// The words for Settings ▸ Radio: where radio songs go.
public enum RadioSettingsWords {
    /// What the radio playlist settings add up to.
    public struct Playlist: Sendable, Equatable {
        public var addsSongs: Bool
        public var name: String

        /// `name` as stored: blank reads as the default, as ``CaptureSettings/playlistName``
        /// does.
        public init(addsSongs: Bool, name: String) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            self.addsSongs = addsSongs
            self.name = trimmed.isEmpty ? CaptureSettings.defaultPlaylistName : trimmed
        }
    }

    /// The status line.
    public static func status(_ playlist: Playlist) -> String {
        guard playlist.addsSongs else {
            return String(localized: "Radio songs are kept in your history. Tracks can also add them to a playlist in Apple Music.")
        }
        return String(localized: "Adding radio songs to \(quoted(playlist.name))")
    }

    /// The root row's value: the playlist, or nothing when songs stay in history only.
    public static func short(_ playlist: Playlist) -> String? {
        playlist.addsSongs ? playlist.name : nil
    }

    /// Curly quotes, so a name reads as a name inside a sentence.
    static func quoted(_ name: String) -> String {
        "\u{201C}\(name)\u{201D}"
    }
}
