import Foundation

/// The two halves of a `MusicPlayer.Queue.Entry.id`.
///
/// On iOS 27 (see `docs/PlatformNotes.md`), entry IDs look like `<queue>::<item>`:
///
/// ```
/// Jzb4lWyve::STREAM        Apple Music Chill
/// PxDIf4ejk::STREAM        Apple Music 1
/// o6C8OJs7I::STREAM        a personal artist station
/// PRhKeIIy0::6ostOUDHU     an album, first track
/// PRhKeIIy0::EHYCyckzc     the same album, second track
/// ```
///
/// The item half is `STREAM` for radio, which is how iOS detects radio. The queue half stays
/// the same across a station's tracks and changes with the station, which marks a session
/// boundary. The format is undocumented; the tests use the real IDs above.
public struct QueueEntryIdentifier: Sendable, Equatable, Hashable {
    /// Identifies the station or album the entry belongs to.
    public let queueID: String
    /// `STREAM` for radio; an opaque per-track identifier for on-demand playback.
    public let itemID: String

    /// The marker that distinguishes a station from an on-demand queue.
    public static let streamMarker = "STREAM"

    public init?(_ raw: String) {
        let parts = raw.components(separatedBy: "::")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        queueID = parts[0]
        itemID = parts[1]
    }

    /// Whether this entry came from a radio station.
    public var isStream: Bool { itemID == Self.streamMarker }
}
