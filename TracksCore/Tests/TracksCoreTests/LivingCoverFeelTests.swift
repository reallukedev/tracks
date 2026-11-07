import Testing
import Foundation
@testable import TracksCore

@Suite("Living Cover feel")
struct LivingCoverFeelTests {
    /// A made-up moment of music, as `SmoothedLevels` would give it.
    struct Moment: Sendable {
        var bass: Float
        var mid: Float
        var high: Float
        var kick: Float
        var activity: Float

        var bands: [Float] {
            (0..<24).map { band in band < 5 ? bass : band < 8 ? (bass + mid) / 2 : band < 16 ? mid : high }
        }
    }

    /// A song as it sounds over time.
    struct Song: Sendable {
        var character: LivingCoverFeel.Character
        /// About 1 at 120 beats a minute, as `SmoothedLevels` gives it.
        var pace = 1.0
        var moment: @Sendable (Double) -> Moment

        /// Four on the floor at 124: a hard kick every beat, claps on two and four, open hats
        /// on the off-beats, a loud master.
        static let dance = Song(character: .init(punch: 0.9, brightness: 0.6, intensity: 0.95, lock: 1, gentleness: 0.1), pace: 1.45) { time in
            let beat = 60.0 / 124
            let intoBeat = time.truncatingRemainder(dividingBy: beat)
            let kick = Float(exp(-intoBeat / 0.08))
            let beatIndex = Int(time / beat)
            let clap = beatIndex % 2 == 1 ? Float(exp(-intoBeat / 0.1)) : 0
            let intoHalf = (time + beat / 2).truncatingRemainder(dividingBy: beat)
            let hat = Float(exp(-intoHalf / 0.05))
            return Moment(bass: 0.35 + 0.45 * kick, mid: 0.3 + 0.4 * clap, high: 0.2 + 0.4 * hat, kick: kick, activity: 0.75)
        }

        /// Half time at 70: chords that bloom and fade, a soft drum once a bar, a quiet master,
        /// heard evened out as full as the dance track.
        static let ballad = Song(character: .init(punch: 0.35, brightness: 0.4, intensity: 0.4, lock: 1, gentleness: 0.8), pace: 0.55) { time in
            let bar = 4 * 60.0 / 70
            let intoBar = time.truncatingRemainder(dividingBy: bar)
            let kick = Float(0.15 * exp(-intoBar / 0.15))
            let chord = Float(exp(-intoBar / 2.2))
            return Moment(bass: 0.55 + 0.3 * chord, mid: 0.45 + 0.2 * chord, high: 0.15, kick: kick, activity: 0.12)
        }
    }

    /// Plays `song` for `seconds` at `fps`, and every frame from `from` on.
    func play(_ song: Song, seconds: Double, fps: Double = 30, from: Double = 0, feel: inout LivingCoverFeel) -> [LivingCoverFeel.Frame] {
        var frames: [LivingCoverFeel.Frame] = []
        let dt = 1 / fps
        for index in 0..<Int(seconds * fps) {
            let time = Double(index) * dt
            let moment = song.moment(time)
            let frame = feel.step(bands: moment.bands, kick: moment.kick, activity: moment.activity, pace: song.pace, isPlaying: true, character: song.character, elapsed: dt)
            if time >= from { frames.append(frame) }
        }
        return frames
    }

