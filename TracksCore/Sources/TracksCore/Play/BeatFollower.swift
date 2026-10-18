import Accelerate
import Foundation

/// Finds the beat in sound as it's heard, so what moves with the music pulses on the song's own
/// beats and nowhere else.
///
/// Each moment, how much is newly arriving across the bands (spectral flux, against the louder
/// of the last two moments and their neighbouring bands, so a held note's wobble or a slide in
/// pitch isn't news) is kept for the last eight seconds. How alike that is to itself a beat
/// later gives the tempo and how surely there is one; where the arrivals line up in the last
/// few beats gives the beat's place. A clock then runs on at that tempo and pulses as each beat
/// comes, so a pulse lands with the beat rather than a moment after it, and only while the beat
/// is sure and keeps landing. A piano ballad, a held pad or a breakdown has no sure beat and
/// never pulses.
///
/// It also says how hard the beats land, and from both how driven the music is: a dance track
/// near 1, a ballad near 0. And where the sound sits, dark to bright, over the last few seconds.
public nonisolated struct BeatFollower: Equatable, Sendable {
    public struct Reading: Equatable, Sendable {
        /// Full as a sure beat lands, then falling away; 0 with no sure beat.
        public var pulse: Float = 0
        /// Beats a minute, while there's a sure beat.
        public var tempo: Double?
        /// How surely there's a beat, 0 to 1.
        public var confidence = 0.0
        /// How hard the beats land, 0 to 1.
        public var punch = 0.0
        /// How driven the music is, 0 to 1: a sure beat that lands hard.
        public var drive = 0.0
        /// Where the sound sits, 0 dark to 1 bright.
        public var brightness = 0.5
        /// Beats counted, the fraction how far into the current one, once a tempo's been found.
        public var beats: Double?

        public init() {}
    }

    /// Moments a second the arrivals are kept at, whatever the frame rate.
    static let rate = 30.0
    /// Eight seconds of them.
    static let length = 240

    /// An expected tempo, from what's known of the song, which the search leans toward.
    public var tempoHint: Double?
    public private(set) var reading = Reading()

    private var envelope = [Float](repeating: 0, count: BeatFollower.length)
    /// Room to work the tempo out in, kept so it isn't made anew four times a second.
    private var values = [Float](repeating: 0, count: BeatFollower.length)
    private var alike = [Float](repeating: 0, count: 2 * BeatFollower.lags.upperBound + 2)
    private var head = 0
    private var filled = 0
    private var last: [Float] = []
    private var beforeLast: [Float] = []
    private var pending: Float = 0
    private var clock = 0.0
    private var nextSample = 0.0
    private var sinceEstimate = 0.0

    /// Seconds a beat.
    private var period: Double?
    /// A different tempo found once, waiting to be found again before it's taken.
    private var candidate: Double?
    private var clarity = 0.0
    private var sureness = 0.0
    /// Beats counted, the fraction how far into this one.
    private var beat = 0.0
    private var sinceBeat = Double.infinity
    /// When the last beat came, in samples, to judge whether it landed once its moment is in.
    private var judging: Int?
    /// How much arrives where the beats come, lately, and the most it has in the song lately.
    private var landed = 0.0
    private var hardest = 0.0
    private var brightness = 0.5
    private var hasBrightness = false

    public init(tempoHint: Double? = nil) {
        self.tempoHint = tempoHint
    }

    /// Steps on by `elapsed` seconds with this moment's bands, 0 to 1 low to high, as heard
    /// evened out (decibels over a range that rides the song, see ``SpectrumGain``).
    @discardableResult
    public mutating func step(_ levels: [Float], elapsed: Double) -> Reading {
        let dt = elapsed.isFinite ? min(max(elapsed, 0), 0.25) : 0
        let arriving = arrival(levels)
        followBrightness(levels, elapsed: dt)
        pending = max(pending, arriving)
        clock += dt
        while nextSample <= clock {
            envelope[head] = pending
            head = (head + 1) % Self.length
            filled += 1
            pending = 0
            nextSample += 1 / Self.rate
        }
        judge()
        sinceEstimate += dt
        if sinceEstimate >= 0.25 {
            sinceEstimate = 0
            estimate()
        }
        // Sure takes a beat or two of evidence; unsure is quicker, so a breakdown stops pulsing.
        sureness = Self.ease(sureness, toward: clarity, elapsed: dt, rise: 1.2, fall: 0.8)
        hardest = max(landed, hardest * exp(-dt / 20))
        let punch = Self.smoothstep(0.03, 0.18, hardest)
        // A beat is only sure if something arrives on it: a pad's faint drift can repeat too.
        let lands = Self.smoothstep(0.004, 0.02, landed)
        let confidence = Self.smoothstep(0.28, 0.5, sureness) * lands
        // Each beat as strong as the beats are landing now against the song's hardest, so a
        // breakdown's faint hats pulse faintly and the drop's kick fully.
        let accent = hardest > 0 ? pow(Self.unit(landed / hardest), 0.7) : 0

        var fired: Float = 0
        sinceBeat += dt
        if let period {
            let before = beat
            beat += dt / period
            if beat.rounded(.down) != before.rounded(.down), sinceBeat > period * 0.6 {
                sinceBeat = 0
                judging = filled + 2
                fired = Float(confidence * accent)
            }
        }
        // A beat's pulse falls away over a part of the beat: short at a dance tempo, longer
        // and softer for a slow one.
        let fade = min(0.3, max(0.08, 0.22 * (period ?? 0.5)))
        var next = reading
        next.pulse = max(fired, reading.pulse * Float(exp(-dt / fade)))
        next.confidence = confidence
        next.tempo = confidence > 0 ? period.map { 60 / $0 } : nil
        next.punch = punch
        next.drive = Self.ease(reading.drive, toward: confidence * (0.35 + 0.65 * punch), elapsed: dt, rise: 1.5, fall: 2.5)
        next.brightness = brightness
        next.beats = period == nil ? nil : beat
        reading = next
        return next
    }

    /// How much is newly arriving across the bands, against the louder of the last two moments
    /// and their neighbours.
    private mutating func arrival(_ levels: [Float]) -> Float {
        let count = levels.count
        guard count > 0, levels.allSatisfy(\.isFinite) else { return 0 }
        defer {
            beforeLast = last.count == count ? last : levels
            last = levels
        }
        guard last.count == count, beforeLast.count == count else { return 0 }
        var total: Float = 0
        for band in 0..<count {
            var reference = max(last[band], beforeLast[band])
            if band > 0 { reference = max(reference, last[band - 1], beforeLast[band - 1]) }
            if band + 1 < count { reference = max(reference, last[band + 1], beforeLast[band + 1]) }
            total += max(0, levels[band] - reference)
        }
        return total / Float(count)
    }

    private mutating func followBrightness(_ levels: [Float], elapsed: Double) {
        var weight: Float = 0, place: Float = 0
        for (band, level) in levels.enumerated() {
            weight += max(0, level)
            place += max(0, level) * Float(band) / Float(max(1, levels.count - 1))
        }
        guard weight > 0.5, levels.allSatisfy(\.isFinite) else { return }
        let centre = Double(place / weight)
        let goal = Self.unit((centre - 0.25) / 0.25)
        brightness = hasBrightness ? Self.ease(brightness, toward: goal, elapsed: elapsed, rise: 4, fall: 4) : goal
        hasBrightness = true
    }

    /// The arrivals into `values`, oldest first, mean taken away. How many there are.
    private mutating func history() -> Int {
        let count = min(filled, Self.length)
        var mean: Float = 0
        for index in 0..<count {
            let value = envelope[(head - count + index + Self.length) % Self.length]
            values[index] = value
            mean += value
        }
        mean /= Float(max(1, count))
        for index in 0..<count { values[index] -= mean }
        return count
    }

    /// The tempo, how surely there's a beat, and where it is.
    private mutating func estimate() {
        let count = history()
        guard count >= 90 else { return }
        // How alike the arrivals are to themselves each lag later, for every lag looked at.
        let lags = Self.lags.lowerBound - 1...2 * Self.lags.upperBound + 1
        var energy: Float = 0
        values.withUnsafeBufferPointer { values in
            vDSP_dotpr(values.baseAddress!, 1, values.baseAddress!, 1, &energy, vDSP_Length(count))
            for lag in lags {
                var sum: Float = 0
                if lag < count {
                    vDSP_dotpr(values.baseAddress! + lag, 1, values.baseAddress!, 1, &sum, vDSP_Length(count - lag))
                }
                alike[lag] = sum
            }
        }
        // Silence, or sound with nothing arriving in it.
        guard energy > 1e-7 else {
            clarity = 0
            return
        }
        func likeness(_ lag: Int) -> Double { Double(alike[lag] / energy) }
        let centre = tempoHint.flatMap { $0.isFinite && $0 > 30 ? $0 : nil } ?? 110
        let width = tempoHint == nil ? 0.9 : 0.4
        var best: (score: Double, lag: Int)?
        for lag in Self.lags {
            let tempo = 60 * Self.rate / Double(lag)
            let prior = exp(-0.5 * pow(log2(tempo / centre) / width, 2))
            let twice = 2 * lag < count - 10 ? 0.5 * likeness(2 * lag) : 0
            let score = prior * (likeness(lag) + twice)
            if score > best?.score ?? -.infinity { best = (score, lag) }
        }
        guard let best else { return }
        // Between whole moments, where the likeness peaks.
        let (before, at, after) = (likeness(best.lag - 1), likeness(best.lag), likeness(best.lag + 1))
        let curve = before - 2 * at + after
        let shift = curve < 0 ? min(0.5, max(-0.5, 0.5 * (before - after) / curve)) : 0
        clarity = max(0, at - 0.25 * (before - after) * shift)
        adopt(period: (Double(best.lag) + shift) / Self.rate)
        place(count: count)
    }

    /// 45 to 200 beats a minute, in moments a beat.
    private static let lags = 9...40

    /// Takes a new tempo: eased toward when it's close, and only once found twice when it isn't,
    /// so a stray estimate doesn't throw the beat off.
    private mutating func adopt(period found: Double) {
        guard let period, sureness > 0.15 else {
            self.period = found
            candidate = nil
            return
        }
        if abs(found / period - 1) < 0.06 {
            self.period = period + (found - period) * 0.3
            candidate = nil
        } else if let candidate, abs(found / candidate - 1) < 0.06 {
            self.period = found
            self.candidate = nil
        } else {
            candidate = found
        }
    }

    /// Nudges the beat clock toward where the arrivals of the last four beats line up.
    private mutating func place(count: Int) {
        guard let period else { return }
        let samples = period * Self.rate
        let steps = Int(samples.rounded())
        guard steps > 1 else { return }
        var bestOffset = 0, bestScore = -Double.infinity
        for offset in 0..<steps {
            var score = 0.0, weight = 1.0
            for beat in 0..<4 {
                let index = Double(count - 1 - offset) - Double(beat) * samples
                guard index >= 1 else { break }
                let whole = Int(index)
                score += weight * Double(max(values[whole], values[min(count - 1, whole + 1)]))
                weight *= 0.8
            }
            if score > bestScore {
                bestScore = score
                bestOffset = offset
            }
        }
        // The last beat was `bestOffset` moments ago, so the clock should be that far into one.
        let measured = Double(bestOffset) / samples
        let current = beat - beat.rounded(.down)
        var error = measured - current
        error -= error.rounded()
        beat += error * 0.5
    }

    /// Once a beat's moment is in, how much arrived there.
    private mutating func judge() {
        guard let due = judging, filled >= due else { return }
        judging = nil
        var strongest: Float = 0
        for back in 0..<min(4, filled) {
            strongest = max(strongest, envelope[(head - 1 - back + Self.length) % Self.length])
        }
        landed += (Double(strongest) - landed) * 0.35
    }

    private static func ease(_ value: Double, toward goal: Double, elapsed: Double, rise: Double, fall: Double) -> Double {
        value + (goal - value) * (1 - exp(-elapsed / (goal > value ? rise : fall)))
    }

    private static func smoothstep(_ low: Double, _ high: Double, _ value: Double) -> Double {
        let x = unit((value - low) / (high - low))
        return x * x * (3 - 2 * x)
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}
