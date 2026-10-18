import Foundation

/// The drives Tracks has noticed, so Tracks Radio knows the songs you play on the road: any play
/// inside a drive was heard driving, whichever app played it.
///
/// Kept on this device only, a few months of drives, oldest first and never overlapping.
public struct DriveLog: Codable, Sendable, Equatable {
    public private(set) var drives: [DateInterval] = []

    /// How long a drive is remembered.
    public static let memory: TimeInterval = 120 * 24 * 60 * 60
    /// Drives kept at most, so the file can't grow without end.
    public static let limit = 400
    /// A drive shorter than this was likely a bus stop or a lift, not a drive.
    public static let shortest: TimeInterval = 3 * 60
    /// Two drives this close together are one, with a stop for fuel in it.
    public static let joiningGap: TimeInterval = 5 * 60

    public init(drives: [DateInterval] = []) {
        let now = drives.map(\.end).max() ?? .distantPast
        for drive in drives { record(drive, now: now) }
    }

    /// Adds a drive, joining it to any it overlaps or nearly meets, and forgets the old ones.
    public mutating func record(_ drive: DateInterval, now: Date) {
        guard drive.duration >= Self.shortest else { return }
        var start = drive.start
        var end = drive.end
        var kept: [DateInterval] = []
        for other in drives {
            if other.end.addingTimeInterval(Self.joiningGap) >= start && other.start <= end.addingTimeInterval(Self.joiningGap) {
                start = min(start, other.start)
                end = max(end, other.end)
            } else {
                kept.append(other)
            }
        }
        kept.append(DateInterval(start: start, end: end))
        let forgotten = now.addingTimeInterval(-Self.memory)
        drives = Array(kept.filter { $0.end >= forgotten }.sorted { $0.start < $1.start }.suffix(Self.limit))
    }

    /// Whether a moment falls inside a drive.
    public func contains(_ date: Date) -> Bool {
        // The last drive starting at or before the date is the only one that can hold it.
        var low = 0
        var high = drives.count
        while low < high {
            let middle = (low + high) / 2
            if drives[middle].start <= date { low = middle + 1 } else { high = middle }
        }
        return low > 0 && drives[low - 1].end >= date
    }

    public var isEmpty: Bool { drives.isEmpty }

    // MARK: - Storage

    /// As JSON, for a defaults key.
    public var stored: Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    /// Anything unreadable is an empty log.
    public init(stored: Data?) {
        self = stored.flatMap { try? JSONDecoder().decode(DriveLog.self, from: $0) } ?? DriveLog()
    }
}
