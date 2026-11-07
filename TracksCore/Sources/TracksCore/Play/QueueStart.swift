import Foundation

/// Where a queue must be to start on the song someone tapped.
///
/// A queue made from a list with a song to start on can still be on the list's first song
/// once it's ready: the player only moves to the one asked for as it plays, so the first
/// seconds of the wrong song are heard. The player checks where it is before playing and,
/// if it's somewhere else, moves there first.
public enum QueueStart {
    /// The entry to move to before playing, or nil when the queue is already on the song, or
    /// where the song is can't be told.
    ///
    /// - Parameters:
    ///   - wantedID: the song asked for.
    ///   - wantedIndex: where it is in the list the queue was made from.
    ///   - listCount: how many songs that list has.
    ///   - entryIDs: the queue's songs as the player has them, in order; nil for one it
    ///     hasn't worked out yet.
    ///   - current: where the player is in them, if anywhere.
    public static func correction(
        wantedID: String,
        wantedIndex: Int,
        listCount: Int,
        entryIDs: [String?],
        current: Int?
    ) -> Int? {
        let target: Int? = if entryIDs.indices.contains(wantedIndex), entryIDs[wantedIndex] == wantedID {
            wantedIndex
        } else if let found = entryIDs.firstIndex(of: wantedID) {
            found
        } else if entryIDs.count == listCount, entryIDs.indices.contains(wantedIndex) {
            // The songs aren't known by the ids they were queued with, but the queue is the
            // list as it was made, so the song is where it was put.
            wantedIndex
        } else {
            nil
        }
        guard let target, target != current else { return nil }
        return target
    }
}
