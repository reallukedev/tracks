import Foundation

/// A stretch of listening with no gap between songs longer than
/// `ListeningEstimate.longestPlausibleGap`.
public struct ListeningSession: Sendable, Equatable {
    public let start: Date
    public let seconds: TimeInterval
    public let songCount: Int

    public init(start: Date, seconds: TimeInterval, songCount: Int) {
        self.start = start
        self.seconds = seconds
        self.songCount = songCount
    }
}

/// Sessions in a range, found from the gaps between songs rather than from radio tune-ins,
/// so on-demand listening counts too.
public struct SessionStats: Sendable, Equatable {
    public let count: Int
    public let totalSeconds: TimeInterval
    public let totalSongs: Int
    public let longest: ListeningSession?
    /// Every length, empty ones included, shortest first.
    public let lengths: [SessionLengthCount]

    public init(
        count: Int,
        totalSeconds: TimeInterval,
        totalSongs: Int,
        longest: ListeningSession?,
        lengths: [SessionLengthCount]
    ) {
        self.count = count
        self.totalSeconds = totalSeconds
        self.totalSongs = totalSongs
        self.longest = longest
        self.lengths = lengths
    }

    public var averageSeconds: TimeInterval {
        count > 0 ? totalSeconds / Double(count) : 0
    }

    public var averageSongCount: Double {
        count > 0 ? Double(totalSongs) / Double(count) : 0
    }

    public static let none = SessionStats(count: 0, totalSeconds: 0, totalSongs: 0, longest: nil, lengths: [])
}

/// How long a session ran, in the steps a histogram needs.
public enum SessionLength: Int, Sendable, CaseIterable, Comparable {
    case underFifteenMinutes
    case underHalfHour
    case underHour
    case underTwoHours
    case twoHoursOrMore

    public init(seconds: TimeInterval) {
        self = Self.allCases.last { seconds >= $0.lowerBound } ?? .underFifteenMinutes
    }

    /// The shortest session in this step.
    public var lowerBound: TimeInterval {
        switch self {
        case .underFifteenMinutes: 0
        case .underHalfHour: 15 * 60
        case .underHour: 30 * 60
        case .underTwoHours: 60 * 60
        case .twoHoursOrMore: 120 * 60
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct SessionLengthCount: Sendable, Equatable, Identifiable {
    public let length: SessionLength
    public let count: Int

    public var id: SessionLength { length }

    public init(length: SessionLength, count: Int) {
        self.length = length
        self.count = count
    }
}

/// Four parts of the day. Night runs past midnight, so 2 AM belongs to the night before.
public enum DayPart: Int, Sendable, CaseIterable {
    case morning
    case afternoon
    case evening
    case night

    public init(hour: Int) {
        switch hour {
        case 5..<12: self = .morning
        case 12..<17: self = .afternoon
        case 17..<22: self = .evening
        default: self = .night
        }
    }

    public var startHour: Int {
        switch self {
        case .morning: 5
        case .afternoon: 12
        case .evening: 17
        case .night: 22
        }
    }

    /// Exclusive, and earlier than `startHour` for the night.
    public var endHour: Int {
        switch self {
        case .morning: 12
        case .afternoon: 17
        case .evening: 22
        case .night: 5
        }
    }
}

public struct DayPartCount: Sendable, Equatable, Identifiable {
    public let part: DayPart
    public let count: Int
    public let seconds: TimeInterval

    public var id: DayPart { part }

    public init(part: DayPart, count: Int, seconds: TimeInterval) {
        self.part = part
        self.count = count
        self.seconds = seconds
    }
}

/// Listening so far at one point in the range, beside the same point last period.
public struct PacePoint: Sendable, Equatable, Identifiable {
    /// The start of this point's day or month in the current range.
    public let start: Date
    /// Running total. `nil` for the part of the range still to come.
    public let current: TimeInterval?
    /// Last period's running total at the same point. `nil` with nothing to compare with.
    public let previous: TimeInterval?

    public var id: Date { start }

    public init(start: Date, current: TimeInterval?, previous: TimeInterval?) {
        self.start = start
        self.current = current
        self.previous = previous
    }
}

/// One day's listening, for the Records.
public struct DayRecord: Sendable, Equatable {
    public let day: Date
    public let seconds: TimeInterval
    public let songCount: Int
    public let artistCount: Int

    public init(day: Date, seconds: TimeInterval, songCount: Int, artistCount: Int) {
        self.day = day
        self.seconds = seconds
        self.songCount = songCount
        self.artistCount = artistCount
    }
}

/// The most times one song was played in a single day.
public struct RepeatRecord: Sendable, Equatable {
    /// The song's identity, as in `SongTally.id`.
    public let songID: String
    public let title: String
    public let artistName: String
    public let count: Int
    public let day: Date

    public init(songID: String, title: String, artistName: String, count: Int, day: Date) {
        self.songID = songID
        self.title = title
        self.artistName = artistName
        self.count = count
        self.day = day
    }
}

/// Bests inside the range. Each is `nil` when there's too little to call it a record.
public struct ListeningRecords: Sendable, Equatable {
    public let biggestDay: DayRecord?
    /// At least three artists, or it isn't a record worth showing.
    public let mostArtistsDay: DayRecord?
    /// At least two plays in a day.
    public let mostRepeated: RepeatRecord?
    public let longestSession: ListeningSession?
    /// Closest to dawn, counting the small hours as the night before.
    public let latestListen: Date?
    /// Earliest after 5 AM.
    public let earliestListen: Date?

    public init(
        biggestDay: DayRecord?,
        mostArtistsDay: DayRecord?,
        mostRepeated: RepeatRecord?,
        longestSession: ListeningSession?,
        latestListen: Date?,
        earliestListen: Date?
    ) {
        self.biggestDay = biggestDay
        self.mostArtistsDay = mostArtistsDay
        self.mostRepeated = mostRepeated
        self.longestSession = longestSession
        self.latestListen = latestListen
        self.earliestListen = earliestListen
    }

    public static let none = ListeningRecords(
        biggestDay: nil,
        mostArtistsDay: nil,
        mostRepeated: nil,
        longestSession: nil,
        latestListen: nil,
        earliestListen: nil
    )
}

/// One genre's plays in a range.
public struct GenreTally: Sendable, Equatable, Identifiable {
    public let name: String
    public let count: Int
    public let seconds: TimeInterval
    public let artistCount: Int

    public var id: String { name }

    public init(name: String, count: Int, seconds: TimeInterval, artistCount: Int) {
        self.name = name
        self.count = count
        self.seconds = seconds
        self.artistCount = artistCount
    }
}

/// Plays of songs released in one decade.
public struct DecadeCount: Sendable, Equatable, Identifiable {
    /// The decade's first year: 1990 for the 1990s.
    public let decade: Int
    public let count: Int
    public let seconds: TimeInterval

    public var id: Int { decade }

    public init(decade: Int, count: Int, seconds: TimeInterval) {
        self.decade = decade
        self.count = count
        self.seconds = seconds
    }
}

/// A song and the year it came out, for "oldest song".
public struct ReleaseRecord: Sendable, Equatable {
    /// The song's identity, as in `SongTally.id`.
    public let songID: String
    public let title: String
    public let artistName: String
    public let year: Int

    public init(songID: String, title: String, artistName: String, year: Int) {
        self.songID = songID
        self.title = title
        self.artistName = artistName
        self.year = year
    }
}
