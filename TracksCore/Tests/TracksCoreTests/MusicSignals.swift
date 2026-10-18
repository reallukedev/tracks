import Foundation
@testable import TracksCore

/// Music made up for tests, with the true beat of every bar known, so what moves with it can be
/// measured against where a listener would tap their foot.
struct MusicSignal: Sendable {
    let name: String
    let samples: [Float]
    /// Every beat, in seconds, and which of them start a bar.
    let beats: [Double]
    let downbeats: [Double]
    /// Where there's a beat to pulse on, past the first few seconds of finding it.
    let steady: [Range<Double>]

    static let rate = 44_100.0

    var seconds: Double { Double(samples.count) / Self.rate }
    var expectsPulses: Bool { !steady.isEmpty }
}

/// Builds a mix by adding each hit where it lands, so a minute of drums costs no more than its hits.
struct Mixer {
    var samples: [Float]
    private var noise: UInt64 = 0x2545_F491_4F6C_DD1D

    init(seconds: Double) {
        samples = [Float](repeating: 0, count: Int(seconds * MusicSignal.rate))
    }

    private mutating func hiss() -> Float {
        noise ^= noise << 13
        noise ^= noise >> 7
        noise ^= noise << 17
        return Float(Int64(bitPattern: noise % 2_000_001) - 1_000_000) / 1_000_000
    }

    private mutating func add(at time: Double, length: Double, _ voice: (Double) -> Float) {
        let first = max(0, Int(time * MusicSignal.rate))
        let last = min(samples.count, Int((time + length) * MusicSignal.rate))
        guard first < last else { return }
        for index in first..<last {
            samples[index] += voice(Double(index) / MusicSignal.rate - time)
        }
    }

    mutating func kick(_ time: Double, loud: Double = 1) {
        add(at: time, length: 0.45) { into in
            let pitch = 2 * Double.pi * (50 * into + 90 * 0.035 * (1 - exp(-into / 0.035)))
            return Float(0.6 * loud * sin(pitch) * exp(-into / 0.13))
        }
    }

    mutating func snare(_ time: Double, loud: Double = 1) {
        var noise = [Float](repeating: 0, count: Int(0.3 * MusicSignal.rate) + 1)
        for index in noise.indices { noise[index] = hiss() }
        add(at: time, length: 0.3) { into in
            let index = min(noise.count - 1, Int(into * MusicSignal.rate))
            return Float(0.32 * loud * (0.65 * Double(noise[index]) + 0.35 * sin(2 * .pi * 185 * into)) * exp(-into / 0.08))
        }
    }

    mutating func hat(_ time: Double, loud: Double = 1, open: Bool = false) {
        let length = open ? 0.25 : 0.06
        var noise = [Float](repeating: 0, count: Int(length * MusicSignal.rate) + 1)
        for index in noise.indices { noise[index] = hiss() }
        var last: Float = 0
        add(at: time, length: length) { into in
            let index = min(noise.count - 1, Int(into * MusicSignal.rate))
            // Only the hiss's top: what's left after taking away its last moment.
            let high = noise[index] - last
            last = noise[index]
            return Float(0.09 * loud * exp(-into / (open ? 0.09 : 0.018))) * high
        }
    }

    mutating func tom(_ time: Double, pitch: Double, loud: Double = 1) {
        add(at: time, length: 0.35) { into in
            Float(0.4 * loud * sin(2 * .pi * pitch * into * (1 - 0.3 * min(1, into / 0.2))) * exp(-into / 0.12))
        }
    }

    mutating func crash(_ time: Double) {
        var noise = [Float](repeating: 0, count: Int(1.6 * MusicSignal.rate) + 1)
        for index in noise.indices { noise[index] = hiss() }
        add(at: time, length: 1.6) { into in
            Float(0.12 * exp(-into / 0.5)) * noise[min(noise.count - 1, Int(into * MusicSignal.rate))]
        }
    }

    /// A plucked bass note that rings for `length`.
    mutating func bass(_ time: Double, pitch: Double, length: Double) {
        add(at: time, length: length) { into in
            let envelope = min(1, into / 0.008) * exp(-into / 0.35)
            return Float(0.2 * envelope * (sin(2 * .pi * pitch * into) + 0.3 * sin(4 * .pi * pitch * into)))
        }
    }

