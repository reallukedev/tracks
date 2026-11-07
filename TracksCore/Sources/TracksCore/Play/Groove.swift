import Foundation

/// The feel of a song, learned from a short stretch of it: how fast it goes, where in a bar its
/// drums land, how its sound spreads from low notes to high, and how hard it hits. Small enough
/// to keep for every song, and all a visualizer needs to keep time with a song it can't hear.
public nonisolated struct Groove: Codable, Equatable, Sendable {
    /// Sixteenths in a bar of four.
    public static let steps = 16

    /// Beats a minute.
    public var tempo: Double
    /// How sure the beat is, 0 to 1: a drum machine near 1, a rubato piano near 0.
    public var confidence: Double
    /// Where the kick lands.
    public var low: GrooveLane
    /// Where the snare and claps land.
    public var mid: GrooveLane
    /// Where the hats and cymbals land.
    public var high: GrooveLane
    /// How loud the song is on average in each band, 0 to 1, low notes to high.
    public var shape: [Float]
    /// How far its loud bars stand above its quiet ones, 0 to 1.
    public var dynamics: Double
    /// How hard its hits land, 0 to 1: a ballad's brushes low, a dance track's kick high.
    public var punch: Double
    /// Where its sound sits, 0 dark to 1 bright.
    public var brightness: Double
    /// How loud it is as a whole, in LUFS (see ``Loudness``): a dance master near -8, a quiet
    /// ballad near -16. Nil when unknown, and the drawing moves fully.
    public var loudness: Double?
    /// How far its loud passages stand above its quiet ones, in LU.
    public var loudnessRange: Double?
    /// How hard each beat landed, bar after bar, 0 to 1, the first of each four a downbeat.
    public var beats: [Float]?
    /// How loud each of those bars was, in LU above or below ``loudness``.
    public var bars: [Float]?
    /// The preview's own sound, to replay in time with the song (see ``GrooveTexture``).
    public var texture: GrooveTexture?
    /// Seconds into the song where the preview starts, when that could be found: the beat
    /// and the preview's sound then line up with the song exactly.
    public var songOffset: Double?

    public init(tempo: Double, confidence: Double, low: GrooveLane, mid: GrooveLane, high: GrooveLane, shape: [Float], dynamics: Double, punch: Double, brightness: Double, loudness: Double? = nil, loudnessRange: Double? = nil, beats: [Float]? = nil, bars: [Float]? = nil, texture: GrooveTexture? = nil) {
        self.tempo = tempo
        self.confidence = confidence
        self.low = low
        self.mid = mid
        self.high = high
        self.shape = shape
        self.dynamics = dynamics
        self.punch = punch
        self.brightness = brightness
        self.loudness = loudness
        self.loudnessRange = loudnessRange
        self.beats = beats
        self.bars = bars
        self.texture = texture
    }

    /// Beats counted `position` seconds into the song, the first of each four a downbeat, when
    /// where they fall is known: from the preview's first downbeat, where the preview sits in
    /// the song, at the song's own tempo. Nil when the preview couldn't be placed, or has no
    /// beat to keep.
    public func beats(at position: Double) -> Double? {
        guard let songOffset, let texture, texture.isPlayable, texture.chunkSeconds != GrooveTexture.freeChunk,
              position.isFinite, songOffset.isFinite else { return nil }
        return (position - songOffset - texture.start) / texture.chunkSeconds * 4
    }

    /// How strongly the song moves a drawing as a whole, 0 to 1, by how loud it is.
    public var intensity: Double { Loudness.intensity(lufs: loudness) }

    /// How surely a replay of the preview's sound lands on what's heard, 0 to 1. Placed in the
    /// song, exactly. Not placed, a steady beat still keeps the song's tempo from its start,
    /// close enough to show; with no beat to keep, its hits would fall anywhere, so they soften
    /// into swells instead.
    public var lock: Double {
        if songOffset != nil { return 1 }
        return confidence >= GrooveLevels.leastConfidence ? 0.85 : 0
    }

    /// How gently the song moves, 0 to 1: a soft, quietly mastered ballad near 1, anything that
    /// hits hard or is mastered loud near 0. A drawing glides for a gentle song and springs for
    /// the rest. Tempo has no say: a slow rap track hits as hard as any dance track.
    public var gentleness: Double {
        let soft = min(1, max(0, (0.6 - (punch.isFinite ? punch : 1)) / 0.45))
        let quiet = min(1, max(0, (0.95 - intensity) / 0.4))
        return soft * quiet
    }

    /// Nothing to keep time with: silence, or sound with no beat in it.
    public static let calm = Groove(
        tempo: 90, confidence: 0, low: .quiet, mid: .quiet, high: .quiet,
        shape: [Float](repeating: 0.35, count: 24), dynamics: 0, punch: 0, brightness: 0.5
    )

    /// A made-up groove, the same every time for the same `seed`, for sample songs that make
    /// no sound. A few of the bars drummers play most, at the tempos they're played.
    public static func sample(seed: String) -> Groove {
        var random = SeededRandom(seed)
        func lane(_ hits: [Int: Float]) -> GrooveLane {
            GrooveLane(hits: (0..<steps).map { hits[$0] ?? 0 }, lean: [Float](repeating: 0, count: steps))
        }
        let eighths: [Int: Float] = [0: 0.9, 2: 0.6, 4: 0.9, 6: 0.6, 8: 0.9, 10: 0.6, 12: 0.9, 14: 0.6]
        let sixteenths = Dictionary(uniqueKeysWithValues: (0..<steps).map { ($0, $0 % 2 == 0 ? Float(0.85) : 0.45) })
        var groove: Groove
        switch random.next() % 4 {
        case 0:
            // Four on the floor.
            groove = Groove(
                tempo: 118 + Double(random.next() % 11), confidence: 0.9,
                low: lane([0: 1, 4: 1, 8: 1, 12: 1]), mid: lane([4: 0.9, 12: 0.9]),
                high: lane([2: 1, 6: 1, 10: 1, 14: 1, 0: 0.3, 4: 0.3, 8: 0.3, 12: 0.3]),
                shape: [], dynamics: 0.3, punch: 0.9, brightness: 0.6, loudness: -8
            )
        case 1:
            // A backbeat, as most pop and rock.
            groove = Groove(
                tempo: 96 + Double(random.next() % 34), confidence: 0.85,
                low: lane([0: 1, 8: 0.9, 10: 0.55]), mid: lane([4: 1, 12: 1]),
                high: lane(eighths), shape: [], dynamics: 0.45, punch: 0.7, brightness: 0.55, loudness: -10
            )
        case 2:
            // Hip-hop: a lazy kick, sixteenths on the hats, swung.
            groove = Groove(
                tempo: 84 + Double(random.next() % 14), confidence: 0.85,
                low: lane([0: 1, 3: 0.6, 10: 0.85]), mid: lane([4: 1, 12: 1]),
                high: lane(sixteenths), shape: [], dynamics: 0.35, punch: 0.8, brightness: 0.45, loudness: -9
            )
            for step in stride(from: 1, to: steps, by: 2) { groove.high.lean[step] = 0.22 }
        default:
            // Half time, as a ballad: one big snare a bar.
            groove = Groove(
                tempo: 68 + Double(random.next() % 16), confidence: 0.7,
                low: lane([0: 1, 10: 0.5]), mid: lane([8: 1]),
                high: lane(eighths), shape: [], dynamics: 0.6, punch: 0.4, brightness: 0.4, loudness: -15
            )
        }
        // Its bars count from the song's start: it's made up, so that's where they are.
        groove.songOffset = 0
        // Fuller low down, as music is, with a lift in the presence range.
        groove.shape = (0..<24).map { band in
            let place = Double(band) / 23
            return Float(0.75 - 0.4 * place + 0.12 * exp(-pow((place - 0.65) / 0.15, 2)))
        }
        return groove
    }
}

