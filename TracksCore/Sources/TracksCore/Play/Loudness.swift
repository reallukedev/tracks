import Foundation

/// How loud a stretch of sound is as a listener hears it, measured the way broadcasters do
/// (ITU-R BS.1770, in LUFS): weighted toward the frequencies ears are most sensitive to,
/// in 400 ms blocks, with the near-silent moments left out so a fade doesn't count as quiet.
///
/// A loud dance master sits around -7 LUFS, most pop around -10, a quiet ballad near -16,
/// and a soft classical piece below -20. Every 10 LU quieter sounds about half as loud.
public nonisolated enum Loudness {
    /// Below this a block is silence, not music.
    public static let silence = -70.0

    /// `samples` through the K-weighting filter: a shelf lifting the highs a few decibels, as
    /// the head does, and a cut below 40 Hz, which ears hardly hear.
    public static func weighted(_ samples: [Float], sampleRate: Double) -> [Float] {
        guard sampleRate.isFinite, sampleRate > 1_000, !samples.isEmpty else { return [] }
        let shelf = Biquad.highShelf(gain: 4, frequency: 1_500, q: 1 / 2.0.squareRoot(), rate: sampleRate)
        let cut = Biquad.highPass(frequency: 38, q: 0.5, rate: sampleRate)
        var out = [Float](repeating: 0, count: samples.count)
        var first = Biquad.State(), second = Biquad.State()
        for index in samples.indices {
            let value = samples[index].isFinite ? Double(samples[index]) : 0
            out[index] = Float(cut.step(shelf.step(value, &first), &second))
        }
        return out
    }

    /// Each 400 ms block's mean square, every 100 ms, of K-weighted samples.
    public static func blocks(_ weighted: [Float], sampleRate: Double, length: Double = 0.4, hop: Double = 0.1) -> [Double] {
        let size = Int(sampleRate * length), step = max(1, Int(sampleRate * hop))
        guard size > 0, weighted.count >= size else { return [] }
        var prefix = [Double](repeating: 0, count: weighted.count + 1)
        for index in weighted.indices { prefix[index + 1] = prefix[index] + Double(weighted[index]) * Double(weighted[index]) }
        return stride(from: 0, through: weighted.count - size, by: step).map { (prefix[$0 + size] - prefix[$0]) / Double(size) }
    }

    /// A mean square as loudness, LUFS.
    public static func lufs(meanSquare: Double) -> Double {
        -0.691 + 10 * log10(max(meanSquare, 1e-12))
    }

    /// The loudness of the whole stretch, LUFS, from its blocks: the music, not the
    /// silences between. `silence` when there's nothing above it.
    public static func integrated(_ blocks: [Double]) -> Double {
        let audible = blocks.filter { lufs(meanSquare: $0) > silence }
        guard !audible.isEmpty else { return silence }
        let relative = lufs(meanSquare: audible.reduce(0, +) / Double(audible.count)) - 10
        let kept = audible.filter { lufs(meanSquare: $0) > relative }
        guard !kept.isEmpty else { return silence }
        return lufs(meanSquare: kept.reduce(0, +) / Double(kept.count))
    }

    /// How far the loud passages stand above the quiet ones, in LU: the spread of three-second
    /// loudness from its 10th to its 95th percentile, as EBU R 128's loudness range.
    public static func range(_ blocks: [Double]) -> Double {
        // Thirty 100 ms blocks make three seconds.
        let span = 27
        guard blocks.count > span else { return 0 }
        let shortTerm = stride(from: 0, to: blocks.count - span, by: 10).map { start in
            lufs(meanSquare: blocks[start ... start + span].reduce(0, +) / Double(span + 1))
        }.filter { $0 > silence }
        guard !shortTerm.isEmpty else { return 0 }
        let mean = shortTerm.map { pow(10, $0 / 10) }.reduce(0, +) / Double(shortTerm.count)
        let gate = 10 * log10(mean) - 20
        let sorted = shortTerm.filter { $0 > gate }.sorted()
        guard sorted.count > 1 else { return 0 }
        return sorted[Int(Double(sorted.count - 1) * 0.95)] - sorted[Int(Double(sorted.count - 1) * 0.1)]
    }

    /// The loudness a drawing moves fully at; a dance master is about here.
    public static let full = -8.0
    /// Every this many LU quieter, a drawing moves half as much. Ears halve loudness every 10
    /// LU; a little steeper reads better, since a quiet song is quiet in character too.
    public static let halving = 8.0
    /// The least a song that's playing moves, however quiet, so it still reads as playing.
    public static let least = 0.15

    /// How strongly a song this loud should move a drawing, 0 to 1. -8 LUFS or louder, fully;
    /// -16, half; -24, a quarter; never below a seventh for music, and down to nothing as it
    /// fades toward silence. Unknown, fully, as before loudness was measured.
    public static func intensity(lufs: Double?) -> Double {
        guard let lufs else { return 1 }
        guard lufs.isFinite else { return 0 }
        let heard = min(1, max(least, pow(2, (lufs - full) / halving)))
        // From -52 to -38 the music fades in out of the hiss.
        let audible = min(1, max(0, (lufs + 52) / 14))
        return heard * audible * audible * (3 - 2 * audible)
    }

    /// How much more or less a moment `relative` LU from the song's own level moves, by the
    /// same curve, held to a sensible spread.
    public static func gain(relative: Double) -> Double {
        guard relative.isFinite else { return 1 }
        return min(1.25, max(0.3, pow(2, relative / halving)))
    }
}

/// A two-pole filter, as the loudness standard defines its weighting.
private nonisolated struct Biquad {
    let b0, b1, b2, a1, a2: Double

    struct State {
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    }

    func step(_ x: Double, _ state: inout State) -> Double {
        let y = b0 * x + b1 * state.x1 + b2 * state.x2 - a1 * state.y1 - a2 * state.y2
        state.x2 = state.x1
        state.x1 = x
        state.y2 = state.y1
        state.y1 = y
        return y
    }

    static func highShelf(gain: Double, frequency: Double, q: Double, rate: Double) -> Biquad {
        let a = pow(10, gain / 40)
        let w = 2 * .pi * frequency / rate
        let alpha = sin(w) / (2 * q)
        let root = 2 * a.squareRoot() * alpha
        let a0 = (a + 1) - (a - 1) * cos(w) + root
        return Biquad(
            b0: a * ((a + 1) + (a - 1) * cos(w) + root) / a0,
            b1: -2 * a * ((a - 1) + (a + 1) * cos(w)) / a0,
            b2: a * ((a + 1) + (a - 1) * cos(w) - root) / a0,
            a1: 2 * ((a - 1) - (a + 1) * cos(w)) / a0,
            a2: ((a + 1) - (a - 1) * cos(w) - root) / a0
        )
    }

    static func highPass(frequency: Double, q: Double, rate: Double) -> Biquad {
        let w = 2 * .pi * frequency / rate
        let alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha
        return Biquad(
            b0: (1 + cos(w)) / 2 / a0,
            b1: -(1 + cos(w)) / a0,
            b2: (1 + cos(w)) / 2 / a0,
            a1: -2 * cos(w) / a0,
            a2: (1 - alpha) / a0
        )
    }
}
