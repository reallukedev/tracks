import Foundation

/// Decides from what iPhone senses whether you're driving, steadily: the motion has to be sure
/// of a car before Tracks Radio changes, a stop at the lights doesn't end a drive, and walking
/// away does at once. CarPlay counts as driving for as long as it's connected.
public struct DriveSense: Sendable, Equatable {
    /// One of Core Motion's activity readings, reduced to what the decision needs.
    public struct Reading: Sendable, Equatable {
        public let date: Date
        public let isAutomotive: Bool
        /// Walking, running or cycling.
        public let isOnFoot: Bool
        /// Core Motion's medium confidence or better.
        public let isConfident: Bool

        public init(date: Date, isAutomotive: Bool, isOnFoot: Bool = false, isConfident: Bool = true) {
            self.date = date
            self.isAutomotive = isAutomotive
            self.isOnFoot = isOnFoot
            self.isConfident = isConfident
        }
    }

    /// How long a drive lasts past the last sign of a car, for traffic and lights.
    public static let lingering: TimeInterval = 4 * 60

    public private(set) var isCarPlayConnected = false
    /// When the drive under way started, by motion or CarPlay. Nil when not driving.
    public private(set) var driveStart: Date?
    /// The last moment a car was sensed. Core Motion reads out changes, so a car sensed goes
    /// on being sensed until a reading says otherwise.
    private var lastInCar: Date?
    private var isInCar = false

    public init() {}

    public var isDriving: Bool { driveStart != nil }

    /// Takes a reading.
    /// - Returns: the drive it ended, if it ended one.
    public mutating func take(_ reading: Reading) -> DateInterval? {
        if reading.isAutomotive {
            if reading.isConfident, driveStart == nil { driveStart = reading.date }
            // An unsure reading keeps a drive going, but never starts one.
            if driveStart != nil {
                isInCar = true
                lastInCar = reading.date
            }
            return nil
        }
        if isInCar {
            isInCar = false
            lastInCar = reading.date
        }
        if reading.isOnFoot, reading.isConfident, !isCarPlayConnected {
            return end(at: lastInCar ?? reading.date)
        }
        return check(at: reading.date)
    }

    /// Ends the drive once long enough has passed without a car: for a timer, since Core
    /// Motion stays quiet while nothing changes.
    /// - Returns: the drive it ended, if it ended one.
    public mutating func check(at date: Date) -> DateInterval? {
        guard let start = driveStart, !isCarPlayConnected, !isInCar else { return nil }
        let last = lastInCar ?? start
        guard date.timeIntervalSince(last) >= Self.lingering else { return nil }
        return end(at: last)
    }

    /// When the drive under way would end if nothing more were sensed, for the timer. Nil when
    /// nothing would end it: no drive, CarPlay, or a car still sensed.
    public var endsAt: Date? {
        guard let start = driveStart, !isCarPlayConnected, !isInCar else { return nil }
        return (lastInCar ?? start).addingTimeInterval(Self.lingering)
    }

    /// CarPlay connecting starts a drive at once. Disconnecting leaves it to the motion, which
    /// ends it after ``lingering`` unless the car is still sensed.
    /// - Returns: the drive it ended, if it ended one.
    public mutating func carPlay(isConnected: Bool, at date: Date) -> DateInterval? {
        guard isConnected != isCarPlayConnected else { return nil }
        isCarPlayConnected = isConnected
        if isConnected, driveStart == nil { driveStart = date }
        if !isInCar { lastInCar = date }
        return nil
    }

    private mutating func end(at date: Date) -> DateInterval? {
        guard let start = driveStart else { return nil }
        driveStart = nil
        lastInCar = nil
        isInCar = false
        return DateInterval(start: start, end: max(start, date))
    }

    /// The drives in a run of past readings, as Core Motion's history gives them.
    /// - Parameter end: when the readings stop: a drive still under way then ends there.
    /// - Returns: the drives, oldest first.
    public static func drives(in readings: [Reading], until end: Date) -> [DateInterval] {
        var sense = DriveSense()
        var found: [DateInterval] = []
        for reading in readings.sorted(by: { $0.date < $1.date }) where reading.date <= end {
            if let drive = sense.take(reading) { found.append(drive) }
        }
        if let drive = sense.check(at: end) ?? sense.end(at: sense.isInCar ? end : sense.lastInCar ?? end) {
            found.append(drive)
        }
        return found
    }
}