    /// A held chord, faded in and out over `fade`, so nothing in it arrives.
    mutating func pad(_ time: Double, notes: [Double], length: Double, fade: Double = 1.2, loud: Double = 1) {
        add(at: time, length: length + fade) { into in
            let envelope = min(1, into / fade) * min(1, max(0, (length + fade - into) / fade))
            let sound = notes.reduce(0.0) { $0 + sin(2 * .pi * $1 * into) + 0.25 * sin(4 * .pi * $1 * into) }
            return Float(0.05 * loud * envelope * sound)
        }
    }

    mutating func piano(_ time: Double, pitch: Double, loud: Double = 1) {
        add(at: time, length: 3.5) { into in
            let envelope = min(1, into / 0.01) * exp(-into / 1.1)
            return Float(0.12 * loud * envelope * (sin(2 * .pi * pitch * into) + 0.4 * sin(4 * .pi * pitch * into)))
        }
    }
}

extension MusicSignal {
    private static let roots = [55.0, 43.65, 49.0, 41.2]

    /// Beat times from `start` at `tempo` until `end`, and every fourth a downbeat.
    private static func grid(tempo: Double, from start: Double = 0, until end: Double) -> [Double] {
        stride(from: start, to: end, by: 60 / tempo).map { $0 }
    }

    /// A dance track at 124: a kick on every beat, a clap on two and four, open hats on the
    /// offbeats, a bass between the kicks, a crash every eight bars.
    static func fourOnTheFloor(seconds: Double = 40) -> MusicSignal {
        let beats = grid(tempo: 124, until: seconds)
        var mix = Mixer(seconds: seconds + 1)
        for (index, beat) in beats.enumerated() {
            let half = 60 / 124.0 / 2
            mix.kick(beat)
            if index % 2 == 1 { mix.snare(beat, loud: 0.9) }
            mix.hat(beat + half, loud: 0.8, open: true)
            mix.bass(beat + half, pitch: roots[(index / 8) % 4] * 2, length: half)
            if index % 32 == 0 { mix.crash(beat) }
        }
        return MusicSignal(name: "Four on the floor 124", samples: Array(mix.samples.prefix(Int(seconds * rate))), beats: beats, downbeats: stride(from: 0, to: beats.count, by: 4).map { beats[$0] }, steady: [5..<seconds])
    }

    /// Pop and rock at 100: kick on one, three and the and of three, snare on two and four,
    /// hats on the eighths, the bass changing each bar, a chord held under it.
    static func backbeat(seconds: Double = 40) -> MusicSignal {
        let tempo = 100.0, beat = 60 / tempo
        let beats = grid(tempo: tempo, until: seconds)
        var mix = Mixer(seconds: seconds + 2)
        for (index, time) in beats.enumerated() {
            let place = index % 4
            if place == 0 || place == 2 { mix.kick(time) }
            if place == 2 { mix.kick(time + beat / 2, loud: 0.6) }
            if place == 1 || place == 3 { mix.snare(time) }
            mix.hat(time, loud: 0.7)
            mix.hat(time + beat / 2, loud: 0.45)
            if place == 0 {
                let root = roots[(index / 4) % 4]
                mix.bass(time, pitch: root, length: beat * 2)
                mix.pad(time, notes: [root * 4, root * 5, root * 6], length: beat * 4 - 0.3, fade: 0.3, loud: 0.5)
            }
        }
        return MusicSignal(name: "Backbeat 100", samples: Array(mix.samples.prefix(Int(seconds * rate))), beats: beats, downbeats: stride(from: 0, to: beats.count, by: 4).map { beats[$0] }, steady: [5..<seconds])
    }