/// One drum's place in a bar: how hard each sixteenth hits, and how early or late it lands.
public nonisolated struct GrooveLane: Codable, Equatable, Sendable {
    /// How hard each sixteenth hits, 0 to 1.
    public var hits: [Float]
    /// How early or late each lands, in sixteenths, -0.5 to 0.5. Swing pushes the off-beats late.
    public var lean: [Float]

    public init(hits: [Float], lean: [Float]) {
        self.hits = hits
        self.lean = lean
    }

    public static let quiet = GrooveLane(hits: [Float](repeating: 0, count: Groove.steps), lean: [Float](repeating: 0, count: Groove.steps))
}

/// Bands for a song Tracks can't hear, played back from what it learned of the song's feel
/// (see ``Groove``) in time with where the song is.
///
/// What carries it is the beat: a hit on every beat, up at once and falling away over most of
/// it, the first of each bar the hardest, so the tempo reads at a glance. The song's own kicks
/// between the beats, its snare and its hats sit lighter on top.
///
/// How much it all moves follows how loud the song is: a quiet ballad pulses gently, a loud
/// dance track hits hard. Bar by bar it follows the preview's own rise and fall, each beat as
/// hard as the one heard there, played forward and back across the song so it never jumps;
/// and it eases in over the song's first seconds and out over its last, which the preview
/// didn't hear. A groove without these swells and settles over each eight-bar phrase instead.
///
/// The beat grid starts at the song's first moment, where most studio recordings' first
/// downbeat is, and stays there: the analysis hears a stretch from the middle of the song, so
/// it knows the tempo to a hundredth of a beat a minute but not where the song's own beats
/// fall. It keeps time; it may sit a little ahead or behind, the same all the way through.
public nonisolated enum GrooveLevels {
    /// How each drum is sounding at a moment, 0 to 1.
    public struct Hits: Equatable, Sendable {
        /// The beat, or a kick between beats, whichever is louder.
        public var kick: Float
        public var snare: Float
        public var hat: Float
        /// The slow rise and fall over a phrase, 0 to 1.
        public var swell: Float
        /// Bars into the song, for slow motion that keeps time with it.
        public var bars: Double
        /// How strongly the song moves at this moment, 0 to a little over 1: its loudness,
        /// the loudness of this bar, and the ease in and out at its ends.
        public var strength: Float = 1
    }

    /// Below this, a groove's beat is too unsure to show; better a calm breath than a wrong beat.
    public static let leastConfidence = 0.2

    /// Seconds over which a song eases in at its start and out at its end.
    public static let ends = 10.0

    /// `duration`, when known, lets the song ease in over its first seconds and out over its last.
    public static func hits(playbackTime: Double, groove: Groove, duration: Double? = nil) -> Hits {
        let time = playbackTime.isFinite ? min(max(0, playbackTime), 86_400) : 0
        let tempo = groove.tempo.isFinite ? min(240, max(40, groove.tempo)) : 90
        let beat = 60 / tempo
        let step = beat / 4
        let punch = Float(min(1, max(0, groove.punch)))
        let certainty = Float(0.55 + 0.45 * min(1, max(0, groove.confidence)))
        let heard = Heard(groove)

        // The beat: a ballad's blooms and fades, a dance track's is short and hard.
        let fade = min(0.4, max(0.1, beat * Double(0.32 + 0.2 * (1 - punch))))
        let current = Int(time / beat)
        var pulse: Float = 0
        for index in max(0, current - 1)...current {
            let age = time - Double(index) * beat
            let accent = heard.map { $0.accent(beat: index) } ?? accent(beatInBar: index % 4, groove: groove)
            pulse = max(pulse, accent * envelope(age: age, rise: 0.012, fade: fade))
        }
        // The song's own drums, lighter. Only kicks off the beat, since the beat has the rest.
        let between = lane(groove.low, at: time, step: step, fade: min(0.25, max(0.07, beat * 0.22)), only: { $0 % 4 != 0 })
        let snare = lane(groove.mid, at: time, step: step, fade: min(0.3, max(0.08, beat * 0.28)), only: { _ in true })
        // Hats on the eighths only: sixteenths at full speed read as flicker, not rhythm.
        let hat = lane(groove.high, at: time, step: step, fade: min(0.12, max(0.05, step * 0.9)), only: { $0 % 2 == 0 })

        let bars = time / (beat * 4)
        let swell: Float
        let loudness = Float(groove.intensity) * ease(time: time, duration: duration)
        // The preview's own bars, eased from one to the next so a bar never jumps. Each beat
        // already carries how loud it was, so the bar's loudness goes on the rest.
        let bar = heard?.gain(bars: bars) ?? 1
        if heard != nil {
            swell = 1
        } else {
            // Louder toward the middle of each eight-bar phrase, by as much as the song moves.
            swell = 1 - Float(min(1, max(0, groove.dynamics))) * 0.4 * Float(0.5 + 0.5 * cos(2 * .pi * bars / 8))
        }
        return Hits(
            kick: max(pulse, between * 0.7 * bar) * certainty * loudness,
            snare: snare * 0.75 * certainty * loudness * bar,
            hat: hat * 0.45 * certainty * loudness * bar,
            swell: swell,
            bars: bars,
            strength: loudness * bar
        )
    }

    public static func levels(playbackTime: Double, groove: Groove, count: Int, duration: Double? = nil) -> [Float] {
        levels(hits: hits(playbackTime: playbackTime, groove: groove, duration: duration), groove: groove, count: count)
    }

    /// From 0.4 to full over the song's first ``ends`` seconds, and back over its last, since
    /// most songs build in and fade out and the preview heard neither. Full for a song of no
    /// known length, such as a live stream, or one too short to have ends.
    public static func ease(time: Double, duration: Double?) -> Float {
        guard let duration, duration.isFinite, duration > ends * 3 else { return 1 }
        func rise(_ seconds: Double) -> Float {
            let x = min(1, max(0, seconds / ends))
            return Float(0.4 + 0.6 * x * x * (3 - 2 * x))
        }
        return min(rise(time), rise(duration - time))
    }

    /// What the preview heard bar by bar, played forward and back across the song.
    private struct Heard {
        let beats: [Float]
        let bars: [Float]

        init?(_ groove: Groove) {
            guard let beats = groove.beats, let bars = groove.bars, bars.count >= 2, beats.count >= bars.count * 4 else { return nil }
            self.beats = beats
            self.bars = bars
        }

        /// The preview's bar for the song's `bar`: forward, then back, then forward again.
        func bar(_ bar: Int) -> Int {
            let cycle = 2 * (bars.count - 1)
            let place = bar % cycle
            return place < bars.count ? place : cycle - place
        }

        /// How hard the song's `beat` lands: as hard as the beat heard there, the first of the
        /// bar a little harder, and never so faint it can't be seen.
        func accent(beat: Int) -> Float {
            let inBar = beat % 4
            let heard = beats[bar(beat / 4) * 4 + inBar]
            let lift: Float = inBar == 0 ? 1 : inBar == 2 ? 0.92 : 0.86
            return (0.2 + 0.8 * min(1, max(0, heard))) * lift
        }

        /// The loudness of the bar the song is in, eased toward the next over its last beat.
        func gain(bars position: Double) -> Float {
            let current = Int(position)
            let through = position - Double(current)
            let blend = Float(max(0, (through - 0.75) / 0.25))
            let here = bars[bar(current)], next = bars[bar(current + 1)]
            let lu = here + (next - here) * blend * blend * (3 - 2 * blend)
            return Float(Loudness.gain(relative: Double(lu)))
        }
    }

    /// Each band: the song's own shape held as a body, and the drums on top of it, the beat
    /// in the low and middle bands, the snare in the middle, the hats up high.
    public static func levels(hits: Hits, groove: Groove, count: Int) -> [Float] {
        guard count > 0 else { return [] }
        let reach = Float(0.6 + 0.35 * min(1, max(0, groove.punch)))
        return (0..<count).map { band in
            let place = count > 1 ? Float(band) / Float(count - 1) : 0
            let shape = sample(groove.shape, at: place)
            // A slow ripple across the held sound, two bars to cross, so it isn't still between
            // hits and never moves faster than the music does.
            let ripple = 0.95 + 0.05 * Float(sin(2 * .pi * (hits.bars / 2 - Double(place))))
            // The held sound follows the song's loudness less than its drums do, as a meter's
            // body sits steadier than its peaks. Silence leaves only a hairline.
            let held = pow(max(0, hits.strength), 0.8)
            let body = (0.04 + 0.06 * min(1, held) + 0.34 * shape * hits.swell * held) * ripple
            let drums = hits.kick * (bell(place, 0.08, 0.2) + 0.45 * bell(place, 0.38, 0.22))
                + hits.snare * (0.8 * bell(place, 0.45, 0.2) + 0.25 * bell(place, 0.2, 0.08))
                + hits.hat * bell(place, 0.87, 0.14)
            let level = body + drums * reach * (0.6 + 0.4 * shape) * hits.swell * (1 - body * 0.4)
            return min(1, max(0, level.isFinite ? level : 0))
        }
    }

    /// How hard a beat lands by where it is in the bar: the first hardest, the third next, and
    /// harder still where the song's own kick or snare is.
    private static func accent(beatInBar: Int, groove: Groove) -> Float {
        let base: Float = switch beatInBar {
        case 0: 1
        case 2: 0.78
        default: 0.62
        }
        let step = beatInBar * 4
        let drums = max(groove.low.hits[safe: step] ?? 0, groove.mid.hits[safe: step] ?? 0)
        return base * (0.82 + 0.18 * min(1, max(0, drums)))
    }

    /// A hit `age` seconds ago: up over `rise`, then falling away by `fade`.
    private static func envelope(age: Double, rise: Double, fade: Double) -> Float {
        guard age >= 0 else { return 0 }
        let up = min(1, age / rise)
        return Float(up * up * (3 - 2 * up) * exp(-max(0, age - rise) / fade))
    }

    /// The strongest hit still sounding in `lane` at `time`, of the steps `only` allows.
    private static func lane(_ lane: GrooveLane, at time: Double, step: Double, fade: Double, only: (Int) -> Bool) -> Float {
        guard lane.hits.count == Groove.steps, lane.lean.count == Groove.steps, step > 0 else { return 0 }
        let current = Int(time / step)
        var strongest: Float = 0
        // The next step too, for a hit that leans early.
        for index in stride(from: current + 1, through: max(0, current - 8), by: -1) {
            let place = index % Groove.steps
            let strength = lane.hits[place]
            // Faint hits are as likely the analysis hearing the music between drums.
            guard strength > 0.3, only(place) else { continue }
            let age = time - (Double(index) + Double(lane.lean[place])) * step
            strongest = max(strongest, strength * envelope(age: age, rise: 0.01, fade: fade))
        }
        return strongest
    }

    private static func bell(_ place: Float, _ centre: Float, _ width: Float) -> Float {
        let distance = (place - centre) / width
        return exp(-distance * distance)
    }

    /// `values` at `place`, 0 to 1 across them, eased between neighbours.
    static func sample(_ values: [Float], at place: Float) -> Float {
        guard values.count > 1 else { return values.first ?? 0.4 }
        let position = min(1, max(0, place)) * Float(values.count - 1)
        let index = min(values.count - 2, Int(position))
        let fraction = position - Float(index)
        return values[index] + (values[index + 1] - values[index]) * fraction
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Where a song is, smoothly, from a player that reports it in steps. Follows small wobbles
/// gently, so the beat doesn't stutter, and jumps with a seek.
public nonisolated struct PlaybackClock: Equatable, Sendable {
    /// The song's time less the clock's, as it's been following it.
    private var offset: Double?

    public init() {}

    public mutating func position(reported: Double, at now: Double, isPlaying: Bool) -> Double {
        guard reported.isFinite, now.isFinite else { return 0 }
        let target = reported - now
        guard isPlaying, let current = offset, abs(target - current) < 0.2 else {
            offset = target
            return reported
        }
        let eased = current + (target - current) * 0.05
        offset = eased
        return now + eased
    }

    /// Where the song is now, carried on from the last report, for the moments between them.
    public func position(at now: Double) -> Double? {
        offset.map { now + $0 }
    }
}

/// The caps over a meter's bars: up with a bar at once, a moment's hang, then a fall that
/// gathers speed, as a hardware meter's do.
public nonisolated struct PeakCaps: Equatable, Sendable {
    public private(set) var peaks: [Float] = []
    private var holds: [Double] = []
    private var speeds: [Float] = []
    /// Seconds a cap hangs before it falls.
    public var hold: Double = 0.35
    /// Heights a second, a second, that a falling cap gathers.
    public var gravity: Float = 3

    public init() {}

    @discardableResult
    public mutating func step(_ levels: [Float], elapsed: Double) -> [Float] {
        let elapsed = min(max(elapsed, 0), 0.25)
        if peaks.count != levels.count {
            peaks = levels
            holds = [Double](repeating: hold, count: levels.count)
            speeds = [Float](repeating: 0, count: levels.count)
            return peaks
        }
        for index in levels.indices {
            let level = levels[index]
            if level >= peaks[index] {
                peaks[index] = level
                holds[index] = hold
                speeds[index] = 0
            } else if holds[index] > 0 {
                holds[index] -= elapsed
            } else {
                speeds[index] += gravity * Float(elapsed)
                peaks[index] = max(level, peaks[index] - speeds[index] * Float(elapsed))
            }
        }
        return peaks
    }
}

/// The same numbers every time for the same words, unlike `hashValue`.
nonisolated struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(_ seed: String) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        state = hash
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xbf58_476d_1ce4_e5b9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94d0_49bb_1331_11eb
        return mixed ^ (mixed >> 31)
    }
}
