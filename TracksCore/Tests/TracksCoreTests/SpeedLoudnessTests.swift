import Testing
import Foundation
@testable import TracksCore

@Suite("Louder at Speed")
struct SpeedLoudnessTests {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Drives a stretch: a speed reading every second, as Core Location gives them, and the
    /// music moved ten times a second, as the app does.
    /// - Returns: the time the stretch ended.
    @discardableResult
    func drive(_ loudness: inout SpeedLoudness, at speed: Double, for seconds: Int, from time: Date) -> Date {
        var now = time
        for _ in 0..<seconds {
            loudness.hear(speed: speed, at: now)
            for _ in 0..<10 {
                now = now.addingTimeInterval(0.1)
                loudness.advance(to: now)
            }
        }
        return now
    }

    /// Time passing with no readings, as when the car stops and Core Location goes quiet.
    @discardableResult
    func wait(_ loudness: inout SpeedLoudness, for seconds: Int, from time: Date) -> Date {
        var now = time
        for _ in 0..<(seconds * 10) {
            now = now.addingTimeInterval(0.1)
            loudness.advance(to: now)
        }
        return now
    }

    func kmh(_ value: Double) -> Double { value / 3.6 }

    /// A car that has been on the highway long enough to settle there.
    func onTheHighway(_ amount: SpeedVolumeAmount = .moderate) -> (SpeedLoudness, Date) {
        var loudness = SpeedLoudness(amount: amount)
        let now = drive(&loudness, at: kmh(110), for: 20, from: start)
        return (loudness, now)
    }

    // MARK: - The curve

    @Test("the music is at full on the highway and the amount's stopped level when still")
    func curveEnds() {
        for amount in SpeedVolumeAmount.allCases {
            #expect(SpeedLoudness.decibels(atSpeed: 0, amount: amount) == -amount.stoppedDecibels)
            #expect(SpeedLoudness.decibels(atSpeed: SpeedLoudness.highwaySpeed, amount: amount) == 0)
            #expect(SpeedLoudness.decibels(atSpeed: kmh(160), amount: amount) == 0)
        }
    }

    @Test("the music rises with every step up in speed, most of the way by town speeds")
    func curveShape() {
        let speeds = stride(from: 0.0, through: 35, by: 2.5)
        let levels = speeds.map { SpeedLoudness.decibels(atSpeed: $0, amount: .moderate) }
        #expect(zip(levels, levels.dropFirst()).allSatisfy { $0 <= $1 })
        // Road noise grows fastest at low speed: past halfway by 50 km/h.
        #expect(SpeedLoudness.decibels(atSpeed: kmh(50), amount: .moderate) > -4)
        #expect(SpeedLoudness.decibels(atSpeed: kmh(30), amount: .moderate) < -3)
    }

    @Test("a stronger amount goes quieter when stopped, and never quieter than you'd miss it")
    func amounts() {
        let stopped = SpeedVolumeAmount.allCases.map(\.stoppedDecibels)
        #expect(stopped == stopped.sorted())
        // Moderate stays over a third of full: quiet enough to talk over, still clearly there.
        #expect(SpeedLoudness.amplitude(decibels: -SpeedVolumeAmount.moderate.stoppedDecibels) > 0.33)
        #expect(SpeedLoudness.amplitude(decibels: -SpeedVolumeAmount.strong.stoppedDecibels) >= 0.25)
    }

    // MARK: - Moving with the car

    @Test("pulling away from lights, the music comes up with the car within a few seconds")
    func pullingAway() {
        var loudness = SpeedLoudness(amount: .moderate, level: -8)
        var now = drive(&loudness, at: 0, for: 10, from: start)
        #expect(loudness.level == -8)
        // 0 to 50 km/h over about six seconds, then holding it.
        for step in 1...6 {
            now = drive(&loudness, at: kmh(Double(step) * 50 / 6), for: 1, from: now)
        }
        let atSpeed = SpeedLoudness.decibels(atSpeed: kmh(50), amount: .moderate)
        #expect(loudness.level > -6, "it's already on its way up as the car gets going")
        now = drive(&loudness, at: kmh(50), for: 4, from: now)
        #expect(abs(loudness.level - atSpeed) < 0.5)
    }

    @Test("braking hard doesn't make the music dip: it eases down slower than it rose")
    func braking() {
        var (loudness, now) = onTheHighway()
        #expect(loudness.level == 0)
        // 110 down to 50 km/h in a few seconds, as for a junction.
        now = drive(&loudness, at: kmh(50), for: 3, from: now)
        let target = SpeedLoudness.decibels(atSpeed: kmh(50), amount: .moderate)
        #expect(loudness.level > target / 2, "still well above where it's heading after three seconds")
        drive(&loudness, at: kmh(50), for: 25, from: now)
        #expect(abs(loudness.level - target) < 0.3)
    }

