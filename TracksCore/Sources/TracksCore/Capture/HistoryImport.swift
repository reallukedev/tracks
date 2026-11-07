import Foundation

/// One song from Apple's recently-played list.
public struct PlayedSong: Sendable, Equatable {
    public let songID: String
    public let title: String
    public let artistName: String
    public let albumTitle: String?
    public let artworkURL: String?

    public init(
        songID: String,
        title: String,
        artistName: String,
        albumTitle: String? = nil,
        artworkURL: String? = nil
    ) {
        self.songID = songID
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.artworkURL = artworkURL
    }
}

/// Reads Apple's recently-played list.
public protocol PlayedSongSource: Sendable {
    func recentlyPlayed(limit: Int) async throws -> [PlayedSong]
}

/// Fills in songs played while Tracks wasn't running.
///
/// iOS suspends a backgrounded app within about thirty seconds, so Tracks misses most
/// listening there. Imported rows are `.imported`: Apple's list doesn't say whether a song
/// was radio or on demand. It has no timestamps either, only newest-first order, so imports
/// are dated when found and must never overwrite a witnessed capture.
public enum HistoryImport {

    /// Identity for an imported song: normalised title and artist.
    ///
    /// Not the catalog ID. Apple's list can return the same song under both a catalog and a
    /// library ID, and a macOS capture's searched ID may differ from the one in the list.
    /// Both caused duplicate imports.
    public static func key(title: String, artistName: String) -> String {
        let normalise = { (value: String) in
            value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        return "\(normalise(title))\u{1F}\(normalise(artistName))"
    }

    /// How many songs at the top of Apple's list weren't there last time.
    ///
    /// Finds the longest tail of `current` that appears in `previous` in the same order; the
    /// songs above it are new plays (including a song played again, which jumps to the top).
    /// Both lists are newest first.
    public static func unseenCount(in current: [String], previous: [String]) -> Int {
        var j = previous.count - 1
        var boundary = current.count
        for i in current.indices.reversed() {
            while j >= 0, previous[j] != current[i] { j -= 1 }
            guard j >= 0 else { break }
            boundary = i
            j -= 1
        }
        return boundary
    }

    /// Which of Apple's recently-played songs are worth writing down.
    ///
    /// - Parameters:
    ///   - played: newest first, as Apple returns them.
    ///   - known: ``key(title:artistName:)`` values Tracks already has from this period.
    /// - Returns: the ones not already known, oldest first, so they insert in listening order.
    public static func newSongs(
        in played: [PlayedSong],
        known: Set<String>
    ) -> [PlayedSong] {
        var seen = known
        var result: [PlayedSong] = []
        for song in played where !song.songID.isEmpty {
            // Also collapses the same song listed twice under different IDs.
            let identity = key(title: song.title, artistName: song.artistName)
            guard seen.insert(identity).inserted else { continue }
            result.append(song)
        }
        return result.reversed()
    }
}
