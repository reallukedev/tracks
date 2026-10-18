import Foundation
import Testing
@testable import TracksCore

/// Every made-up song heard once, through the same steps as the app, and shared by the tests.
private enum Heard {
    static let all: [String: (signal: MusicSignal, moments: [BeatHarness.Moment])] = Dictionary(
        uniqueKeysWithValues: MusicSignal.all.map { ($0.name, ($0, BeatHarness().listen(to: $0.samples))) }
    )

    static func score(_ name: String) throws -> BeatScore {
        let heard = try #require(all[name])
        return BeatScore(heard.signal, heard.moments)
    }
}

/// Living Cover keeps time with music the way a listener does: pulses on the beat they'd tap
/// their foot to, none at all when there's no beat to be sure of, and each of its other moves
/// where the music earns it, none of them all the time.
@Suite("Moving on the beat")
struct BeatAccuracyTests {
    static let steady = ["Four on the floor 124", "Backbeat 100", "Swing 92", "Fill every 4 bars 120", "Breakdown then drop 126", "Tempo change 110 to 128"]

    @Test("Steady music pulses within 50 ms of nearly every beat, through fills, a breakdown and a change of tempo", arguments: steady)
    func pulsesLandOnTheBeat(name: String) throws {
        let score = try Heard.score(name)
        #expect(score.onBeat >= 0.9, "\(score)")
        #expect(score.coverage >= 0.85, "\(score)")
        #expect(score.medianError <= 25, "\(score)")
    }

    @Test("Music with no beat to be sure of never pulses off the beat, and music with no beat at all never pulses", arguments: ["Syncopated funk 96", "Rubato ballad", "Pad", "Silence"])
    func noRandomPulses(name: String) throws {
        let heard = try #require(Heard.all[name])
        let score = BeatScore(heard.signal, heard.moments)
        #expect(score.offBeat == 0, "\(score)")
        if !heard.signal.expectsPulses {
            #expect(heard.moments.allSatisfy { $0.reading.pulse == 0 && $0.frame.thump == 0 && $0.sway == 0 }, "\(score)")
        }
    }

    @Test("A bar's downbeat pulses harder than its other beats", arguments: ["Backbeat 100", "Swing 92", "Fill every 4 bars 120"])
    func downbeatsLeadTheBar(name: String) throws {
        let score = try Heard.score(name)
        #expect(score.downbeatAccent > 1.2, "\(score)")
    }

    @Test("Each move shows where the music earns it and none all the time")
    func everyMoveUsedNoneOverused() throws {
        let scores = try MusicSignal.all.map { try Heard.score($0.name) }
        for (signal, score) in zip(MusicSignal.all, scores) {
            // At most one pulse a beat, at its quickest.
            let quickest = zip(signal.beats, signal.beats.dropFirst()).map { 60 / ($1 - $0) }.max() ?? 0
            #expect(score.pulses <= quickest + 3, "\(score)")
            #expect(score.swirl <= 30, "\(score)")
            #expect(score.glint <= 40, "\(score)")
            #expect(score.swell <= 24, "\(score)")
            #expect(score.lift <= 8, "\(score)")
            #expect(score.swaying <= 0.75, "\(score)")
            // Driven music doesn't breathe like a ballad.
            if signal.expectsPulses { #expect(score.breath <= 3, "\(score)") }
        }
        func used(_ move: (BeatScore) -> Double) -> Bool { scores.contains { move($0) > 0 } }
        #expect(used(\.pulses) && used(\.swirl) && used(\.glint) && used(\.swell) && used(\.lift) && used(\.breath) && used(\.swaying))
        // A drop after a breakdown opens the cover out.
        #expect(try Heard.score("Breakdown then drop 126").lift > 0)
    }

    @Test("The beat is carried on to the moment a frame is seen, landing on the next beat")
    func pulseCarriedToTheScreen() throws {
        let heard = try #require(Heard.all["Four on the floor 124"])
        let beat = 60 / 124.0
        var checked = 0
        // Halfway between beats, well after the beat is found: where the next pulse would be
        // drawn if the frame were seen up to a beat later.
        for moment in heard.moments where moment.time > 10 && moment.reading.confidence > 0.9 {
            let into = moment.time.truncatingRemainder(dividingBy: beat)
            guard abs(into - beat / 2) < 0.008 else { continue }
            let steps = stride(from: 0.0, through: beat, by: 0.002).map { ($0, moment.reading.pulse(after: $0)) }
            let jump = try #require(zip(steps, steps.dropFirst()).first { $1.1 > $0.1 + 0.2 })
            let landed = moment.time + jump.1.0
            #expect(abs(landed - (moment.time - into + beat)) < 0.03)
            checked += 1
        }
        #expect(checked > 20)
    }
}