    /// Funk at 96, played by people: the kick somewhere new each bar, mostly off the beat, the
    /// snare on two and four with ghost notes around it, hats on most sixteenths, every hit up
    /// to 12 ms either side and as hard as it happens to be.
    static func syncopated(seconds: Double = 40) -> MusicSignal {
        let tempo = 96.0, beat = 60 / tempo
        let beats = grid(tempo: tempo, until: seconds)
        var random = SeededRandom("syncopated")
        func wobble() -> Double { (Double(random.next() % 2001) / 1000 - 1) * 0.012 }
        func loud() -> Double { 0.6 + 0.4 * Double(random.next() % 1000) / 1000 }
        let patterns: [[Double]] = [[0, 1.5, 2.75], [0, 0.75, 2.5, 3.25], [0, 1.75, 2.5], [0, 2.25, 2.75, 3.5], [0, 1.25, 2.5]]
        var mix = Mixer(seconds: seconds + 2)
        for bar in stride(from: 0, to: beats.count, by: 4) {
            let start = beats[bar]
            for place in patterns[Int(random.next() % UInt64(patterns.count))] { mix.kick(start + place * beat + wobble(), loud: loud()) }
            for place in [1.0, 3.0] { mix.snare(start + place * beat + wobble(), loud: loud()) }
            for ghost in [0.75, 1.25, 2.75, 3.5] where random.next() % 3 == 0 { mix.snare(start + ghost * beat + wobble(), loud: 0.25) }
            for sixteenth in 0..<16 where random.next() % 10 < 7 {
                mix.hat(start + Double(sixteenth) * beat / 4 + wobble(), loud: sixteenth % 4 == 0 ? 0.9 : 0.5 * loud())
            }
            mix.bass(start, pitch: roots[(bar / 4) % 4], length: beat * 1.5)
            mix.bass(start + 2.5 * beat, pitch: roots[(bar / 4) % 4] * 1.5, length: beat)
        }
        return MusicSignal(name: "Syncopated funk 96", samples: Array(mix.samples.prefix(Int(seconds * rate))), beats: beats, downbeats: stride(from: 0, to: beats.count, by: 4).map { beats[$0] }, steady: [6..<seconds])
    }

    /// A shuffle at 92: hats and ride on swung eighths, kick on one and three, snare on two
    /// and four with a swung ghost before each.
    static func swing(seconds: Double = 40) -> MusicSignal {
        let tempo = 92.0, beat = 60 / tempo
        let beats = grid(tempo: tempo, until: seconds)
        var mix = Mixer(seconds: seconds + 2)
        for (index, time) in beats.enumerated() {
            let place = index % 4
            if place % 2 == 0 { mix.kick(time) }
            if place % 2 == 1 {
                mix.snare(time)
                mix.snare(time - beat / 3, loud: 0.3)
            }
            mix.hat(time, loud: 0.8, open: place % 2 == 1)
            mix.hat(time + 2 * beat / 3, loud: 0.5)
            if place == 0 { mix.bass(time, pitch: roots[(index / 4) % 4], length: beat * 3) }
        }
        return MusicSignal(name: "Swing 92", samples: Array(mix.samples.prefix(Int(seconds * rate))), beats: beats, downbeats: stride(from: 0, to: beats.count, by: 4).map { beats[$0] }, steady: [5..<seconds])
    }

    /// A backbeat at 110 that jumps to 128 twenty seconds in.
    static func tempoChange(seconds: Double = 44) -> MusicSignal {
        let change = 20.0
        var beats = grid(tempo: 110, until: change)
        let resume = (beats.last ?? 0) + 60 / 110
        beats += grid(tempo: 128, from: resume, until: seconds)
        var mix = Mixer(seconds: seconds + 2)
        for (index, time) in beats.enumerated() {
            let place = index % 4
            let beat = time < resume ? 60 / 110.0 : 60 / 128.0
            mix.kick(time)
            if place % 2 == 1 { mix.snare(time) }
            mix.hat(time + beat / 2, loud: 0.6)
            if place == 0 { mix.bass(time, pitch: roots[(index / 4) % 4], length: beat * 2) }
        }
        return MusicSignal(name: "Tempo change 110 to 128", samples: Array(mix.samples.prefix(Int(seconds * rate))), beats: beats, downbeats: stride(from: 0, to: beats.count, by: 4).map { beats[$0] }, steady: [5..<change, (resume + 5)..<seconds])
    }

