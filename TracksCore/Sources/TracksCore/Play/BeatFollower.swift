import Accelerate
import Foundation

/// Finds the beat in sound as it's heard, the one a listener taps their foot to, and keeps a
/// clock locked to it, so what moves with the music pulses on the song's own beats and nowhere
/// else.
///
/// Each moment, how much is newly arriving across the bands (spectral flux, against the louder
/// of the last two moments and their neighbouring bands, so a held note's wobble or a slide in
/// pitch isn't news) is kept for the last eight seconds, the low bands counted twice since the
/// kick is where most feet land. How alike that is to itself a beat later, weighed toward the
/// tempos people tap and checked against twice the beat, gives the tempo. A clock then runs at
/// that tempo, and four times a second the arrivals of the last few beats are laid over its
/// grid: it's slewed gently toward where they line up, never jumping once it's sure, so a
/// fill's busy sixteenths or a syncopated kick don't throw it, and through a break it coasts
/// on and picks the beat straight back up at the drop. Only once the arrivals keep landing on
/// its grid is it sure, and only then does it pulse. With no sure beat it never pulses: a
/// ballad, a held pad, a breakdown or a loose jam move continuously instead (see
/// ``LivingCoverFeel``).
///
/// Which beat of four starts the bar comes from where the kick, the snare and the chords
/// change; the downbeat pulses fullest. Each beat pulses as hard as that beat of the bar has
/// lately landed, against the song's hardest, so a breakdown's last faint beats pulse faintly.
///
/// It also says how hard the beats land, and from that how driven the music is: a dance track
/// near 1, a ballad near 0. And where the sound sits, dark to bright, over the last few seconds.
public nonisolated struct BeatFollower: Equatable, Sendable {
    public struct Reading: Equatable, Sendable {
        /// Full as a sure beat lands, then falling away, `lead` seconds after the moment heard;
        /// 0 with no sure beat.
        public var pulse: Float = 0
        /// Beats a minute, while there's a sure beat.
        public var tempo: Double?
        /// How surely there's a beat, 0 to 1.
        public var confidence = 0.0
        /// How hard the beats land, 0 to 1.
        public var punch = 0.0
        /// How driven the music is, 0 to 1: a sure beat that lands hard, or music that keeps
        /// arriving hard.
        public var drive = 0.0
        /// Where the sound sits, 0 dark to 1 bright.
        public var brightness = 0.5
        /// How much keeps arriving, 0 to 1, whatever the tempo: drums and a busy mix near 1, a
        /// ballad's piano or a held pad near 0.
        public var vigour = 0.0
        /// Beats counted at the moment heard, the fraction how far into the current one, once a
        /// tempo's been found.
        public var beats: Double?
        /// Which of every four beats counted starts a bar, and how sure that is, 0 to 1.
        public var downbeat = 0
        public var downbeatSureness = 0.0
        /// How hard each of every four beats counted lands, lately, 0 to 1.
        public var accents: [Float] = [0, 0, 0, 0]
        /// Seconds a beat, once a tempo's been found.
        public var period: Double?

        public init() {}

        /// Beats into the bar, 0 on the downbeat.
        public var bar: Double? {
            beats.map { beats in
                let into = (beats - Double(downbeat)).truncatingRemainder(dividingBy: 4)
                return into < 0 ? into + 4 : into
            }
        }

        /// The pulse `seconds` after the moment heard, carried on by the beat's clock: what to
        /// draw for a frame that reaches the screen then.
        public func pulse(after seconds: Double) -> Float {
            guard let beats, let period, period > 0, beats.isFinite, seconds.isFinite else { return 0 }
            let gate = BeatFollower.smoothstep(0.3, 0.6, confidence)
            guard gate > 0 else { return 0 }
            let at = beats + min(max(seconds, -1), 1) / period
            var whole = at.rounded(.down)
            // Quicker than about 166 a minute, every other beat, from the downbeat: a pulse three
            // times a second reads as flicker, not as a beat.
            if period < 0.36, Self.slot(whole - Double(downbeat)) % 2 != 0 { whole -= 1 }
            let since = (at - whole) * period
            let fade = min(0.3, max(0.08, 0.22 * period))
            return Float(gate) * accents[Self.slot(whole)] * Float(exp(-since / fade))
        }

        static func slot(_ beat: Double) -> Int {
            let whole = Int(beat.truncatingRemainder(dividingBy: 4))
            return whole < 0 ? whole + 4 : whole
        }
    }

    /// Moments a second the arrivals are kept at, whatever the frame rate.
    static let rate = 30.0
    /// Eight seconds of them.
    static let length = 240
    /// How long after a drum's attack its arrival peaks, as measured: the transform is centred
    /// on the moment heard, so it hears an attack a little before it lands.
    static let onsetDelay = 0.0
    /// The decibels a band's height spans (see ``SpectrumGain``), to hear arrivals as loudness
    /// rather than as change: in decibels a quiet bass note arriving under a fading kick seems
    /// newer than the kick, and feet follow the kick.
    static let span: Float = 46
    /// An expected tempo, from what's known of the song, which the search leans toward.
    public var tempoHint: Double?
    /// Beats counted, when where they fall is already known, such as a replay of a song's
    /// preview placed in the song, the first of each four a downbeat, and how sure that is, 0
    /// to 1. The clock then keeps to them, at `tempoHint`, rather than to a beat found in
    /// what's heard.
    public var knownBeats: Double?
    public var knownSureness = 0.0
    /// Seconds after the moment heard that `reading.pulse` is for.
    public var lead = 0.0
    public private(set) var reading = Reading()

    /// What's arrived, all bands with the low ones counted twice, and in the low and middle
    /// bands alone; and when each moment was.
    private var envelope = [Float](repeating: 0, count: BeatFollower.length)
    private var alls = [Float](repeating: 0, count: BeatFollower.length)
    private var lows = [Float](repeating: 0, count: BeatFollower.length)
    private var mids = [Float](repeating: 0, count: BeatFollower.length)
    private var times = [Double](repeating: -.infinity, count: BeatFollower.length)
    /// Room to work the tempo out in, kept so it isn't made anew four times a second.
    private var values = [Float](repeating: 0, count: BeatFollower.length)
    private var alike = [Float](repeating: 0, count: 4 * BeatFollower.lags.upperBound + 2)
    private var grid = [Double](repeating: 0, count: BeatFollower.offsets)
    private var head = 0
    private var filled = 0
    private var last: [Float] = []
    private var beforeLast: [Float] = []
    private var pending = Arrival()
    private var pendingTime = 0.0
    private var clock = 0.0
    private var nextSample = 0.0
    private var sinceEstimate = 0.0

    /// Seconds a beat.
    private var period: Double?
    /// A different tempo found lately, and how many times running.
    private var candidate: Double?
    private var candidateCount = 0
    /// Found afresh: the clock is set to the beat's place outright rather than slewed toward it.
    private var isAcquiring = true
    /// How alike the arrivals are a beat apart, and how much more they land on the clock's
    /// grid than off it.
    private var clarity = 0.0
    private var contrast = 0.0
    /// How nearly another place in the beat, or a tempo not twice or half this one, would do as
    /// well: a dancehall's three-three-two, or a kick that only ever lands off the beat. Then
    /// it can't be sure which a listener would tap to.
    private var rivalPlace = 0.0
    private var rivalTempo = 0.0
    /// How alike the arrivals are a bar of four of these beats apart: a true beat's bar repeats.
    private var meter = 0.0
    private var sureness = 0.0
    /// How far the clock is still to be slewed, in beats, and how many times running the beat
    /// has seemed to be half a beat away.
    private var correction = 0.0
    private var flips = 0
    private var misses = 0
    /// Beats counted, the fraction how far into this one.
    private var beat = 0.0
    /// The last beat, to judge how hard it landed once its moment is in.
    private var judging: Judging?
    /// How much arrives where the beats come, lately, and the most it has in the song lately.
    private var landed = 0.0
    private var hardest = 0.0
    /// Each of every four beats: how hard it lands, and how much it sounds like a downbeat.
    private var slotLanded = [Double](repeating: 0, count: 4)
    private var slotDownbeat = [Double](repeating: 0, count: 4)
    /// The bands lately, and as they were at the last beat, for where the chords change.
    private var heldBands: [Float] = []
    private var beatBands: [Float] = []
    private var brightness = 0.5
    private var hasBrightness = false
    /// How strongly the music usually arrives, lately: most moments arrive no harder.
    private var typical: Float = 0
    private var vigour = 0.0

    private struct Judging: Equatable {
        var due: Double, at: Double, slot: Int
    }

    private struct Arrival: Equatable {
        /// In decibels, all told and in the low and middle bands, for how hard things land.
        var all: Float = 0, low: Float = 0, mid: Float = 0
        /// As loudness, the low bands counted twice, for where the beat is.
        var beat: Float = 0
    }

    public init(tempoHint: Double? = nil) {
        self.tempoHint = tempoHint
    }

    /// Steps on by `elapsed` seconds with this moment's bands, 0 to 1 low to high, as heard
    /// evened out (decibels over a range that rides the song, see ``SpectrumGain``).
    @discardableResult
    public mutating func step(_ levels: [Float], elapsed: Double) -> Reading {
        let dt = elapsed.isFinite ? min(max(elapsed, 0), 0.25) : 0
        let isValid = !levels.isEmpty && levels.allSatisfy(\.isFinite)
        let arriving = isValid ? arrival(levels) : Arrival()
        if isValid {
            followBrightness(levels, elapsed: dt)
            hold(levels, elapsed: dt)
        }
        clock += dt
        // The strongest moment of each sample, and when it came.
        if arriving.beat > pending.beat {
            pending = arriving
            pendingTime = clock
        }
        var isSampled = false
        while nextSample <= clock {
            envelope[head] = pending.beat
            alls[head] = pending.all
            lows[head] = pending.low
            mids[head] = pending.mid
            times[head] = pending.beat > 0 ? pendingTime : clock
            head = (head + 1) % Self.length
            filled += 1
            pending = Arrival()
            nextSample += 1 / Self.rate
            isSampled = true
        }
        // What arrives is measured against the sound a moment or two ago at the same pace
        // whatever the frame rate, so a beat found at 120 frames a second is the one at 30.
        if isSampled || last.isEmpty, isValid {
            beforeLast = last.count == levels.count ? last : levels
            last = levels
        }
        judge()
        sinceEstimate += dt
        if sinceEstimate >= 0.25 {
            sinceEstimate = 0
            estimate()
        }
        // Sure takes a beat or two of evidence and lets go more slowly, so a fill doesn't stop
        // the pulse; a breakdown, with nothing landing at all, stops it at once below.
        let target = Self.smoothstep(0.1, 0.3, clarity) * Self.smoothstep(1.3, 2.2, contrast) * Self.smoothstep(0.2, 0.5, meter)
            * (1 - Self.smoothstep(0.55, 0.8, rivalPlace)) * (1 - Self.smoothstep(0.8, 0.97, rivalTempo))
        sureness = Self.ease(sureness, toward: target, elapsed: dt, rise: 0.8, fall: 1.5)
        hardest = max(landed, hardest * exp(-dt / 20))
        vigour = Self.ease(vigour, toward: Self.smoothstep(0.02, 0.04, Double(typical)), elapsed: dt, rise: 1, fall: 2.5)
        // Beats that land hard, or music whose arrivals are mostly strong.
        let punch = max(Self.smoothstep(0.02, 0.09, hardest), Self.smoothstep(0.03, 0.08, Double(typical)))
        // A beat is only sure if something arrives on it: a pad's faint drift can repeat too.
        let lands = Self.smoothstep(0.004, 0.02, landed)
        var confidence = Self.smoothstep(0.3, 0.55, sureness) * lands
        var downbeat = Self.strongest(slotDownbeat)
        var downbeatSureness = Self.downbeatSureness(slotDownbeat)

        let known = knownBeats.flatMap { beats in tempoHint.map { (beats: beats, period: 60 / $0) } }
        let before = beat
        if let known, known.beats.isFinite, known.period.isFinite, known.period > 0.2, known.period < 2 {
            // Sure where the beats fall, if not yet how hard they land.
            confidence = max(confidence, Self.unit(knownSureness) * (0.5 + 0.5 * lands))
            period = known.period
            beat = known.beats
            downbeat = 0
            downbeatSureness = max(downbeatSureness, Self.unit(knownSureness))
            correction = 0
        } else if let period {
            // Slewed, never stepped back, so each beat comes once.
            let pace = dt / period
            let slew = max(-0.5 * pace, correction * (1 - exp(-dt / 0.35)))
            beat += pace + slew
            correction -= slew
        }
        let isNewBeat = period != nil && beat.rounded(.down) != before.rounded(.down) && beat > before
        if isNewBeat {
            let slot = Reading.slot(beat.rounded(.down))
            judging = Judging(due: clock + Self.onsetDelay + 0.12, at: clock - (beat - beat.rounded(.down)) * (period ?? 0.5), slot: slot)
        }
        // Counted from nearer zero now and then, by whole bars, so it never loses its fraction.
        if knownBeats == nil, beat > 4096 { beat -= 4096 }

        var next = reading
        next.confidence = confidence
        next.tempo = confidence > 0 ? period.map { 60 / $0 } : nil
        next.period = period
        next.beats = period == nil ? nil : beat
        next.punch = punch
        // Driven by a sure beat that lands hard, or by music that keeps arriving hard.
        let driven = max(confidence * (0.35 + 0.65 * punch), vigour * (0.5 + 0.5 * punch))
        next.drive = Self.ease(reading.drive, toward: driven, elapsed: dt, rise: 1.5, fall: 2.5)
        next.vigour = vigour
        next.brightness = brightness
        next.downbeat = downbeat
        next.downbeatSureness = downbeatSureness
        // Taken as each beat comes, so a beat's pulse never grows once it's begun.
        if isNewBeat || period == nil {
            next.accents = (0..<4).map { slot in
                guard hardest > 0 else { return 0 }
                let strength = pow(Self.unit(slotLanded[slot] / hardest), 0.7)
                return Float(slot == downbeat ? strength : strength * (1 - 0.3 * downbeatSureness))
            }
        }
        next.pulse = next.pulse(after: lead)
        reading = next
        return next
    }

    /// How much is newly arriving across the bands, against the louder of the last two moments
    /// and their neighbours: all told, and in the low and middle bands.
    private func arrival(_ levels: [Float]) -> Arrival {
        let count = levels.count
        guard last.count == count, beforeLast.count == count else { return Arrival() }
        var found = Arrival()
        for band in 0..<count {
            var reference = max(last[band], beforeLast[band])
            if band > 0 { reference = max(reference, last[band - 1], beforeLast[band - 1]) }
            if band + 1 < count { reference = max(reference, last[band + 1], beforeLast[band + 1]) }
            let new = max(0, levels[band] - reference)
            found.all += new
            let loudness = max(0, Self.loudness(levels[band]) - Self.loudness(reference))
            if band * 4 < count {
                found.low += new
                found.beat += 2 * loudness
            } else {
                if band * 3 < count * 2 { found.mid += new }
                found.beat += loudness
            }
        }
        let scale = 1 / Float(count)
        return Arrival(all: found.all * scale, low: found.low * scale, mid: found.mid * scale, beat: found.beat * scale)
    }

    private static func loudness(_ level: Float) -> Float {
        pow(10, span * (min(1, max(0, level)) - 1) / 20)
    }

    private mutating func followBrightness(_ levels: [Float], elapsed: Double) {
        var weight: Float = 0, place: Float = 0
        for (band, level) in levels.enumerated() {
            weight += max(0, level)
            place += max(0, level) * Float(band) / Float(max(1, levels.count - 1))
        }
        guard weight > 0.5 else { return }
        let centre = Double(place / weight)
        let goal = Self.unit((centre - 0.25) / 0.25)
        brightness = hasBrightness ? Self.ease(brightness, toward: goal, elapsed: elapsed, rise: 4, fall: 4) : goal
        hasBrightness = true
    }

    /// The low and middle bands, followed over a beat or so, for where the chords change.
    private mutating func hold(_ levels: [Float], elapsed: Double) {
        let count = levels.count * 2 / 3
        guard heldBands.count == count else {
            heldBands = Array(levels.prefix(count))
            return
        }
        let follow = Float(1 - exp(-elapsed / 0.2))
        for band in 0..<count { heldBands[band] += (levels[band] - heldBands[band]) * follow }
    }

    /// How strongly the music usually arrives: the last four seconds' ninetieth percentile.
    private mutating func followTypical() {
        let count = min(filled, Int(4 * Self.rate))
        guard count > 0 else { return }
        var recent = [Float](repeating: 0, count: count)
        for back in 0..<count { recent[back] = alls[(head - 1 - back + Self.length) % Self.length] }
        recent.sort()
        typical = recent[count * 9 / 10]
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
        // Blurred over two moments either side, so a beat that falls between two moments still
        // lines up with itself a beat later.
        var blurred = [Float](repeating: 0, count: count)
        for index in 0..<count {
            var sum: Float = 0, weight: Float = 0
            for (shift, share) in zip(-2...2, [1, 2, 3, 2, 1] as [Float]) where (0..<count).contains(index + shift) {
                sum += values[index + shift] * share
                weight += share
            }
            blurred[index] = sum / weight - mean
        }
        for index in 0..<count { values[index] = blurred[index] }
        return count
    }

    /// The tempo, how surely there's a beat, and where it is.
    private mutating func estimate() {
        let count = history()
        followTypical()
        guard count >= 90 else { return }
        // How alike the arrivals are to themselves each lag later, as a share of how alike
        // they are to themselves, for every lag from an eighth of the quickest beat to a bar
        // of the slowest.
        var energy: Float = 0
        values.withUnsafeBufferPointer { values in
            vDSP_dotpr(values.baseAddress!, 1, values.baseAddress!, 1, &energy, vDSP_Length(count))
            for lag in 1..<alike.count {
                var sum: Float = 0
                if lag < count - 20 {
                    vDSP_dotpr(values.baseAddress! + lag, 1, values.baseAddress!, 1, &sum, vDSP_Length(count - lag))
                    sum *= Float(count) / Float(count - lag)
                }
                alike[lag] = sum
            }
        }
        // Silence, or sound with nothing arriving in it.
        guard energy > 1e-7 else {
            clarity = 0
            contrast = 0
            meter = 0
            return
        }
        func likeness(_ lag: Double) -> Double {
            let whole = Int(lag)
            guard whole >= 1, whole + 1 < alike.count, whole + 1 < count - 20 else { return 0 }
            let part = Float(lag - Double(whole))
            return Double((alike[whole] + (alike[whole + 1] - alike[whole]) * part) / energy)
        }
        // The tempos people tap most, around 110, unless the song's own is known; and a beat
        // is the one whose half, double and bar repeat too, so a dancehall's three-three-two
        // or a hat's eighths don't pass for it.
        let centre = tempoHint.flatMap { $0.isFinite && $0 > 30 ? $0 : nil } ?? 110
        let width = tempoHint == nil ? 0.9 : 0.4
        func score(_ lag: Double) -> Double {
            let tempo = 60 * Self.rate / lag
            let prior = exp(-0.5 * pow(log2(tempo / centre) / width, 2))
            let bar = 4 * lag < Double(count - 21) ? likeness(4 * lag) : likeness(2 * lag)
            return prior * (likeness(lag) + 0.25 * likeness(2 * lag) + 0.75 * bar + 0.5 * max(0, likeness(lag / 2)))
        }
        var best: (score: Double, lag: Double)?
        for lag in stride(from: Double(Self.lags.lowerBound), through: Double(Self.lags.upperBound), by: 0.5) {
            let found = score(lag)
            if found > best?.score ?? -.infinity { best = (found, lag) }
        }
        guard let best else { return }
        // Between whole moments, where it peaks.
        let (before, at, after) = (score(best.lag - 0.5), best.score, score(best.lag + 0.5))
        let curve = before - 2 * at + after
        let shift = curve < 0 ? min(0.5, max(-0.5, 0.5 * (before - after) / curve)) * 0.5 : 0
        let lag = best.lag + shift
        clarity = Self.unit(likeness(lag))
        meter = 4 * lag < Double(count - 21) ? likeness(4 * lag) : likeness(2 * lag)
        // Near enough each, since a rival's own peak needn't fall exactly there.
        rivalTempo = [2.0 / 3, 1.5, 0.75, 4.0 / 3].map { ratio in
            stride(from: lag * ratio - 1, through: lag * ratio + 1, by: 0.5).map { rival in
                Double(Self.lags.lowerBound)...Double(Self.lags.upperBound) ~= rival ? score(rival) : 0
            }.max() ?? 0
        }.max().map { $0 / max(best.score, 1e-9) } ?? 0
        adopt(period: lag / Self.rate)
        place()
    }

    /// 45 to 200 beats a minute, in moments a beat.
    private static let lags = 9...40

    /// Takes a tempo found: eased toward when it's close; a different one only once it's been
    /// found a few times running, so a stray estimate or a fill doesn't throw the beat off.
    private mutating func adopt(period found: Double) {
        guard found.isFinite, found > 0 else { return }
        guard let period else {
            self.period = found
            isAcquiring = true
            return
        }
        let ratio = found / period
        let isSure = sureness > 0.4
        if abs(ratio - 1) < 0.04 {
            // The clock's own slewing keeps it more exactly than whole moments can.
            self.period = period + (found - period) * (isSure ? 0.05 : 0.3)
            candidate = nil
            return
        }
        if let candidate, abs(found / candidate - 1) < 0.04 {
            candidateCount += 1
        } else {
            candidate = found
            candidateCount = 1
        }
        // Sure of a beat, twice or half it, or a three against two, takes two seconds running.
        let isRelated = [2.0, 0.5, 1.5, 2.0 / 3].contains { abs(ratio / $0 - 1) < 0.04 }
        if candidateCount >= (!isSure ? 2 : isRelated ? 8 : 4) {
            self.period = found
            candidate = nil
            isAcquiring = true
        }
    }

    /// Offsets of the clock's grid tried, across a whole beat.
    private static let offsets = 40

    /// Lays the last few beats' arrivals over the clock's grid at every offset across a beat,
    /// each arrival blurred by a few milliseconds and the newest counting most. Where they
    /// pile up is where the beat is. Found afresh, the clock is set there; sure, it's slewed
    /// toward the nearest pile, half the way each time.
    private mutating func place() {
        guard let period, knownBeats == nil else { return }
        let blur = 0.03 / period
        for index in grid.indices { grid[index] = 0 }
        for index in 0..<min(filled, Self.length) {
            let weight = Double(envelope[index])
            let age = clock - times[index]
            guard weight > 1e-4, age.isFinite, age < 8 else { continue }
            let recency = exp(-age / 4)
            // Where the clock was as it arrived.
            let at = beat - (age + Self.onsetDelay) / period
            for offset in 0..<Self.offsets {
                let x = at - (Double(offset) / Double(Self.offsets) - 0.5)
                let distance = (x - x.rounded()) / blur
                grid[offset] += weight * recency * exp(-0.5 * distance * distance)
            }
        }
        let mean = grid.reduce(0, +) / Double(Self.offsets)
        guard mean > 1e-6 else {
            contrast = 0
            rivalPlace = 0
            return
        }
        func offset(_ index: Int) -> Double { Double(index) / Double(Self.offsets) - 0.5 }
        func refined(_ index: Int) -> Double {
            let (a, b, c) = (grid[(index + Self.offsets - 1) % Self.offsets], grid[index], grid[(index + 1) % Self.offsets])
            let curve = a - 2 * b + c
            let shift = curve < 0 ? min(0.5, max(-0.5, 0.5 * (a - c) / curve)) : 0
            return offset(index) + shift / Double(Self.offsets)
        }
        let strongest = grid.indices.max { grid[$0] < grid[$1] } ?? 0
        // The strongest pile elsewhere in the beat, against this one.
        rivalPlace = grid.indices.filter { index in
            let apart = abs(index - strongest)
            let isPeak = grid[index] >= grid[(index + 1) % Self.offsets] && grid[index] >= grid[(index + Self.offsets - 1) % Self.offsets]
            return isPeak && min(apart, Self.offsets - apart) > Self.offsets / 6
        }.map { grid[$0] / grid[strongest] }.max() ?? 0
        // Near where the clock already is, leaning toward no change at all.
        let nearest = grid.indices.filter { abs(offset($0)) <= 0.25 }.max {
            grid[$0] * exp(-0.5 * pow(offset($0) / 0.15, 2)) < grid[$1] * exp(-0.5 * pow(offset($1) / 0.15, 2))
        } ?? Self.offsets / 2

        if isAcquiring || sureness < 0.25 {
            let found = refined(strongest)
            beat -= found
            correction = 0
            flips = 0
            contrast = grid[strongest] / mean
            if isAcquiring || abs(found) > 0.1 {
                // Counted afresh: which beat of four was which is learned again.
                slotLanded = [Double](repeating: 0, count: 4)
                slotDownbeat = [Double](repeating: 0, count: 4)
            }
            isAcquiring = false
            return
        }
        contrast = grid[nearest] / mean
        // Landing half a beat away for a second and a half: the clock had the offbeat.
        if grid[strongest] > 1.35 * grid[nearest], abs(offset(strongest)) > 0.3 {
            flips += 1
            if flips >= 6 {
                correction = -refined(strongest)
                flips = 0
                return
            }
        } else {
            flips = 0
        }
        guard contrast > 1.4 else { return }
        let error = refined(nearest)
        // Missing by a good part of a beat for most of a second: the music changed under it,
        // a new tempo or a new place. It stops pulsing at once and finds the beat afresh.
        misses = abs(error) > 0.12 ? misses + 1 : 0
        if misses >= 3 {
            misses = 0
            sureness *= 0.3
            isAcquiring = true
            return
        }
        correction = -0.5 * error
        // Landing late each time, the clock runs fast: a little slower.
        self.period = min(60.0 / 45, max(60.0 / 200, period * (1 + 0.04 * error)))
    }

    /// Once a beat's moment is in, how hard it landed, and how much it sounded like a downbeat:
    /// a kick, a chord changing, no snare.
    private mutating func judge() {
        guard let due = judging, clock >= due.due else { return }
        judging = nil
        var strongest: Float = 0, low: Float = 0, mid: Float = 0
        let from = due.at + Self.onsetDelay - 0.05, to = due.at + Self.onsetDelay + 0.1
        for index in 0..<min(filled, Self.length) where times[index] >= from && times[index] <= to {
            strongest = max(strongest, alls[index])
            low = max(low, lows[index])
            mid = max(mid, mids[index])
        }
        landed += (Double(strongest) - landed) * 0.35
        slotLanded[due.slot] += (Double(strongest) - slotLanded[due.slot]) * 0.3
        var change: Float = 0
        if beatBands.count == heldBands.count, !heldBands.isEmpty {
            change = zip(heldBands, beatBands).reduce(0) { $0 + abs($1.0 - $1.1) } / Float(heldBands.count)
        }
        beatBands = heldBands
        let downbeatness = Double(low + 0.6 * change - 0.4 * mid)
        slotDownbeat[due.slot] += (downbeatness - slotDownbeat[due.slot]) * 0.2
    }

    private static func strongest(_ slots: [Double]) -> Int {
        slots.indices.max { slots[$0] < slots[$1] } ?? 0
    }

    private static func downbeatSureness(_ slots: [Double]) -> Double {
        let sorted = slots.sorted(by: >)
        guard let top = sorted.first, top > 1e-4 else { return 0 }
        return smoothstep(0.1, 0.35, (top - sorted[1]) / top)
    }

    private static func ease(_ value: Double, toward goal: Double, elapsed: Double, rise: Double, fall: Double) -> Double {
        value + (goal - value) * (1 - exp(-elapsed / (goal > value ? rise : fall)))
    }

    static func smoothstep(_ low: Double, _ high: Double, _ value: Double) -> Double {
        let x = unit((value - low) / (high - low))
        return x * x * (3 - 2 * x)
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}
