import Foundation
import Testing
@testable import TracksCore

/// Living Cover fed real sound, the way the app hears it: each frame's moment measured, evened
/// out to the song's level, its beat found, then felt.
@Suite("Living Cover hearing sound")
struct LivingCoverHearingTests {
    static let rate = 44_100.0

    /// A slow pad: a held chord every four seconds, each fading into the next over a second and
    /// a half, with no attack anywhere.
    static func pad(seconds: Double) -> [Float] {
        let chords: [[Double]] = [[130.8, 164.8, 196.0], [110.0, 130.8, 164.8], [87.3, 110.0, 130.8], [98.0, 123.5, 146.8]]
        return (0..<Int(seconds * rate)).map { index in
            let time = Double(index) / rate
            let chord = Int(time / 4)
            let blend = min(1, (time - Double(chord) * 4) / 1.5)
            func voice(_ notes: [Double]) -> Double {
                notes.reduce(0) { sum, note in sum + sin(2 * .pi * note * time) + 0.3 * sin(4 * .pi * note * time) }
            }
            let old = voice(chords[(chord + 3) % 4]), new = voice(chords[chord % 4])
            return Float(0.08 * (old + (new - old) * blend))
        }
    }

    /// A kick on every beat at `tempo` over a held bass note.
    static func kicks(tempo: Double, seconds: Double) -> [Float] {
        let beat = 60 / tempo
        return (0..<Int(seconds * rate)).map { index in
            let time = Double(index) / rate
            let into = time.truncatingRemainder(dividingBy: beat)
            // A falling pitch, as a kick drum's is.
            let pitch = 2 * .pi * (50 * into + 70 * 0.04 * (1 - exp(-into / 0.04)))
            let kick = sin(pitch) * exp(-into / 0.12)
            let bass = 0.15 * sin(2 * .pi * 55 * time)
            return Float(0.6 * kick + bass)
        }
    }

    struct Moment {
        var time: Double
        var reading: BeatFollower.Reading
        var frame: LivingCoverFeel.Frame
    }

    /// Hears `samples` at 30 frames a second, as Living Cover does, every frame's moment and how
    /// the cover moves.
    func hear(_ samples: [Float]) throws -> [Moment] {
        let analyzer = try #require(SpectrumAnalyzer(size: SpectrumLayout.size(for: Self.rate), sampleRate: Self.rate, bandCount: 24))
        var gain = SpectrumGain()
        var contrast = LevelContrast()
        var smoother = LevelSmoother(count: 24, resting: 0.04, attack: 0.02, release: 0.18)
        var beat = BeatFollower()
        var feel = LivingCoverFeel()
        let size = analyzer.size
        let dt = 1.0 / 30
        var moments: [Moment] = []
        var time = Double(size) / Self.rate
        while Int(time * Self.rate) + size / 2 < samples.count {
            let centre = Int(time * Self.rate)
            let decibels = analyzer.decibels(of: Array(samples[(centre - size / 2)..<(centre + size / 2)]))
            let even = gain.levels(for: decibels, elapsed: dt)
            let reading = beat.step(even, elapsed: dt)
            let bands = smoother.step(toward: contrast.apply(even, elapsed: dt), elapsed: dt)
            let character = LivingCoverFeel.Character(punch: reading.punch, brightness: reading.brightness, intensity: 0.75, lock: reading.confidence, gentleness: 1 - reading.drive)
            let frame = feel.step(bands: bands, kick: reading.pulse, activity: 0.3, beats: reading.confidence > 0 ? reading.beats : nil, isPlaying: true, character: character, elapsed: dt)
            moments.append(Moment(time: time, reading: reading, frame: frame))
            time += dt
        }
        return moments
    }

    @Test("A steady slow pad never pulses or sways: it breathes")
    func padNeverPulses() throws {
        let moments = try hear(Self.pad(seconds: 40))
        #expect(moments.allSatisfy { $0.frame.thump == 0 })
        #expect(moments.allSatisfy { abs($0.frame.twist) < 0.001 })
        let breath = moments.filter { $0.time > 20 }.map(\.frame.breath)
        #expect((breath.max() ?? 0) - (breath.min() ?? 0) > 0.2)
    }

    @Test("A kick at 128 pushes the cover on its beats, once the beat is found")
    func kickPulsesOnTheBeat() throws {
        let moments = try hear(Self.kicks(tempo: 128, seconds: 30))
        let tempo = try #require(moments.last?.reading.tempo)
        #expect(abs(tempo - 128) < 2)

        let beat = 60.0 / 128
        // Where each push starts: a push lands over a frame or two.
        var pushes: [Double] = []
        for (before, after) in zip(moments, moments.dropFirst()) where after.time > 6 && after.frame.thump > before.frame.thump + 0.1 {
            if after.time - (pushes.last ?? 0) > 0.15 { pushes.append(after.time) }
        }
        let expected = Int((moments.last!.time - 6) / beat)
        #expect(pushes.count >= expected - 3 && pushes.count <= expected + 1)
        // Each within a frame or two of its beat, allowing for the moment measured around it.
        let offsets = pushes.map { time in
            let into = time.truncatingRemainder(dividingBy: beat)
            return min(into, beat - into)
        }
        #expect(offsets.allSatisfy { $0 < 0.08 }, "\(offsets.max() ?? 0)")
        #expect(moments.last!.reading.drive > 0.5)
    }

    @Test("Silence stays still")
    func silenceStaysStill() throws {
        let moments = try hear([Float](repeating: 0, count: Int(20 * Self.rate)))
        #expect(moments.allSatisfy { moment in
            let frame = moment.frame
            return frame.thump == 0 && frame.twist == 0 && frame.shimmer == 0 && frame.lift == 0 && frame.breath == 0 && moment.reading.confidence == 0
        })
    }
}
