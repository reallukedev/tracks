import Foundation
import Testing
@testable import TracksCore

@Suite("Loudness")
struct LoudnessTests {
    static func tone(amplitude: Float, seconds: Double = 6, rate: Double = 48_000) -> [Float] {
        (0..<Int(rate * seconds)).map { amplitude * Float(sin(2 * .pi * 997 * Double($0) / rate)) }
    }

    static func lufs(_ samples: [Float], rate: Double = 48_000) -> Double {
        Loudness.integrated(Loudness.blocks(Loudness.weighted(samples, sampleRate: rate), sampleRate: rate))
    }

    @Test("A full-scale tone measures -3 LUFS, as the standard's own check does, and 20 dB down measures -23")
    func calibrated() {
        #expect(abs(Self.lufs(Self.tone(amplitude: 1)) + 3.01) < 0.2)
        #expect(abs(Self.lufs(Self.tone(amplitude: 0.1)) + 23.01) < 0.2)
        #expect(abs(Self.lufs(Self.tone(amplitude: 1, rate: 44_100), rate: 44_100) + 3.01) < 0.2)
    }

    @Test("Silence is silence, and a song's quiet start doesn't pull its loudness down")
    func gated() {
        #expect(Self.lufs([Float](repeating: 0, count: 48_000 * 4)) == Loudness.silence)
        let withSilence = [Float](repeating: 0, count: 48_000 * 3) + Self.tone(amplitude: 0.1)
        #expect(abs(Self.lufs(withSilence) + 23.01) < 0.3)
    }

    @Test("Louder moves more, halving every 8 LU, never below a floor for music, and nothing for silence")
    func intensity() {
        #expect(Loudness.intensity(lufs: -6) == 1)
        #expect(abs(Loudness.intensity(lufs: -16) - 0.5) < 0.01)
        #expect(abs(Loudness.intensity(lufs: -24) - 0.25) < 0.01)
        #expect(Loudness.intensity(lufs: -36) >= Loudness.least * 0.99)
        #expect(Loudness.intensity(lufs: -60) == 0)
        #expect(Loudness.intensity(lufs: nil) == 1)
        let ladder = stride(from: -40.0, through: -8, by: 2).map { Loudness.intensity(lufs: $0) }
        #expect(zip(ladder, ladder.dropFirst()).allSatisfy { $0 <= $1 })
    }
}

/// The same band at three volumes, and silence, heard and played back.
@Suite("Groove dynamics", .serialized)
struct GrooveDynamicsTests {
    static let song = Band.song(bpm: 120, style: .backbeat, start: Band.start(for: 120), seconds: 20)

    static func groove(gain: Float) -> Groove {
        GrooveAnalysis.groove(of: song.map { $0 * gain }, sampleRate: Band.rate)
    }

    /// The kick's average peak and the bands' average level over eight seconds well into a
    /// song, past its eased start.
    static func drawn(_ groove: Groove) -> (kick: Float, level: Float) {
        let frames = (0..<240).map { 30 + Double($0) / 30 }
        let kicks = frames.map { GrooveLevels.hits(playbackTime: $0, groove: groove, duration: 240).kick }
        let levels = frames.map { GrooveLevels.levels(playbackTime: $0, groove: groove, count: 24, duration: 240) }
        let level = levels.map { $0.reduce(0, +) / Float($0.count) }.reduce(0, +) / Float(levels.count)
        return (kicks.max() ?? 0, level)
    }

