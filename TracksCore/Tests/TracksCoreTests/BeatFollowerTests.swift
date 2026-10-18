import Foundation
import Testing
@testable import TracksCore

@Suite("Beat follower")
struct BeatFollowerTests {
    /// What the meter hears at `time`, 24 bands evened out, 0 to 1.
    typealias Sound = @Sendable (Double) -> [Float]

    /// A kick on every beat at `tempo` over a held bass and some hats, a little noise in it.
    static func kicks(tempo: Double, from start: Double = 0) -> Sound {
        { time in
            let beat = 60 / tempo
            let into = (time - start).truncatingRemainder(dividingBy: beat)
            let hit = time >= start && into >= 0 ? Float(exp(-into / 0.09)) : 0
            var noise = SeededRandom("\(Int(time * 1000))")
            return (0..<24).map { band in
                let wobble = Float(noise.next() % 1000) / 1000 * 0.03
                let body: Float = band < 6 ? 0.55 : band < 16 ? 0.45 : 0.3
                let kick: Float = band < 6 ? 0.4 * hit : band < 12 ? 0.15 * hit : 0.05 * hit
                return min(1, body + kick + wobble)
            }
        }
    }

    /// A pad whose chord changes every four seconds, each change fading over a second and a
    /// half, and whose colour drifts: no attack anywhere.
    static let pad: Sound = { time in
        let chord = Int(time / 4)
        let into = time - Double(chord) * 4
        let blend = Float(min(1, into / 1.5))
        return (0..<24).map { band in
            let old = 0.45 + 0.2 * Float(sin(Double(band + (chord - 1) * 5)))
            let new = 0.45 + 0.2 * Float(sin(Double(band + chord * 5)))
            let drift = 0.02 * Float(sin(time * 0.7 + Double(band)))
            return old + (new - old) * blend + drift
        }
    }

    /// Plays `sound` for `seconds` at `fps`, returning each frame's time and reading.
    func play(_ sound: Sound, seconds: Double, fps: Double = 30, follower: inout BeatFollower) -> [(time: Double, reading: BeatFollower.Reading)] {
        (0..<Int(seconds * fps)).map { frame in
            let time = Double(frame) / fps
            return (time, follower.step(sound(time), elapsed: 1 / fps))
        }
    }

    /// When each pulse began: a frame whose pulse jumped up.
    func pulses(_ frames: [(time: Double, reading: BeatFollower.Reading)], above floor: Float = 0.1) -> [Double] {
        zip(frames, frames.dropFirst()).compactMap { before, after in
            after.reading.pulse > max(floor, before.reading.pulse + 0.05) ? after.time : nil
        }
    }

    @Test("A held pad, its chords changing slowly, never pulses", arguments: [30.0, 60.0])
    func padStaysStill(fps: Double) {
        var follower = BeatFollower()
        let frames = play(Self.pad, seconds: 40, fps: fps, follower: &follower)
        #expect(frames.allSatisfy { $0.reading.pulse == 0 })
        #expect(frames.allSatisfy { $0.reading.confidence < 0.05 })
        #expect(follower.reading.drive < 0.05)
        #expect(follower.reading.tempo == nil)
    }

    @Test("Silence stays still")
    func silenceStaysStill() {
        var follower = BeatFollower()
        let frames = play({ _ in [Float](repeating: 0, count: 24) }, seconds: 20, follower: &follower)
        #expect(frames.allSatisfy { $0.reading.pulse == 0 && $0.reading.drive == 0 })
    }

    @Test("A kick at 128 is found within a few seconds and pulses on its beats", arguments: [30.0, 60.0])
    func kickPulsesOnBeat(fps: Double) throws {
        var follower = BeatFollower()
        let frames = play(Self.kicks(tempo: 128), seconds: 30, fps: fps, follower: &follower)
        let tempo = try #require(follower.reading.tempo)
        #expect(abs(tempo - 128) < 2)
        #expect(follower.reading.drive > 0.6)

        // Locked within five seconds, then a pulse on every beat, each within a frame or two.
        let beat = 60.0 / 128
        let late = pulses(frames).filter { $0 > 5 }
        let expected = Int((30 - 5) / beat)
        #expect(late.count >= expected - 3 && late.count <= expected + 1)
        let offsets = late.map { time in
            let into = time.truncatingRemainder(dividingBy: beat)
            return min(into, beat - into)
        }
        #expect(offsets.allSatisfy { $0 < 0.07 }, "\(offsets.max() ?? 0)")
    }

    @Test("A ballad's slow beat is found at its own tempo, not twice as fast")
    func slowBeat() throws {
        var follower = BeatFollower()
        _ = play(Self.kicks(tempo: 72), seconds: 30, follower: &follower)
        let tempo = try #require(follower.reading.tempo)
        #expect(abs(tempo - 72) < 2)
    }

    @Test("When the beat stops, the pulses stop within a few seconds")
    func beatStopping() {
        var follower = BeatFollower()
        _ = play(Self.kicks(tempo: 120), seconds: 20, follower: &follower)
        let frames = play(Self.pad, seconds: 12, follower: &follower)
        #expect(frames.filter { $0.time > 4 }.allSatisfy { $0.reading.pulse < 0.05 })
    }

    @Test("Anything at all comes in, it stays in bounds")
    func bounded() {
        var follower = BeatFollower(tempoHint: .nan)
        let inputs: [[Float]] = [[], [.nan, 1], [Float](repeating: 40, count: 24), [Float](repeating: -3, count: 24), [Float](repeating: .infinity, count: 24)]
        for index in 0..<1_500 {
            let reading = follower.step(inputs[index % inputs.count], elapsed: [1.0 / 30, 0, 9, -1, .nan][index % 5])
            #expect(reading.pulse.isFinite && reading.pulse >= 0 && reading.pulse <= 1)
            for part in [reading.confidence, reading.punch, reading.drive, reading.brightness] {
                #expect(part.isFinite && part >= 0 && part <= 1)
            }
        }
    }
}
