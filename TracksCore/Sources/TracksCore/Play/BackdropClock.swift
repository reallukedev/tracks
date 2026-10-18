import Foundation

/// The time a moving background keeps: it runs while the music plays, glides to a stop when
/// it's paused and picks up again from where it stopped, never jumping.
///
/// Its speed eases toward the one asked for with a time constant of `easing` seconds, so a
/// pause slows the flow over a second or two, as a record player's platter winds down, and a
/// song with more energy speeds it up without a lurch. Phase and speed are both continuous
/// across every change.
public nonisolated struct BackdropClock: Equatable, Sendable {
    /// Seconds for the speed to cover two thirds of the way to a new one.
    public let easing: Double
    /// The speed it's heading for: 0 when paused.
    public private(set) var targetSpeed: Double
    private var anchorTime: Double
    private var anchorPhase: Double
    private var anchorSpeed: Double

    /// Below this it's still, to the eye.
    static let restingSpeed = 0.002

    /// A clock already at `speed`, from `phase`.
    public init(speed: Double, at time: Double, phase: Double = 0, easing: Double = 0.7) {
        self.easing = max(0.01, easing)
        targetSpeed = speed
        anchorTime = time
        anchorPhase = phase
        anchorSpeed = speed
    }

    public func phase(at time: Double) -> Double {
        let elapsed = max(0, time - anchorTime)
        let remaining = (anchorSpeed - targetSpeed) * easing * (1 - exp(-elapsed / easing))
        return anchorPhase + targetSpeed * elapsed + remaining
    }

    public func speed(at time: Double) -> Double {
        let elapsed = max(0, time - anchorTime)
        return targetSpeed + (anchorSpeed - targetSpeed) * exp(-elapsed / easing)
    }

    /// Heads for a new speed from wherever it is now.
    public mutating func setSpeed(_ speed: Double, at time: Double) {
        guard speed != targetSpeed else { return }
        anchorPhase = phase(at: time)
        anchorSpeed = self.speed(at: time)
        anchorTime = time
        targetSpeed = speed
    }

    /// Stopped, so the drawing can stop.
    public func isAtRest(at time: Double) -> Bool {
        targetSpeed == 0 && abs(speed(at: time)) < Self.restingSpeed
    }

    /// Seconds from `time` until it's at rest: nil while it's heading for a speed above 0.
    public func secondsToRest(from time: Double) -> Double? {
        guard targetSpeed == 0 else { return nil }
        let speed = abs(speed(at: time))
        guard speed >= Self.restingSpeed else { return 0 }
        return easing * log(speed / Self.restingSpeed)
    }
}