    @Test("A quiet and a loud take of the same song move clearly differently, in order")
    func quietAndLoud() throws {
        // Each 8 dB quieter than the last, as a dance master, a pop one and a ballad's differ.
        let loud = Self.groove(gain: 1), middle = Self.groove(gain: 0.4), quiet = Self.groove(gain: 0.16)
        let loudness = try [loud, middle, quiet].map { try #require($0.loudness) }
        #expect(loudness[0] > loudness[1] + 7 && loudness[1] > loudness[2] + 7, "\(loudness)")
        // The beat is found whatever the volume.
        for groove in [loud, middle, quiet] { #expect(abs(groove.tempo - 120) < 0.2) }

        let drawn = [loud, middle, quiet].map(Self.drawn)
        #expect(drawn[0].kick > drawn[1].kick * 1.4, "\(loudness) \(drawn)")
        #expect(drawn[1].kick > drawn[2].kick * 1.4, "\(loudness) \(drawn)")
        #expect(drawn[0].level > drawn[1].level && drawn[1].level > drawn[2].level, "\(drawn)")
        #expect(drawn[2].kick < 0.35, "a quiet song pulses gently: \(drawn[2].kick)")
    }

    @Test("Silence draws next to nothing")
    func silence() {
        let groove = GrooveAnalysis.groove(of: [Float](repeating: 0, count: Int(Band.rate * 20)), sampleRate: Band.rate)
        #expect(groove.loudness == Loudness.silence)
        #expect(groove.intensity < 0.01)
        var beating = groove
        // Even made to keep a beat, there's nothing to show.
        beating.confidence = 1
        beating.low.hits = (0..<16).map { $0 % 4 == 0 ? 1 : 0 }
        let drawn = Self.drawn(beating)
        #expect(drawn.kick < 0.01)
        #expect(drawn.level < 0.05)
    }

    @Test("Quiet bars stay quiet, and each beat is as hard as the one heard")
    func bars() throws {
        // Loud bars and soft ones, taking turns two bars at a time.
        let beat = 60 / 120.0
        let start = Band.start(for: 120)
        let shaped = Self.song.enumerated().map { index, sample in
            let bar = Int((start + Double(index) / Band.rate) / (beat * 4))
            return sample * (bar / 2 % 2 == 0 ? 1 : 0.25)
        }
        let groove = GrooveAnalysis.groove(of: shaped, sampleRate: Band.rate)
        let bars = try #require(groove.bars)
        let beats = try #require(groove.beats)
        try #require(bars.count >= 4 && beats.count == bars.count * 4)
        #expect((bars.max() ?? 0) - (bars.min() ?? 0) > 8, "\(bars)")
        // The beats of the loudest bar land harder than those of the quietest.
        let loudest = try #require(bars.indices.max { bars[$0] < bars[$1] })
        let quietest = try #require(bars.indices.min { bars[$0] < bars[$1] })
        let strength = { (bar: Int) in beats[bar * 4 ..< bar * 4 + 4].reduce(0, +) }
        #expect(strength(loudest) > strength(quietest) * 1.5, "\(beats)")

        // Played back, the loud bars draw stronger than the quiet ones.
        let strengths = (8..<40).map { bar in
            GrooveLevels.hits(playbackTime: (Double(bar) + 0.5) * beat * 4, groove: groove, duration: 240).strength
        }
        #expect((strengths.max() ?? 0) > (strengths.min() ?? 0) * 2, "\(strengths)")
    }

    @Test("A song eases in over its first seconds and out over its last")
    func ends() {
        var groove = GrooveLevelsTests.floor
        groove.loudness = -8
        let strength = { (time: Double) in GrooveLevels.hits(playbackTime: time, groove: groove, duration: 200).strength }
        #expect(abs(strength(0) - 0.4) < 0.01)
        #expect(strength(5) > strength(1))
        #expect(abs(strength(60) - 1) < 0.01)
        #expect(strength(199) < 0.5)
        // With no length known, such as a live stream, there are no ends to ease.
        #expect(GrooveLevels.hits(playbackTime: 0, groove: groove).strength == 1)
    }

    @Test("A groove kept before loudness was measured still reads, and moves fully")
    func olderFiles() throws {
        let data = try JSONEncoder().encode(Groove.sample(seed: "Night Drive"))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["loudness", "loudnessRange", "beats", "bars"] { object.removeValue(forKey: key) }
        let older = try JSONDecoder().decode(Groove.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.loudness == nil)
        #expect(older.intensity == 1)
        #expect(older.tempo == Groove.sample(seed: "Night Drive").tempo)
    }
}
