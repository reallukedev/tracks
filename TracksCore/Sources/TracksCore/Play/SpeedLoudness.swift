import Foundation

/// How much Louder at Speed changes the music between a stop and the highway.
public enum SpeedVolumeAmount: String, CaseIterable, Identifiable, Sendable {
    case slight, moderate, strong

    public var id: Self { self }

    /// How far under your highway volume the music settles when the car stops, in decibels.
    /// Moderate is quiet enough to talk over and still plainly there when you're on your own.
    public var stoppedDecibels: Double {
        switch self {
        case .slight: 5
        case .moderate: 8
        case .strong: 12
        }
    }
}

/// What Louder at Speed does with the car's speed: the level the music should be at, and how it
/// gets there.
///
/// The level is in decibels under your highway volume: nothing off at highway speed and above,
/// and ``SpeedVolumeAmount/stoppedDecibels`` off when the car is stopped. In between it follows
/// road noise, which grows fastest as a car first picks up speed and levels off on the highway.
///
/// It moves as the car does. Speeding up, the music comes up with it, a moment behind, so you
/// feel it pull away with you. Slowing down, it eases off slowly, so braking never makes it
/// dip. Stopped for a few seconds, as at lights, it settles to the stopped level, and pulling
/// away brings it straight back. Cruising, it holds steady through the small changes of speed a
/// road brings, so it never pumps.
public struct SpeedLoudness: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Still for a few seconds: at lights, in a queue, parked.
        case stopped
        case moving
        /// Holding a steady speed on an open road.
        case cruising
    }

    public var amount: SpeedVolumeAmount {
        didSet { retarget(force: true) }
    }

    /// Where the music is now, in decibels under your highway volume.
    public private(set) var level: Double
    /// Where it's heading.
    public private(set) var target: Double
    /// The car's speed, lightly smoothed, in metres a second. Nil until the first reading.
    public private(set) var speed: Double?
    public private(set) var phase: Phase = .moving

    /// When the car last went below walking pace, while it stays there.
    private var slowSince: Date?
    /// The speed a steady stretch started at, and when, for cruising.
    private var steadySpeed = 0.0
    private var steadySince: Date?
    private var lastAdvanced: Date?

    /// Full level from here up: 112 km/h, or 70 mph.
    public static let highwaySpeed = 31.0
    /// Where the curve bends: road noise grows fastest below about 20 km/h.
    static let curveKnee = 6.0
    /// Below this the car counts as stopped: about 4 km/h.
    static let stoppedSpeed = 1.2
    /// How long a stop lasts before the music settles for it, so rolling through a turn or
    /// creeping in traffic doesn't count.
    static let settlesAfter: TimeInterval = 3
    /// Cruising is a steady speed above about 40 km/h, held this long.
    static let cruisingSpeed = 11.0
    static let cruisingAfter: TimeInterval = 8

    /// How quickly the music follows, as time constants: most of the way there in about three
    /// times each. Up with the car, slowly down as it slows, and a little quicker to settle once
    /// it has stopped.
    static let risingTime: TimeInterval = 1.6
    static let fallingTime: TimeInterval = 7
    static let settlingTime: TimeInterval = 2.5

    /// - Parameters:
    ///   - level: where the music is now, in decibels under your highway volume: 0 when it's
    ///     just started following, or wherever it was left.
    public init(amount: SpeedVolumeAmount, level: Double = 0) {
        self.amount = amount
        self.level = level
        target = level
    }

    /// The level for a speed, in decibels under your highway volume.
    public static func decibels(atSpeed speed: Double, amount: SpeedVolumeAmount) -> Double {
        let share = log1p(max(0, speed) / curveKnee) / log1p(highwaySpeed / curveKnee)
        return -amount.stoppedDecibels * (1 - min(1, share))
    }

    /// A level in decibels as a share of full volume, for a player's own level.
    public static func amplitude(decibels: Double) -> Double {
        pow(10, decibels / 20)
    }

    /// Whether the music has arrived where it's heading, so nothing needs to move it.
    public var isSettled: Bool { level == target }

    /// Takes a reading of the car's speed, in metres a second.
    public mutating func hear(speed reading: Double, at date: Date) {
        let reading = min(max(0, reading), 70)
        // Light smoothing takes out the jitter in a satellite fix without adding much lag. A
        // stop is taken as it's read: a fix that says still is rarely wrong, and the phone may
        // say nothing more until the car moves again.
        let smoothed = reading < Self.stoppedSpeed ? reading : speed.map { $0 + (reading - $0) * 0.5 } ?? reading
        speed = smoothed
        if smoothed < Self.stoppedSpeed {
            if slowSince == nil { slowSince = date }
        } else {
            slowSince = nil
        }
        if smoothed < Self.cruisingSpeed || steadySince == nil
            || abs(smoothed - steadySpeed) > max(1.5, steadySpeed * 0.08) {
            steadySpeed = smoothed
            steadySince = date
        }
        followPhase(at: date)
        retarget(force: false)
    }

    /// Moves the music toward where it's heading, for the time since the last call.
    public mutating func advance(to date: Date) {
        // Time passing with no readings counts too: a car stopped at lights may stop reporting.
        followPhase(at: date)
        retarget(force: false)
        defer { lastAdvanced = date }
        guard let lastAdvanced else { return }
        // A long pause between calls moves it only a moment's worth, never in one jump.
        let elapsed = min(max(0, date.timeIntervalSince(lastAdvanced)), 0.25)
        let difference = target - level
        let time = difference > 0 ? Self.risingTime : phase == .stopped ? Self.settlingTime : Self.fallingTime
        level += difference * (1 - exp(-elapsed / time))
        if abs(target - level) < 0.02 { level = target }
    }

    /// Arrives at once, for music that isn't playing yet: nothing is heard to move.
    public mutating func settle() {
        level = target
    }

    /// Lets go of the speed, for the end of a drive: the music comes back up to your volume,
    /// as it would pulling away, and stays there until the next reading.
    public mutating func release() {
        speed = nil
        slowSince = nil
        steadySince = nil
        phase = .moving
        target = 0
    }

    private mutating func followPhase(at date: Date) {
        if let slowSince, date.timeIntervalSince(slowSince) >= Self.settlesAfter {
            phase = .stopped
        } else if let speed, speed >= Self.cruisingSpeed, let steadySince,
                  date.timeIntervalSince(steadySince) >= Self.cruisingAfter {
            phase = .cruising
        } else {
            phase = .moving
        }
    }

    /// Picks where the music heads. Small changes are let go, more of them while cruising, so a
    /// wobble in speed isn't heard as the music breathing.
    private mutating func retarget(force: Bool) {
        guard let speed else { return }
        let wanted = phase == .stopped ? -amount.stoppedDecibels : Self.decibels(atSpeed: speed, amount: amount)
        let slack = phase == .cruising ? 1.2 : 0.4
        if force || phase == .stopped || abs(wanted - target) >= slack {
            target = wanted
        }
    }
}

