import Foundation

/// Songs Tracks’ own player started and moved on from before they counted: skipped, or left
/// before ``CaptureSettings/minimumListenShare`` of them had played.
///
/// Apple's recently-played list has them anyway, since Apple counts a song as played the
/// moment it starts. Without this, the next import of that list brings every skip back as a
/// play, scrobbles it, and the suggestions drop it as already heard. The list is shared
/// between devices, as a skip on the Mac shows up in the iPhone's recently-played list too.
///
/// Stored as strings that sort oldest first, `"<seconds since 1970>␞<song key>"`, so two
/// devices' copies join with a plain union and the oldest are trimmed the same way on both.
public struct PassedOverSongs: Sendable, Equatable {
    /// The stored form, oldest first.
    public private(set) var entries: [String]

    /// How long a pass counts against an import: longer than the import's own look back, so
    /// a device that's been away a day still knows.
    public static let memory: TimeInterval = 48 * 60 * 60
    /// The most kept, so a long session of skipping can't fill the iCloud key.
    public static let limit = 400

    private static let separator: Character = "\u{1E}"

    public init(_ entries: [String] = []) {
        self.entries = entries.sorted()
    }

    /// Notes that a song was passed over, and forgets the ones passed over too long ago.
    public mutating func note(_ songKey: String, at date: Date = .now) {
        entries.append(Self.entry(songKey, at: date))
        entries.sort()
        trim(now: date)
    }

    /// The songs passed over since `date`, as ``HistoryImport/key(title:artistName:)`` values.
    public func keys(since date: Date) -> Set<String> {
        Set(entries.compactMap { entry in
            guard let (at, key) = Self.parse(entry), at >= date else { return nil }
            return key
        })
    }

    /// Forgets the passes older than ``memory`` and keeps the newest ``limit``. Also run on
    /// the joined lists from two devices, which each trim only their own.
    mutating func trim(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.memory)
        entries.removeAll { Self.parse($0).map { $0.at < cutoff } ?? true }
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    /// Whole seconds, padded so the entries sort by time as strings.
    static func entry(_ songKey: String, at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince1970))
        return String(format: "%011d", seconds) + String(separator) + songKey
    }

    static func parse(_ entry: String) -> (at: Date, key: String)? {
        guard let split = entry.firstIndex(of: separator),
              let seconds = Int(entry[..<split])
        else { return nil }
        return (Date(timeIntervalSince1970: TimeInterval(seconds)), String(entry[entry.index(after: split)...]))
    }
}
