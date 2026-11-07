import Foundation

/// How long a song in the player is, for its scrubber and the time left.
///
/// Only a live broadcast has no length: Apple Music 1 or an internet radio stream. A station
/// of on-demand songs (an artist's or a song's station, Tracks Radio, a mood) plays songs
/// that each have one, and can be scrubbed like any other.
public enum SongLength {
    /// The song's length, or nil when it has none to show and the player says LIVE instead.
    /// - Parameters:
    ///   - duration: what the song itself reports, nil for an entry that isn't a song.
    ///   - isLiveBroadcast: whether it's heard on a live station, where the song's own
    ///     length says nothing about what's left.
    public static func shown(_ duration: TimeInterval?, isLiveBroadcast: Bool) -> TimeInterval? {
        guard !isLiveBroadcast, let duration, duration > 0, duration.isFinite else { return nil }
        return duration
    }
}