    func range(_ values: [Double]) -> Double { (values.max() ?? 0) - (values.min() ?? 0) }
    func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(max(1, values.count)) }

    @Test("A kick's push lands at once and lets go slowly; the bass swells more slowly still")
    func attackAndRelease() {
        var feel = LivingCoverFeel()
        let loud = Moment(bass: 0.8, mid: 0.2, high: 0.1, kick: 1, activity: 0.5)
        for _ in 0..<3 {
            feel.step(bands: loud.bands, kick: loud.kick, activity: loud.activity, isPlaying: true, elapsed: 1.0 / 60)
        }
        let landed = feel.frame
        #expect(landed.thump > 0.5)
        #expect(landed.swell < landed.thump / 2)

        let quiet = Moment(bass: 0.04, mid: 0.04, high: 0.04, kick: 0, activity: 0.5)
        for _ in 0..<6 {
            feel.step(bands: quiet.bands, kick: 0, activity: quiet.activity, isPlaying: true, elapsed: 1.0 / 60)
        }
        // A tenth of a second on, still most of the way there: it lets go, it doesn't drop.
        #expect(feel.frame.thump > landed.thump * 0.4)
        for _ in 0..<90 {
            feel.step(bands: quiet.bands, kick: 0, activity: quiet.activity, isPlaying: true, elapsed: 1.0 / 60)
        }
        #expect(feel.frame.thump < 0.02)
    }

    @Test("Paused, it glides home rather than stopping dead, and comes to rest")
    func pauseGlidesToRest() {
        var feel = LivingCoverFeel()
        _ = play(.dance, seconds: 6, feel: &feel)
        let playing = feel.frame
        #expect(!feel.isAtRest)

        let silence = [Float](repeating: 0.04, count: 24)
        for _ in 0..<6 {
            feel.step(bands: silence, kick: 0, activity: 0, isPlaying: false, elapsed: 1.0 / 30)
        }
        #expect(feel.frame.body > playing.body * 0.5)
        #expect(!feel.isAtRest)

        for _ in 0..<(30 * 6) {
            feel.step(bands: silence, kick: 0, activity: 0, isPlaying: false, elapsed: 1.0 / 30)
        }
        #expect(feel.isAtRest)
    }

    @Test("Every part stays in bounds, whatever comes in")
    func bounded() {
        var feel = LivingCoverFeel()
        let wild: [[Float]] = [
            [Float](repeating: 40, count: 24),
            [Float](repeating: -3, count: 24),
            [Float](repeating: .nan, count: 24),
            (0..<24).map { $0 % 2 == 0 ? 1 : 0 },
            [],
            [1, 1, 1],
        ]
        let character = LivingCoverFeel.Character(punch: .infinity, brightness: -5, intensity: .nan)
        for index in 0..<2_000 {
            let bands = wild[index % wild.count]
            let elapsed = [1.0 / 60, 0, 10, -1, .nan][index % 5]
            let frame = feel.step(bands: bands, kick: index % 3 == 0 ? 50 : .nan, activity: 9, isPlaying: index % 400 < 350, character: character, elapsed: elapsed)
            for part in [frame.swell, frame.thump, frame.shimmer, frame.body, frame.churn] {
                #expect(part.isFinite && part >= 0 && part <= 1)
            }
            for part in [frame.twist, frame.breath, frame.warmth] {
                #expect(part.isFinite && part >= -1 && part <= 1)
            }
        }
    }

    @Test("A dance track pulses and churns; a ballad drifts and breathes")
    func balladAndDanceFeelDifferent() {
        var danceFeel = LivingCoverFeel()
        var balladFeel = LivingCoverFeel()
        let dance = play(.dance, seconds: 20, from: 10, feel: &danceFeel)
        let ballad = play(.ballad, seconds: 20, from: 10, feel: &balladFeel)

        // The kick: a dance track's lands hard on every beat; a ballad's soft drum barely does.
        #expect(range(dance.map(\.thump)) > 0.5)
        #expect(range(ballad.map(\.thump)) < 0.15)
        // The ballad's chords bloom and fade in its swell; a loud master gives a deeper colour.
        #expect(range(ballad.map(\.swell)) > 0.15)
        #expect(mean(dance.map(\.body)) > mean(ballad.map(\.body)) + 0.2)
        // Busy and crowded churns the flow; the claps stir it to and fro, far more than a
        // ballad's chords do.
        #expect(mean(dance.map(\.churn)) > mean(ballad.map(\.churn)) + 0.3)
        #expect(range(dance.map(\.twist)) > 0.3)
        #expect(range(dance.map(\.twist)) > 2 * range(ballad.map(\.twist)))
        // The hats glint; a ballad's highs are still.
        #expect(range(dance.map(\.shimmer)) > 0.3)
        #expect(range(ballad.map(\.shimmer)) < 0.05)
        // Quiet and still, a ballad breathes deeply; a dance track never does.
        #expect(range(ballad.map(\.breath)) > 0.6)
        #expect(range(dance.map(\.breath)) < 0.02)
        // A steady beat, however hard, is no lift, and nor is a ballad's swell from bar to bar.
        #expect((dance.map(\.lift).max() ?? 1) < 0.05)
        #expect((ballad.map(\.lift).max() ?? 1) < 0.05)
        // A dark, mellow song's highlights warm; a brighter one's cool.
        #expect(ballad.last!.warmth > 0)
        #expect(dance.last!.warmth < 0)
    }

    @Test("It moves the same at any frame rate", arguments: [20.0, 60.0, 120.0])
    func frameRateIndependent(fps: Double) throws {
        var reference = LivingCoverFeel()
        var other = LivingCoverFeel()
        _ = play(.dance, seconds: 4.1, fps: 30, feel: &reference)
        _ = play(.dance, seconds: 4.1, fps: fps, feel: &other)
        let a = reference.frame, b = other.frame
        #expect(abs(a.swell - b.swell) < 0.08)
        #expect(abs(a.body - b.body) < 0.05)
        #expect(abs(a.churn - b.churn) < 0.05)
        #expect(abs(a.twist - b.twist) < 0.15)
    }

    /// Steps `feel` on with the same moment, `count` times at 30 frames a second.
    func hold(_ moment: Moment, count: Int, pace: Double = 1, isPlaying: Bool = true, character: LivingCoverFeel.Character = .unknown, feel: inout LivingCoverFeel) -> [LivingCoverFeel.Frame] {
        (0..<count).map { _ in
            feel.step(bands: moment.bands, kick: moment.kick, activity: moment.activity, pace: pace, isPlaying: isPlaying, character: character, elapsed: 1.0 / 30)
        }
    }

    @Test("The flow runs faster for loud, busy music than for quiet, still music at the same pace")
    func flowSpeedFollowsTheMusic() {
        var loudFeel = LivingCoverFeel()
        var quietFeel = LivingCoverFeel()
        let busy = Moment(bass: 0.6, mid: 0.6, high: 0.5, kick: 0, activity: 0.8)
        let still = Moment(bass: 0.3, mid: 0.25, high: 0.1, kick: 0, activity: 0.08)
        let loud = hold(busy, count: 150, character: .init(punch: 0.8, brightness: 0.5, intensity: 0.95), feel: &loudFeel)
        let quiet = hold(still, count: 150, character: .init(punch: 0.3, brightness: 0.5, intensity: 0.3), feel: &quietFeel)
        #expect(loud.last!.speed > 1.6 * quiet.last!.speed)

        // And between whole songs, a dance track's flow far outruns a ballad's.
        var danceFeel = LivingCoverFeel()
        var balladFeel = LivingCoverFeel()
        let dance = play(.dance, seconds: 12, from: 6, feel: &danceFeel)
        let ballad = play(.ballad, seconds: 12, from: 6, feel: &balladFeel)
        #expect(mean(dance.map(\.speed)) > 3 * mean(ballad.map(\.speed)))
    }

    @Test("A kick surges the flow forward, and the surge coasts away")
    func kickSurges() {
        var feel = LivingCoverFeel()
        let steady = Moment(bass: 0.5, mid: 0.4, high: 0.3, kick: 0, activity: 0.5)
        let cruising = hold(steady, count: 120, feel: &feel).last!.speed
        var kicked = steady
        kicked.kick = 1
        let surged = hold(kicked, count: 1, feel: &feel).last!.speed
        #expect(surged > cruising * 1.3)
        let shortly = hold(steady, count: 6, feel: &feel).last!.speed
        #expect(shortly < surged && shortly > cruising)
        let later = hold(steady, count: 60, feel: &feel).last!.speed
        #expect(abs(later - cruising) < cruising * 0.05)
    }

    @Test("No clock ever runs backwards, through playing, pausing and playing again")
    func phasesOnlyGoForward() {
        var feel = LivingCoverFeel()
        var frames = play(.dance, seconds: 6, feel: &feel)
        frames += hold(Moment(bass: 0.04, mid: 0.04, high: 0.04, kick: 0, activity: 0), count: 120, isPlaying: false, feel: &feel)
        frames += play(.ballad, seconds: 6, feel: &feel)
        for (before, after) in zip(frames, frames.dropFirst()) {
            #expect(after.flow >= before.flow)
            #expect(after.deep >= before.deep)
            #expect(after.middle >= before.middle)
            #expect(after.top >= before.top)
        }
        #expect(frames.last!.flow > frames.first!.flow)
    }

    @Test("Each layer turns with its own part of the sound")
    func layersFollowTheirBands() {
        var bassy = LivingCoverFeel()
        var bright = LivingCoverFeel()
        let low = hold(Moment(bass: 0.9, mid: 0.3, high: 0.05, kick: 0, activity: 0.4), count: 150, feel: &bassy).last!
        let high = hold(Moment(bass: 0.1, mid: 0.3, high: 0.9, kick: 0, activity: 0.4), count: 150, feel: &bright).last!
        #expect(low.deep > low.top * 1.5)
        #expect(high.top > high.deep * 1.5)
    }

    @Test("A lift blooms when the music jumps back to loud after a quieter stretch, not while it stays loud")
    func liftsOnlyOutOfQuiet() {
        let soft = Moment(bass: 0.15, mid: 0.12, high: 0.08, kick: 0, activity: 0.2)
        let loud = Moment(bass: 0.7, mid: 0.6, high: 0.5, kick: 0, activity: 0.6)

        // The song arriving out of silence, a while loud, a breakdown, and the drop.
        var dropping = LivingCoverFeel()
        _ = hold(Moment(bass: 0.04, mid: 0.04, high: 0.04, kick: 0, activity: 0), count: 15, feel: &dropping)
        _ = hold(loud, count: 450, feel: &dropping)
        _ = hold(soft, count: 120, feel: &dropping)
        let drop = hold(loud, count: 90, feel: &dropping)
        #expect((drop.map(\.lift).max() ?? 0) > 0.5)
        // It settles again within a few seconds.
        #expect(hold(loud, count: 120, feel: &dropping).last!.lift < 0.05)

        var steady = LivingCoverFeel()
        let held = hold(loud, count: 300, feel: &steady)
        #expect((held.map(\.lift).max() ?? 0) < 0.05)

        // A song that thins and fills every couple of bars has nothing rare about it.
        var swaying = LivingCoverFeel()
        var swayed: [LivingCoverFeel.Frame] = []
        for _ in 0..<8 {
            swayed += hold(loud, count: 105, feel: &swaying)
            swayed += hold(soft, count: 105, feel: &swaying)
        }
        #expect(swayed.dropFirst(900).filter { $0.lift > 0.3 }.isEmpty)

        // A song starting, its sound rising out of silence, is an arrival, not a lift.
        var starting = LivingCoverFeel()
        _ = hold(Moment(bass: 0.04, mid: 0.04, high: 0.04, kick: 0, activity: 0), count: 15, feel: &starting)
        let arrival = hold(loud, count: 330, feel: &starting)
        #expect((arrival.map(\.lift).max() ?? 0) < 0.05)
    }

    @Test("The flow keeps the same pace at any frame rate", arguments: [20.0, 60.0, 120.0])
    func clocksFrameRateIndependent(fps: Double) {
        var reference = LivingCoverFeel()
        var other = LivingCoverFeel()
        _ = play(.dance, seconds: 6, fps: 30, feel: &reference)
        _ = play(.dance, seconds: 6, fps: fps, feel: &other)
        let a = reference.frame, b = other.frame
        for (x, y) in [(a.flow, b.flow), (a.deep, b.deep), (a.middle, b.middle), (a.top, b.top)] {
            #expect(abs(x - y) < x * 0.05)
        }
    }

    @Test("A song whose hits can't be placed in time never surges or stirs")
    func unplacedSongNeverLurches() {
        var placed = LivingCoverFeel()
        var unplaced = LivingCoverFeel()
        let looseCharacter = LivingCoverFeel.Character(punch: 0.9, brightness: 0.5, intensity: 0.9, lock: 0, gentleness: 0.1)
        let tight = play(.dance, seconds: 10, from: 4, feel: &placed)
        let loose = play(Song(character: looseCharacter, pace: 1.45, moment: Song.dance.moment), seconds: 10, from: 4, feel: &unplaced)
        // The flow still keeps pace with how full and busy the music is, only without lurching.
        #expect(mean(loose.map(\.speed)) > 0.6 * mean(tight.map(\.speed)))
        #expect(range(loose.map(\.speed)) < 0.2 * range(tight.map(\.speed)))
        #expect(range(loose.map(\.twist)) < 0.01)
    }
}