    @Test("stopped at lights, the music settles to the stopped level, quiet enough to talk")
    func stoppingAtLights() {
        var loudness = SpeedLoudness(amount: .moderate)
        var now = drive(&loudness, at: kmh(50), for: 20, from: start)
        now = drive(&loudness, at: 0, for: 2, from: now)
        #expect(loudness.phase == .moving, "a moment's stop isn't a stop yet")
        now = drive(&loudness, at: 0, for: 12, from: now)
        #expect(loudness.phase == .stopped)
        #expect(abs(loudness.level + 8) < 0.5)
    }

    @Test("a stop is noticed even when the phone stops reporting speed")
    func quietStop() {
        var loudness = SpeedLoudness(amount: .moderate)
        var now = drive(&loudness, at: kmh(40), for: 20, from: start)
        now = drive(&loudness, at: 0, for: 1, from: now)
        wait(&loudness, for: 15, from: now)
        #expect(loudness.phase == .stopped)
        #expect(abs(loudness.level + 8) < 0.5)
    }

    @Test("rolling through a turn or creeping in traffic isn't taken for a stop")
    func creeping() {
        var loudness = SpeedLoudness(amount: .moderate)
        var now = drive(&loudness, at: kmh(50), for: 20, from: start)
        for _ in 0..<6 {
            now = drive(&loudness, at: 0, for: 2, from: now)
            now = drive(&loudness, at: kmh(12), for: 2, from: now)
        }
        #expect(loudness.phase != .stopped)
    }

    @Test("cruising, a wobble in speed doesn't move the music")
    func cruising() {
        var (loudness, now) = onTheHighway()
        // Settle at 90 km/h, then wander a little either side of it, as on hills.
        now = drive(&loudness, at: kmh(90), for: 40, from: now)
        #expect(loudness.phase == .cruising)
        let settled = loudness.level
        for speed in [86.0, 93, 88, 95, 87, 92] {
            now = drive(&loudness, at: kmh(speed), for: 3, from: now)
            #expect(loudness.level == settled)
        }
    }

    @Test("with no readings, as in a tunnel, the music holds where it is")
    func tunnel() {
        var (loudness, now) = onTheHighway()
        now = drive(&loudness, at: kmh(80), for: 40, from: now)
        #expect(loudness.isSettled)
        let before = loudness.level
        wait(&loudness, for: 60, from: now)
        #expect(loudness.level == before)
    }

    @Test("a change of amount is followed at once")
    func changingAmount() {
        var loudness = SpeedLoudness(amount: .moderate)
        let now = drive(&loudness, at: 0, for: 30, from: start)
        loudness.amount = .strong
        #expect(loudness.target == -12)
        drive(&loudness, at: 0, for: 20, from: now)
        #expect(abs(loudness.level + 12) < 0.3)
    }

    @Test("before any reading the music stays where it was")
    func noReadings() {
        var loudness = SpeedLoudness(amount: .strong)
        wait(&loudness, for: 5, from: start)
        #expect(loudness.level == 0)
        #expect(loudness.isSettled)
    }

    @Test("music that hasn't started yet starts at the level for the road, with nothing to hear move")
    func settling() {
        var loudness = SpeedLoudness(amount: .moderate)
        loudness.hear(speed: 0, at: start)
        loudness.settle()
        #expect(loudness.level == -8)
        #expect(loudness.isSettled)
    }

    @Test("when the drive ends, the music comes back up to your volume within a few seconds")
    func releasing() {
        var loudness = SpeedLoudness(amount: .moderate)
        let now = drive(&loudness, at: 0, for: 30, from: start)
        #expect(abs(loudness.level + 8) < 0.3)
        loudness.release()
        let later = wait(&loudness, for: 6, from: now)
        #expect(loudness.level > -0.5)
        wait(&loudness, for: 10, from: later)
        #expect(loudness.level == 0)
        #expect(loudness.speed == nil)
    }

    // MARK: - iPhone's volume, for Apple Music

    @Test("the volume you set is kept for the speed you set it at")
    func anchorKeepsYourVolume() {
        let anchor = SystemVolumeAnchor(volume: 0.5, at: -6)
        #expect(abs(anchor.volume(at: -6) - 0.5) < 0.0001)
    }

    @Test("from a stop to the highway, the volume comes up a step for every three decibels")
    func anchorFollowsLevel() {
        let anchor = SystemVolumeAnchor(volume: 0.5, at: -9)
        #expect(abs(anchor.volume(at: 0) - (0.5 + 3.0 / 16)) < 0.0001)
        #expect(abs(anchor.volume(at: -12) - (0.5 - 1.0 / 16)) < 0.0001)
    }

    @Test("the volume never goes past full, and never below the lowest step")
    func anchorLimits() {
        let loud = SystemVolumeAnchor(volume: 0.95, at: -8)
        #expect(loud.volume(at: 0) == 1)
        let quiet = SystemVolumeAnchor(volume: 0.1, at: 0)
        #expect(quiet.volume(at: -12) == 1.0 / 16)
    }

    @Test("a muted iPhone stays muted at any speed")
    func anchorMuted() {
        let muted = SystemVolumeAnchor(volume: 0, at: -8)
        #expect(muted.volume(at: -8) == 0)
        #expect(muted.volume(at: 0) == 0)
    }
}
