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

    /// A band playing hard but loose, the way a live funk or hip-hop band grooves: around 96,
    /// drifting a few percent faster and slower over each phrase as players do, the kick in a
    /// different syncopated place each bar and up to 20 ms either side of it, the snare mostly
    /// on two and four but sometimes pushed or left out, hats on most of the swung sixteenths,
    /// each hit as hard as it happens to be, and a bass line under chords. No beat a follower
    /// can be sure of for long, and plenty arriving. Sixteen seconds in, the drums drop out for
    /// eight, then all of it comes back: a breakdown and a drop.
    ///
    /// `steady`, it keeps time instead: a kick on every beat at 124, one in eight left out,
    /// the snare on two and four and hats on the eighths, each still as hard as it happens to be.
    static func band(seconds: Double, steady: Bool = false) -> [Float] {
        let beat = 60 / 96.0
        var random = SeededRandom(steady ? "steady band" : "band")
        func wobble(_ reach: Double) -> Double { (Double(random.next() % 2001) / 1000 - 1) * reach }
        func loud() -> Double { 0.55 + 0.45 * Double(random.next() % 1000) / 1000 }
        let patterns: [[Double]] = [[0, 1.5, 2.75], [0, 0.75, 2.5, 3.25], [0.5, 1.75, 3], [0, 2.25, 2.75, 3.5], [0, 1.25, 2.5]]
        var kicks: [(time: Double, loud: Double)] = []
        var snares: [(time: Double, loud: Double)] = []
        var hats: [(time: Double, loud: Double)] = []
        var start = 0.0, bar = 0
        while start < seconds {
            if steady {
                let beat = 60 / 124.0
                for place in 0..<4 where (bar * 4 + place) % 8 != 5 {
                    kicks.append((start + Double(place) * beat + wobble(0.01), loud()))
                }
                for place in [1.0, 3.0] { snares.append((start + place * beat + wobble(0.01), loud())) }
                for eighth in 0..<8 { hats.append((start + Double(eighth) * beat / 2, 0.3 + 0.7 * loud())) }
                start += 4 * beat
                bar += 1
                continue
            }
            // This bar's tempo, drifting over a seven-second phrase.
            let beat = 60 / (96 * (1 + 0.04 * sin(2 * .pi * start / 7)))
            for place in patterns[Int(random.next() % UInt64(patterns.count))] {
                kicks.append((start + place * beat + wobble(0.02), loud()))
            }
            for place in [1.0, 3.0] where random.next() % 6 != 0 {
                let pushed = random.next() % 5 == 0 ? 0.25 : 0
                snares.append((start + (place + pushed) * beat + wobble(0.015), loud()))
            }
            for sixteenth in 0..<16 where random.next() % 10 < 6 {
                let swing = sixteenth % 2 == 1 ? (0.03 + 0.06 * Double(random.next() % 100) / 100) * beat : 0
                hats.append((start + Double(sixteenth) * beat / 4 + swing + wobble(0.008), 0.3 + 0.7 * loud()))
            }
            start += 4 * beat
        }
        var samples = [Float](repeating: 0, count: Int(seconds * rate))
        var noise = SeededRandom("band noise")
        func near(_ hits: [(time: Double, loud: Double)], _ time: Double, within: Double) -> [(time: Double, loud: Double)] {
            hits.filter { $0.time <= time && time - $0.time < within }
        }
        var lastKicks: [(time: Double, loud: Double)] = [], lastSnares = lastKicks, lastHats = lastKicks
        for index in samples.indices {
            let time = Double(index) / rate
            if index % 512 == 0 {
                lastKicks = near(kicks, time + 0.02, within: 0.7)
                lastSnares = near(snares, time + 0.02, within: 0.5)
                lastHats = near(hats, time + 0.02, within: 0.2)
            }
            let drums = time < 16 || time >= 24
            let at = Int(time / beat)
            let roots = [55.0, 43.65, 49.0, 41.2]
            let root = roots[(at / 4) % 4]
            var sound = 0.05 * (sin(2 * .pi * root * 4 * time) + sin(2 * .pi * root * 5 * time) + sin(2 * .pi * root * 6 * time))
            if drums {
                let eighth = time.truncatingRemainder(dividingBy: beat / 2)
                sound += 0.18 * sin(2 * .pi * root * time) * exp(-eighth / 0.2)
                let hiss = Double(noise.next() % 2001) / 1000 - 1
                for kick in lastKicks where kick.time <= time {
                    let into = time - kick.time
                    let pitch = 2 * .pi * (50 * into + 70 * 0.04 * (1 - exp(-into / 0.04)))
                    sound += 0.55 * kick.loud * sin(pitch) * exp(-into / 0.12)
                }
                for snare in lastSnares where snare.time <= time {
                    let into = time - snare.time
                    sound += 0.3 * snare.loud * (0.6 * hiss + 0.4 * sin(2 * .pi * 190 * into)) * exp(-into / 0.09)
                }
                for hat in lastHats where hat.time <= time {
                    sound += 0.07 * hat.loud * hiss * exp(-(time - hat.time) / 0.025)
                }
            }
            samples[index] = Float(sound)
        }
        return samples
    }

    /// A piano ballad: soft notes a second or so apart, never quite evenly, each ringing on,
    /// over a held chord.
    static func ballad(seconds: Double) -> [Float] {
        var random = SeededRandom("ballad")
        var notes: [(start: Double, pitch: Double)] = []
        var time = 0.3
        let scale = [261.6, 293.7, 329.6, 392.0, 440.0, 523.3]
        while time < seconds {
            notes.append((time, scale[Int(random.next() % UInt64(scale.count))]))
            time += 0.8 + Double(random.next() % 900) / 1000
        }
        return (0..<Int(seconds * rate)).map { index in
            let time = Double(index) / rate
            var sound = 0.04 * (sin(2 * .pi * 130.8 * time) + sin(2 * .pi * 196 * time))
            for note in notes where note.start <= time && time - note.start < 4 {
                let into = time - note.start
                let envelope = min(1, into / 0.01) * exp(-into / 1.2)
                sound += 0.12 * envelope * (sin(2 * .pi * note.pitch * into) + 0.4 * sin(4 * .pi * note.pitch * into))
            }
            return Float(sound)
        }
    }

    struct Moment {
        var time: Double
        var reading: BeatFollower.Reading
        var frame: LivingCoverFeel.Frame
        /// The stir alone, without the bar's sway, and how far the sway reaches.
        var stirred = 0.0
        var sway = 0.0
    }

    /// How often each of the cover's moves shows, a minute, past `from` seconds.
    struct Moves {
        var pulse = 0.0, swirl = 0.0, glint = 0.0, swell = 0.0, lift = 0.0, breath = 0.0
        /// The part of the time it sways, and how much its flow's speed and its layers' turns vary.
        var swaying = 0.0, flowRange = 0.0, layersApart = 0.0

        init(_ all: [Moment], from: Double) {
            let moments = all.filter { $0.time >= from }
            guard moments.count > 2 else { return }
            let minutes = (moments.last!.time - moments.first!.time) / 60
            func times(_ values: [Double], above: Double, below: Double) -> Double {
                var armed = true, count = 0
                for value in values {
                    if armed, value > above { count += 1; armed = false }
                    if value < below { armed = true }
                }
                return Double(count) / minutes
            }
            // A pulse is a push at least 0.15 above the dip before it.
            var pulses = 0, trough = moments[0].frame.thump
            for index in 1..<(moments.count - 1) {
                let (before, here, after) = (moments[index - 1].frame.thump, moments[index].frame.thump, moments[index + 1].frame.thump)
                trough = min(trough, here)
                if here > before, here >= after {
                    if here - trough >= 0.15 { pulses += 1 }
                    trough = here
                }
            }
            pulse = Double(pulses) / minutes
            swirl = times(moments.map { abs($0.stirred) }, above: 0.25, below: 0.08)
            glint = times(moments.map(\.frame.shimmer), above: 0.25, below: 0.1)
            swell = times(moments.map(\.frame.swell), above: 0.6, below: 0.45)
            lift = times(moments.map(\.frame.lift), above: 0.3, below: 0.1)
            breath = times(moments.map { abs($0.frame.breath) }, above: 0.15, below: 0.05)
            swaying = Double(moments.filter { $0.sway > 0.1 }.count) / Double(moments.count)
            let speeds = moments.map(\.frame.speed).sorted()
            flowRange = speeds[speeds.count * 9 / 10] / max(0.01, speeds[speeds.count / 10])
            var apart = 0.0
            for (a, b) in zip(moments, moments.dropFirst()) {
                let elapsed = b.time - a.time
                let rates = [b.frame.deep - a.frame.deep, b.frame.middle - a.frame.middle, b.frame.top - a.frame.top].map { $0 / elapsed }
                apart = max(apart, (rates.max() ?? 0) - (rates.min() ?? 0))
            }
            layersApart = apart
        }
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
            // As the app has it: what's heard lands where it's heard, and only the bar's sway
            // waits on a sure beat.
            let character = LivingCoverFeel.Character(punch: reading.punch, brightness: reading.brightness, intensity: 0.75, lock: 1, gentleness: 1 - reading.drive, sureness: reading.confidence)
            let frame = feel.step(bands: bands, kick: reading.pulse, activity: 0.3, beats: reading.confidence > 0 ? reading.beats : nil, isPlaying: true, character: character, elapsed: dt)
            moments.append(Moment(time: time, reading: reading, frame: frame, stirred: feel.stirred, sway: feel.sway))
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

    @Test("A loose, energetic band with no sure beat still pulses, and uses every move, none all the time")
    func energeticBandUsesEveryMove() throws {
        let moments = try hear(Self.band(seconds: 40))
        let moves = Moves(moments, from: 6)
        // Pushing with the music most of the time, unsure of its beat as it is.
        #expect(moves.pulse > 40 && moves.pulse < 140, "pulse \(moves.pulse)")
        #expect(moves.swirl > 0 && moves.swirl < 40, "swirl \(moves.swirl)")
        #expect(moves.glint > 0 && moves.glint < 45, "glint \(moves.glint)")
        #expect(moves.swell > 0 && moves.swell < 30, "swell \(moves.swell)")
        #expect(moves.lift > 0 && moves.lift < 8, "lift \(moves.lift)")
        #expect(moves.breath < 10, "breath \(moves.breath)")
        // No beat to sway to.
        #expect(moves.swaying < 0.1, "sway \(moves.swaying)")
        #expect(moves.flowRange > 1.3, "flow \(moves.flowRange)")
        #expect(moves.layersApart > 0.15, "layers \(moves.layersApart)")
    }

    @Test("A steady, energetic band uses every move, the bar's sway included, none all the time")
    func steadyBandUsesEveryMove() throws {
        let moments = try hear(Self.band(seconds: 40, steady: true))
        let moves = Moves(moments, from: 6)
        // Most of its kicks, past the eight seconds without drums.
        #expect(moves.pulse > 45 && moves.pulse < 140, "pulse \(moves.pulse)")
        #expect(moves.swirl > 0 && moves.swirl < 40, "swirl \(moves.swirl)")
        #expect(moves.glint > 0 && moves.glint < 45, "glint \(moves.glint)")
        #expect(moves.swell > 0 && moves.swell < 30, "swell \(moves.swell)")
        #expect(moves.lift > 0 && moves.lift < 8, "lift \(moves.lift)")
        #expect(moves.breath > 0 && moves.breath < 10, "breath \(moves.breath)")
        #expect(moves.swaying > 0.05 && moves.swaying < 0.8, "sway \(moves.swaying)")
        #expect(moves.flowRange > 1.3, "flow \(moves.flowRange)")
        #expect(moves.layersApart > 0.15, "layers \(moves.layersApart)")
    }

    @Test("A piano ballad stays calm: no beat to push or sway to, and it breathes")
    func balladStaysCalm() throws {
        let moments = try hear(Self.ballad(seconds: 40))
        let moves = Moves(moments, from: 6)
        #expect(moves.pulse < 8, "pulse \(moves.pulse)")
        #expect(moves.swirl < 4, "swirl \(moves.swirl)")
        #expect(moves.swaying == 0, "sway \(moves.swaying)")
        #expect(moves.breath > 0, "breath \(moves.breath)")
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