    /// A backbeat at 120 with a drum fill, sixteenths round the toms and snare, closing every
    /// fourth bar.
    static func fill(seconds: Double = 40) -> MusicSignal {
        let tempo = 120.0, beat = 60 / tempo
        let beats = grid(tempo: tempo, until: seconds)
        var mix = Mixer(seconds: seconds + 2)
        for (index, time) in beats.enumerated() {
            let place = index % 4, bar = index / 4
            let isFill = bar % 4 == 3 && place >= 2
            if place == 0, bar % 4 == 0 { mix.crash(time) }
            if isFill {
                for sixteenth in 0..<4 {
                    let at = time + Double(sixteenth) * beat / 4
                    if place == 2 { mix.snare(at, loud: 0.5 + 0.12 * Double(sixteenth)) } else { mix.tom(at, pitch: [180, 150, 120, 95][sixteenth]) }
                }
                if place == 2 { mix.kick(time) }
                continue
            }
            if place % 2 == 0 { mix.kick(time) }
            if place % 2 == 1 { mix.snare(time) }
            mix.hat(time, loud: 0.6)
            mix.hat(time + beat / 2, loud: 0.4)
            if place == 0 { mix.bass(time, pitch: roots[bar % 4], length: beat * 2) }
        }
        return MusicSignal(name: "Fill every 4 bars 120", samples: Array(mix.samples.prefix(Int(seconds * rate))), beats: beats, downbeats: stride(from: 0, to: beats.count, by: 4).map { beats[$0] }, steady: [5..<seconds])
    }

    /// Dance music at 126 whose drums drop out sixteen seconds in, leaving a held chord for
    /// eight seconds, then come back with a crash: a breakdown and a drop.
    static func breakdownAndDrop(seconds: Double = 44) -> MusicSignal {
        let tempo = 126.0, beat = 60 / tempo
        let beats = grid(tempo: tempo, until: seconds)
        let (breakdown, drop) = (beats[32], beats[48])
        var mix = Mixer(seconds: seconds + 3)
        for (index, time) in beats.enumerated() {
            let root = roots[(index / 8) % 4]
            if time >= breakdown, time < drop {
                if index % 8 == 0 { mix.pad(time, notes: [root * 4, root * 5, root * 6], length: beat * 8 - 0.4, fade: 0.6) }
                continue
            }
            if time == drop { mix.crash(time) }
            mix.kick(time)
            if index % 2 == 1 { mix.snare(time, loud: 0.8) }
            mix.hat(time + beat / 2, loud: 0.8, open: true)
            mix.bass(time + beat / 2, pitch: root * 2, length: beat / 2)
        }
        return MusicSignal(name: "Breakdown then drop 126", samples: Array(mix.samples.prefix(Int(seconds * rate))), beats: beats, downbeats: stride(from: 0, to: beats.count, by: 4).map { beats[$0] }, steady: [5..<breakdown, (drop + 2)..<seconds])
    }

    /// A rubato piano ballad: soft notes a second or so apart, never evenly, over a held chord.
    static func ballad(seconds: Double = 40) -> MusicSignal {
        var random = SeededRandom("ballad")
        var mix = Mixer(seconds: seconds + 4)
        let scale = [261.6, 293.7, 329.6, 392.0, 440.0, 523.3]
        var time = 0.3
        while time < seconds {
            mix.piano(time, pitch: scale[Int(random.next() % UInt64(scale.count))], loud: 0.6 + 0.4 * Double(random.next() % 100) / 100)
            time += 0.8 + Double(random.next() % 900) / 1000
        }
        for chord in stride(from: 0.0, to: seconds, by: 6) {
            mix.pad(chord, notes: [130.8, 196], length: 5, fade: 1.5, loud: 0.6)
        }
        return MusicSignal(name: "Rubato ballad", samples: Array(mix.samples.prefix(Int(seconds * rate))), beats: [], downbeats: [], steady: [])
    }

    /// A slow pad: a chord every four seconds, each fading into the next, no attack anywhere.
    static func pad(seconds: Double = 40) -> MusicSignal {
        let chords: [[Double]] = [[130.8, 164.8, 196.0], [110.0, 130.8, 164.8], [87.3, 110.0, 130.8], [98.0, 123.5, 146.8]]
        var mix = Mixer(seconds: seconds + 6)
        for (index, start) in stride(from: -1.5, to: seconds, by: 4).enumerated() {
            mix.pad(start, notes: chords[index % 4], length: 2.5, fade: 1.5, loud: 1.4)
        }
        return MusicSignal(name: "Pad", samples: Array(mix.samples.prefix(Int(seconds * rate))), beats: [], downbeats: [], steady: [])
    }

    static func silence(seconds: Double = 20) -> MusicSignal {
        MusicSignal(name: "Silence", samples: [Float](repeating: 0, count: Int(seconds * rate)), beats: [], downbeats: [], steady: [])
    }

    static var all: [MusicSignal] {
        [fourOnTheFloor(), backbeat(), syncopated(), swing(), tempoChange(), fill(), breakdownAndDrop(), ballad(), pad(), silence()]
    }
}