/// Louder at Speed for a player whose level Tracks can't set, as Apple Music's: it moves
/// iPhone's volume instead, starting from the volume you set.
///
/// Your volume counts as right for the speed you set it at. From there the volume goes up and
/// down by as many steps as the level changes, so the music keeps its place against the road.
public struct SystemVolumeAnchor: Sendable, Equatable {
    /// One press of the volume buttons: iPhone's volume has 16 of them.
    public static let step = 1.0 / 16
    /// About how far apart the steps are, at the volumes people listen at.
    public static let decibelsPerStep = 3.0

    /// The volume that plays at highway speed. Can be above full, when you set the volume high
    /// while slow: then the music can't get louder, and stays at full.
    public private(set) var highway: Double
    /// The quietest it goes: the lowest step, or yours if you had it lower.
    private let floor: Double
    /// Turned all the way down, it stays there: silence is a choice, not a level to follow.
    private let isMuted: Bool

    /// - Parameters:
    ///   - volume: iPhone's volume, 0 to 1, as you set it.
    ///   - decibels: the level at the time, from ``SpeedLoudness/level``.
    public init(volume: Double, at decibels: Double) {
        highway = volume - Self.steps(decibels) * Self.step
        floor = min(max(0, volume), Self.step)
        isMuted = volume <= 0
    }

    /// The volume for a level.
    public func volume(at decibels: Double) -> Double {
        guard !isMuted else { return 0 }
        return min(1, max(floor, highway + Self.steps(decibels) * Self.step))
    }

    private static func steps(_ decibels: Double) -> Double {
        decibels / decibelsPerStep
    }
}
