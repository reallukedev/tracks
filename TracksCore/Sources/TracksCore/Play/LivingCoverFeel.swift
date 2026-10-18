import Foundation

/// How Living Cover feels the music: several qualities of the sound, each answering a
/// different part of it at its own pace, so the cover moves the way the song feels rather
/// than metering it.
///
/// - The flow keeps the music's tempo. It runs at the song's own pace, faster as the music
///   gets louder and busier, so a chorus visibly speeds up, a quiet verse slows to a drift and
///   a breakdown glides down. Each kick surges it forward and it coasts between them. Each of
///   the cover's three layers turns slowly on a clock of its own, leaning on its part of the
///   sound: the deep one on the bass, the middle one on the mids, the top one on the highs. A
///   bass-heavy track rolls the deep layer a little more, a bright one the top, but none ever
///   spins: the flow carries the tempo. No clock ever runs backwards.
/// - A lift, when the music jumps from a quieter stretch to a loud one, a drop or a chorus
///   arriving: for a second or two the cover opens out, loosens and grows richer, then
///   settles. Only a rise well beyond the song's usual ups counts, so a new chord doesn't.
/// - The bass is a slow swell, the cover leaning in as the low end rises above where it's
///   been and easing back as it falls: a ballad's chords bloom, a dance track's drop surges.
///   It follows the bass's rise and fall rather than its level, since the sound is heard
///   evened out, a quiet song as full as a loud one (see `AudioLevelMeter`).
/// - The kick is a soft push outward from the middle, quick to land and slower to settle: a
///   short one for a punchy dance track, a long, gentle one for a ballad's soft drum.
/// - A gentle song (see `Groove.gentleness`, or `BeatFollower` for music that's heard) glides
///   and breathes: everything eases more slowly, its stir swings slower and its kicks don't
///   surge the flow. The kick's surge, the stir and the glints also only go as far as the
///   song's hits surely land where they're drawn (see `Groove.lock`): always, for sound that's
///   heard; for a replay, as surely as it's placed in the song. So the cover never lurches at a
///   moment that isn't in the song.
/// - With a sure beat, the cover sways to and fro once a bar, in time with the song, as far as
///   the beat is sure, and in the song's fuller parts.
/// - What's new in the middle of the sound, a snare, a clap, stirs the colours round, as a
///   spoon does ink in water, and unwinds.
/// - What's new up high, the hats and cymbals, glints in the highlights.
/// - How loud the music is gives the colours their richness and depth: how loud the song is
///   mastered, and how much louder or softer than usual this part is, gathering over a second
///   or so and letting go over a couple more, so a chorus deepens and a verse softens.
/// - How busy it is churns the flow: a crowded mix folds the colours more than a sparse one.
/// - Still music, a ballad or a quiet passage, breathes: slowly, every seven seconds or so,
///   and with the music's own swells, filling as a phrase grows and emptying as it fades.
/// - The song's brightness warms or cools the highlights, slowly: amber for a dark, mellow
///   song, a cooler air for a bright one.
///
/// Paused, everything glides home at one gentle pace and comes to rest, the flow included,
/// so the drawing can stop. It keeps the same pace whatever the frame rate.
public nonisolated struct LivingCoverFeel: Equatable, Sendable {
    /// What's known of the song as a whole, for how it moves: from its groove, when learned.
    public struct Character: Equatable, Sendable {
        /// How hard its hits land, 0 to 1.
        public var punch: Double
        /// Where its sound sits, 0 dark to 1 bright.
        public var brightness: Double
        /// How strongly it moves as a whole, 0 to 1, by how loud it's mastered.
        public var intensity: Double
        /// How surely its hits land in time, 0 to 1: 1 for music that's heard, and for a replay
        /// placed in the song (see `Groove.lock`).
        public var lock: Double
        /// How gently it moves, 0 to 1: a slow, soft ballad near 1 (see `Groove.gentleness`).
        public var gentleness: Double
        /// How sure its beat is, 0 to 1, for what keeps time with the bar: hits can land where
        /// they're heard with no tempo found (see `BeatFollower`).
        public var sureness: Double

        public init(punch: Double, brightness: Double, intensity: Double, lock: Double = 1, gentleness: Double = 0.3, sureness: Double = 1) {
            self.punch = punch
            self.brightness = brightness
            self.intensity = intensity
            self.lock = lock
            self.gentleness = gentleness
            self.sureness = sureness
        }

        /// The song's groove, or a middling song while it isn't known. `isHeard` when the
        /// sound itself is heard, so its hits land where they are.
        public init(groove: Groove?, isHeard: Bool = false) {
            guard let groove else {
                self = .unknown
                if !isHeard { lock = 0 }
                return
            }
            self.init(punch: groove.punch, brightness: groove.brightness, intensity: groove.intensity, lock: isHeard ? 1 : groove.lock, gentleness: groove.gentleness)
        }

        public static let unknown = Character(punch: 0.6, brightness: 0.5, intensity: 0.75)

        /// How much its hits may push the cover about: only as much as they surely land in
        /// time, and less for a gentle song, which glides instead.
        var emphasis: Double { lock * (1 - gentleness) }

        fileprivate var clamped: Character {
            Character(
                punch: unit(punch, otherwise: 0.6),
                brightness: unit(brightness, otherwise: 0.5),
                intensity: unit(intensity, otherwise: 0.75),
                lock: unit(lock, otherwise: 0),
                gentleness: unit(gentleness, otherwise: 0.3),
                sureness: unit(sureness, otherwise: 0)
            )
        }
    }

    /// One moment of the feel, every part bounded.
    public struct Frame: Equatable, Sendable {
        /// The bass's swell, 0 to 1.
        public var swell = 0.0
        /// The kick's push, 0 to 1.
        public var thump = 0.0
        /// The stir, -1 to 1: which way and how far the colours are turned.
        public var twist = 0.0
        /// The glint in the highlights, 0 to 1.
        public var shimmer = 0.0
        /// Richness and depth, 0 to 1.
        public var body = 0.0
        /// How much the flow folds, 0 to 1.
        public var churn = 0.0
        /// A quiet passage's breath, -1 to 1: out and in, still when the music isn't quiet.
        public var breath = 0.0
        /// The highlights' warmth, -1 cool to 1 warm.
        public var warmth = 0.0
        /// A lift's bloom, 0 to 1: up as the music jumps to loud, then settling.
        public var lift = 0.0
        /// Where the flow is, in seconds of flow, never going back.
        public var flow = 0.0
        /// Where each layer's turn is, driven by the bass, the mids and the highs, in seconds of
        /// turning, never going back.
        public var deep = 0.0
        public var middle = 0.0
        public var top = 0.0
        /// How fast the flow is going, kick surge and all: seconds of flow a second.
        public var speed = 0.0

        public init() {}

        public static let rest = Frame()
    }

    /// Each part's pace, in seconds to cover two thirds of the way: quick where the ear hears
    /// an attack, slow where it hears a mood.
    enum Pace {
        static let swell = (rise: 0.25, fall: 0.9)
        /// How many times more slowly a gentle song with no sure beat swells.
        static let swellGlide = 4.0
        static let thumpRise = 0.03
        /// A kick's push lets go this quickly for the punchiest song, and up to `thumpSoftness`
        /// more slowly for the gentlest.
        static let thumpFall = 0.16
        static let thumpSoftness = 0.34
        static let shimmer = (rise: 0.05, fall: 0.3)
        static let body = (rise: 0.8, fall: 2.0)
        static let churn = (rise: 1.5, fall: 3.0)
        static let calm = (rise: 2.5, fall: 1.2)
        static let warmth = 3.0
        /// How long what's new in the middle and the highs takes to become old.
        /// Only a sharp attack up high is new for long enough to glint: a hat, not a held note.
        static let fresh = (mids: 0.35, highs: 0.12)
        /// How long the bass and the whole sound take to become where they've been.
        static let usual = (bass: 3.0, all: 8.0)
        /// Paused, nothing lets go more slowly than this, so it all comes to rest together.
        static let rest = 0.8
        /// Seconds between a quiet passage's breaths.
        static let breath = 7.0
        /// The stir's spring: how long one swing takes, and how much each swing loses.
        static let swing = 2.6
        static let damping = (playing: 0.45, paused: 1.0)
        /// The flow speeds up quickly and slows down gently, so a breakdown glides.
        static let flow = (rise: 0.5, fall: 1.5)
        /// How long a kick's surge of speed takes to coast away.
        static let surge = 0.4
        /// How each layer's part of the sound is followed, so its turn changes speed smoothly.
        static let layers = 0.3
        /// How full the music is now and over the last few seconds, and how long the size of
        /// its usual rises takes to be forgotten.
        static let lift = (now: 0.3, recent: 4.0, usualRise: 20.0)
        /// A lift's bloom opens this quickly and settles this slowly.
        static let bloom = (rise: 0.15, fall: 0.7)
        /// Seconds after a lift before another can come.
        static let liftGap = 4.0
        /// How long the sway takes to come in with a sure beat, and to go with it.
        static let sway = (rise: 1.5, fall: 1.0)
        /// How a phrase's swell is followed, for a quiet passage's breath.
        static let phrase = (rise: 0.6, fall: 1.5)
    }

    public private(set) var frame = Frame.rest
    private var mids = 0.0
    private var usualBass: Double?
    private var usualAll: Double?
    private var highs = 0.0
    private var hasHeard = false
    /// The stir's place and speed.
    private(set) var stirred = 0.0
    private var spin = 0.0
    /// How far the sway reaches, and where in the bar it was last.
    private(set) var sway = 0.0
    private var swayBeats = 0.0
    private var phrase: Double?
    private var calm = 0.0
    private var breathPhase = 0.0
    private var hasWarmth = false
    /// The flow's speed before the kick's surge, and the surge on top.
    private var velocity = 0.0
    private var surge = 0.0
    /// Each layer's part of the sound, followed: the bass, the mids, the highs.
    private var layerLevels: [Double]?
    /// Loudness followed closely, and over the last few seconds.
    private var loudness: [Double]?
    /// How big the song's rises have lately been, so a song that thins and fills every few
    /// bars lifts once, not every time.
    private var usualRise = 0.0
    /// What a lift is opening toward, and how long since the last.
    private var bloom = 0.0
    private var sinceLift = Double.infinity
    /// Whether the music has been near where it usually is since the last lift, so one rise
    /// lifts once.
    private var isLiftArmed = true
    /// Seconds heard so far: a lift needs long enough to know where the music has been, so a
    /// song's first seconds, rising out of silence, don't lift.
    private var heardFor = 0.0

    public init() {}

    /// Steps on by `elapsed` seconds, with this moment of the music: its bands, 0 to 1 low to
    /// high, its kick, how busy it's been, the song's pace, about 1 at 120 beats a minute, and
    /// its beats counted, when there's a beat (see `StagePulse`).
    @discardableResult
    public mutating func step(bands: [Float], kick: Float, activity: Float, pace: Double = 1, beats: Double? = nil, isPlaying: Bool, character: Character = .unknown, elapsed: Double) -> Frame {
        let dt = elapsed.isFinite ? min(max(elapsed, 0), 0.25) : 0
        let song = character.clamped
        func mean(_ range: Range<Int>) -> Double {
            let range = range.clamped(to: 0..<bands.count)
            guard !range.isEmpty else { return 0 }
            return range.reduce(0) { $0 + unit(Double(bands[$1]), otherwise: 0) } / Double(range.count)
        }
        let bass = mean(0..<5), mid = mean(8..<16), high = mean(16..<24), all = mean(0..<bands.count)
        let kick = isPlaying ? unit(Double(kick), otherwise: 0) : 0
        let activity = isPlaying ? unit(Double(activity), otherwise: 0) : 0

        // What's new is measured against what came before, so the first moment isn't all new.
        if !hasHeard {
            (mids, highs, hasHeard) = (mid, high, true)
        }
        let midFresh = isPlaying ? max(0, mid - mids) : 0
        let highFresh = isPlaying ? max(0, high - highs) : 0
        mids = Self.ease(mids, toward: mid, elapsed: dt, rise: Pace.fresh.mids, fall: Pace.fresh.mids)
        highs = Self.ease(highs, toward: high, elapsed: dt, rise: Pace.fresh.highs, fall: Pace.fresh.highs)

        // A gentle song eases everything more slowly, gliding and breathing.
        let glide = 1 + song.gentleness
        func fall(_ seconds: Double) -> Double { isPlaying ? seconds * glide : min(seconds, Pace.rest) }
        var next = frame

        let usualBass = self.usualBass ?? bass, usualAll = self.usualAll ?? all
        if isPlaying {
            self.usualBass = Self.ease(usualBass, toward: bass, elapsed: dt, rise: Pace.usual.bass, fall: Pace.usual.bass)
            self.usualAll = Self.ease(usualAll, toward: all, elapsed: dt, rise: Pace.usual.all, fall: Pace.usual.all)
        }

        // With no sure beat, the swell follows the music's slow envelope, not each chord.
        let swell = isPlaying ? unit(0.35 + (bass - usualBass) * 2.5) * (0.6 + 0.4 * song.intensity) : 0
        let swellRise = Pace.swell.rise * (1 + Pace.swellGlide * (1 - song.emphasis) * song.gentleness)
        next.swell = Self.ease(frame.swell, toward: swell, elapsed: dt, rise: swellRise, fall: fall(Pace.swell.fall))

        // A heard kick seldom reaches past half way, so it's lifted to use the whole range.
        let thump = unit(kick * 1.6) * (0.4 + 0.6 * song.punch)
        next.thump = Self.ease(frame.thump, toward: thump, elapsed: dt, rise: Pace.thumpRise, fall: fall(Pace.thumpFall + Pace.thumpSoftness * (1 - song.punch)))

        // A ballad's piano glints less than a dance track's hats.
        let shimmer = isPlaying ? unit(highFresh * 4) * (0.25 + 0.75 * song.emphasis) : 0
        next.shimmer = Self.ease(frame.shimmer, toward: shimmer, elapsed: dt, rise: Pace.shimmer.rise, fall: fall(Pace.shimmer.fall))

        // How loud it's mastered sets the depth; louder than it's been, a chorus, deepens it.
        let body = isPlaying ? (0.35 + 0.65 * song.intensity) * unit(0.7 + (all - usualAll) * 2.5) : 0
        next.body = Self.ease(frame.body, toward: body, elapsed: dt, rise: Pace.body.rise, fall: fall(Pace.body.fall))

        let churn = isPlaying ? unit(0.75 * activity + 0.5 * mid) : 0
        next.churn = Self.ease(frame.churn, toward: churn, elapsed: dt, rise: Pace.churn.rise, fall: fall(Pace.churn.fall))

        // Still, not merely quiet: a busy verse mixed low doesn't breathe.
        let stillness = max(unit((0.4 - activity) / 0.3), unit((song.gentleness - 0.4) / 0.5))
        let hush = max(unit((0.24 - all) / 0.16), unit((usualAll - all) / max(usualAll, 0.05) * 2))
        // Silence, between songs or before one starts, doesn't breathe: there's nothing to feel.
        let audible = unit((all - 0.06) / 0.06)
        let quiet = isPlaying ? stillness * (0.6 + 0.4 * hush) * audible : 0
        calm = Self.ease(calm, toward: quiet, elapsed: dt, rise: Pace.calm.rise, fall: fall(Pace.calm.fall))
        breathPhase = (breathPhase + dt * 2 * .pi / Pace.breath).truncatingRemainder(dividingBy: 2 * .pi)
        // In with the phrase as it grows and out as it fades, over the slow breath.
        let phrase = Self.ease(self.phrase ?? all, toward: all, elapsed: dt, rise: Pace.phrase.rise, fall: Pace.phrase.fall)
        self.phrase = phrase
        let swelling = isPlaying ? (phrase - usualAll) * 2.5 : 0
        next.breath = calm < 0.0005 ? 0 : max(-1, min(1, 0.6 * sin(breathPhase) + swelling)) * calm

        let warmth = max(-1, min(1, (0.5 - song.brightness) * 2))
        next.warmth = hasWarmth ? Self.ease(frame.warmth, toward: warmth, elapsed: dt, rise: Pace.warmth, fall: Pace.warmth) : warmth
        hasWarmth = true

        stirred = stir(from: stirred, push: midFresh * 36 * song.emphasis, swing: Pace.swing * (1 + 0.6 * song.gentleness), isPlaying: isPlaying, elapsed: dt)
        // Once a bar, to one side and back, on the song's own beat: in its fuller parts, a
        // chorus or a drop, so it comes and goes with the song rather than rocking throughout.
        let fuller = unit((all - usualAll) * 8 + 0.1)
        let swaying = isPlaying && beats != nil ? 0.45 * song.emphasis * song.sureness * fuller : 0
        sway = Self.ease(sway, toward: swaying, elapsed: dt, rise: Pace.sway.rise, fall: min(Pace.sway.fall, fall(Pace.sway.fall)))
        if let beats, beats.isFinite { swayBeats = beats }
        next.twist = max(-1, min(1, stirred + sway * sin(2 * .pi * swayBeats / 4)))

        // How full the music is across the whole sound: a new chord moves the bass alone.
        next.lift = lift(fullness: all, gentleness: song.gentleness, isPlaying: isPlaying, elapsed: dt)
        flow(&next, pace: pace, activity: activity, bass: bass, mid: mid, high: high, kick: thump * song.emphasis, glide: glide, isPlaying: isPlaying, elapsed: dt)
        frame = next
        return next
    }

    /// The flow and the layers' turns, stepped on: the flow at the song's pace, quicker as the
    /// music is fuller and busier, surging on each kick; each layer at the flow's speed, more
    /// or less as its part of the sound is strong.
    private mutating func flow(_ next: inout Frame, pace: Double, activity: Double, bass: Double, mid: Double, high: Double, kick: Double, glide: Double, isPlaying: Bool, elapsed: Double) {
        let pace = pace.isFinite ? min(max(pace, 0), 3) : 1
        let goal = isPlaying ? pace * (0.3 + 0.8 * next.body + 0.5 * activity) : 0
        velocity = Self.ease(velocity, toward: goal, elapsed: elapsed, rise: Pace.flow.rise * glide, fall: isPlaying ? Pace.flow.fall * glide : Pace.rest)
        // Up at once on a kick, coasting away between them.
        surge = max(surge * exp(-elapsed / Pace.surge), isPlaying ? kick * 0.9 * pace : 0)

        let heard = [bass, mid, high]
        let follow = 1 - exp(-elapsed / Pace.layers)
        let layer = zip(layerLevels ?? heard, heard).map { $0 + ($1 - $0) * follow }
        layerLevels = layer
        // The layers only lean into the music's speed, so the cover drifts rather than spins:
        // the flow carries the tempo, the kick's surge and all.
        let lean = isPlaying ? 0.5 + 0.5 * velocity : velocity
        func turn(_ level: Double) -> Double { 0.3 + level * 1.4 }

        next.speed = velocity + surge
        next.flow = Self.wrapped(frame.flow + next.speed * elapsed)
        next.deep = Self.wrapped(frame.deep + lean * turn(layer[0]) * elapsed)
        next.middle = Self.wrapped(frame.middle + lean * turn(layer[1]) * elapsed)
        next.top = Self.wrapped(frame.top + lean * turn(layer[2]) * elapsed)
    }

    /// A lift: when the music, followed closely, rises well above the last few seconds, a
    /// breakdown before a drop or a verse before a chorus, the bloom opens as it rises, then
    /// settles, more softly for a gentle song. Steady music doesn't lift, however loud, and a
    /// rise no bigger than the song's usual ups doesn't either: a new chord, or a song that
    /// thins and fills every few bars.
    private mutating func lift(fullness all: Double, gentleness: Double, isPlaying: Bool, elapsed: Double) -> Double {
        sinceLift += elapsed
        if isPlaying {
            heardFor += elapsed
            let loud = loudness ?? [all, all]
            let now = Self.ease(loud[0], toward: all, elapsed: elapsed, rise: Pace.lift.now, fall: Pace.lift.now)
            let recent = Self.ease(loud[1], toward: all, elapsed: elapsed, rise: Pace.lift.recent, fall: Pace.lift.recent)
            loudness = [now, recent]
            let rise = now - recent
            if rise < 0.02 { isLiftArmed = true }
            // Not while it's still learning how full the song is, rising out of silence.
            let hasLearned = heardFor > Pace.lift.recent * 3
            if hasLearned {
                // Only rises count: falling into a breakdown is what makes the drop stand out.
                let squared = Self.ease(usualRise * usualRise, toward: pow(max(0, rise), 2), elapsed: elapsed, rise: Pace.lift.usualRise, fall: Pace.lift.usualRise)
                usualRise = squared.squareRoot()
            }
            if isLiftArmed, hasLearned, rise > max(0.1, 3 * usualRise), now > 0.2 {
                isLiftArmed = false
                if sinceLift > Pace.liftGap {
                    bloom = 1 - 0.5 * gentleness
                    sinceLift = 0
                }
            }
        }
        bloom *= exp(-elapsed / 0.8)
        if !isPlaying { bloom = 0 }
        return Self.ease(frame.lift, toward: bloom, elapsed: elapsed, rise: Pace.bloom.rise, fall: isPlaying ? Pace.bloom.fall : min(Pace.bloom.fall, Pace.rest))
    }

    /// A phase kept to a size a float holds exactly enough, wrapping rarely: every five and a
    /// half hours of flow.
    private static func wrapped(_ phase: Double) -> Double {
        phase.truncatingRemainder(dividingBy: 20_000)
    }

    /// Nothing left moving, so the drawing can stop.
    public var isAtRest: Bool {
        let moving = [frame.swell, frame.thump, frame.twist, spin * 0.3, sway, frame.shimmer, frame.body, frame.churn, frame.breath, calm, frame.lift, frame.speed]
        return moving.allSatisfy { abs($0) < 0.003 }
    }

    /// The stir: a spring that each push swings further the way it's already turning, and
    /// that pulls back to still. A push near the end of its swing does little, so it never
    /// winds up against the edge.
    private mutating func stir(from twist: Double, push: Double, swing: Double, isPlaying: Bool, elapsed: Double) -> Double {
        let stiffness = pow(2 * .pi / swing, 2)
        let damping = 2 * (isPlaying ? Pace.damping.playing : Pace.damping.paused) * stiffness.squareRoot()
        var twist = twist
        // In steps no longer than a sixtieth of a second, so it swings the same at any frame rate.
        let steps = max(1, Int((elapsed * 60).rounded(.up)))
        let dt = elapsed / Double(steps)
        for _ in 0..<steps {
            let direction: Double = spin >= 0 ? 1 : -1
            spin += (direction * push * (1 - abs(twist)) - stiffness * twist - damping * spin) * dt
            twist += spin * dt
            if abs(twist) > 1 {
                twist = twist > 0 ? 1 : -1
                spin = 0
            }
        }
        return twist
    }

    private static func ease(_ value: Double, toward goal: Double, elapsed: Double, rise: Double, fall: Double) -> Double {
        value + (goal - value) * (1 - exp(-elapsed / (goal > value ? rise : fall)))
    }
}

/// `value` kept from 0 to 1, and `otherwise` when it isn't a number.
private nonisolated func unit(_ value: Double, otherwise: Double = 0) -> Double {
    value.isFinite ? min(max(value, 0), 1) : otherwise
}
