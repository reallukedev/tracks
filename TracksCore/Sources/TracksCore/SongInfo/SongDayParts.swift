import Foundation

/// A song's plays in one part of the day.
public struct DayPartPlays: Sendable, Equatable, Identifiable {
    public let part: DayPart
    public let plays: Int

    public var id: DayPart { part }

    public init(part: DayPart, plays: Int) {
        self.part = part
        self.plays = plays
    }
}

public enum SongDayParts {
    /// When in the day these plays fell, every part from morning to night. Nil until there are
    /// as many plays as Now Playing wants before it names a usual time: a pattern of two
    /// plays isn't one.
    public static func split(_ plays: [Date], calendar: Calendar = .current) -> [DayPartPlays]? {
        guard plays.count >= SongStories.usualMinimumPlays else { return nil }
        var counts: [DayPart: Int] = [:]
        for date in plays {
            counts[DayPart(hour: calendar.component(.hour, from: date)), default: 0] += 1
        }
        return DayPart.allCases.map { DayPartPlays(part: $0, plays: counts[$0] ?? 0) }
    }
}
