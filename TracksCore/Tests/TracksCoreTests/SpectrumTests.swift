import Testing
import Foundation
@testable import TracksCore

@Suite("Spectrum layout")
struct SpectrumLayoutTests {
    /// A stream reporting 0 Hz, or a caller asking for no bands, used to trap.
    @Test("A nonsense rate or no bands lays out nothing", arguments: [(0.0, 24), (.nan, 24), (.infinity, 24), (44_100, 0)])
    func nothingToLayOut(sampleRate: Double, bands: Int) {
        let layout = SpectrumLayout(size: 4096, sampleRate: sampleRate, bandCount: bands)
        #expect(layout.bins.isEmpty)
        #expect(SpectrumAnalyzer(size: 4096, sampleRate: sampleRate, bandCount: bands) == nil)
        #expect(SpectrumLayout.size(for: sampleRate) >= 1024)
    }

    @Test("Every band has bins of its own, in order", arguments: [22_050.0, 44_100, 48_000, 96_000])
    func distinctBands(sampleRate: Double) {
        let size = SpectrumLayout.size(for: sampleRate)
        let layout = SpectrumLayout(size: size, sampleRate: sampleRate, bandCount: 24)
        #expect(layout.bins.count == 24)
        #expect(layout.bins[0].lowerBound >= 1)
        #expect(layout.bins.last!.upperBound <= size / 2)
        for (lower, upper) in zip(layout.bins, layout.bins.dropFirst()) {
            #expect(!lower.isEmpty)
            #expect(lower.upperBound <= upper.lowerBound)
        }
        // Rising by pitch, low notes to high.
        #expect(zip(layout.centres, layout.centres.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test("The old 1024-point layout repeated its lowest bin; this one doesn't")
    func lowBandsNotDuplicated() {
        let layout = SpectrumLayout(size: 1024, sampleRate: 44_100, bandCount: 24)
        let lowest = layout.bins.prefix(6)
        #expect(Set(lowest.map(\.lowerBound)).count == lowest.count)
    }

    @Test("Spans 40 Hz to 16 kHz at CD and studio rates", arguments: [44_100.0, 48_000])
    func span(sampleRate: Double) {
        let layout = SpectrumLayout(size: SpectrumLayout.size(for: sampleRate), sampleRate: sampleRate, bandCount: 24)
        #expect(layout.centres[0] > 30 && layout.centres[0] < 60)
        #expect(layout.centres.last! > 12_000 && layout.centres.last! < 17_000)
    }

    @Test("About 85 ms of sound, a power of two")
    func size() {
        #expect(SpectrumLayout.size(for: 44_100) == 4096)
        #expect(SpectrumLayout.size(for: 48_000) == 4096)
        #expect(SpectrumLayout.size(for: 96_000) == 8192)
    }
}

@Suite("Spectrum analyzer")
struct SpectrumAnalyzerTests {
    static let rate = 44_100.0

    static func sine(_ frequency: Double, amplitude: Double, size: Int = 4096) -> [Float] {
        (0..<size).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / rate)) }
    }

    static func analyzer() throws -> SpectrumAnalyzer {
        // No tilt, to read the scale itself.
        try #require(SpectrumAnalyzer(size: 4096, sampleRate: rate, bandCount: 24, tilt: 0))
    }

    @Test("A full-scale sine reads about 0 dB in its own band, wherever it falls", arguments: [100.0, 440, 1_000, 3_150, 9_000])
    func fullScale(frequency: Double) throws {
        let analyzer = try Self.analyzer()
        let bands = analyzer.decibels(of: Self.sine(frequency, amplitude: 1))
        let loudest = try #require(bands.indices.max { bands[$0] < bands[$1] })
        #expect(abs(bands[loudest]) < 2, "read \(bands[loudest]) dB")
        // In the band that holds it.
        let bin = Int((frequency / (Self.rate / 4096)).rounded())
        #expect(analyzer.layout.bins[loudest].contains(bin) || abs(analyzer.layout.bins[loudest].lowerBound - bin) <= 1)
    }

    @Test("A tenth of the amplitude reads 20 dB down")
    func scalesWithAmplitude() throws {
        let analyzer = try Self.analyzer()
        let loud = analyzer.decibels(of: Self.sine(1_000, amplitude: 1)).max()!
        let quiet = analyzer.decibels(of: Self.sine(1_000, amplitude: 0.1)).max()!
        #expect(abs((loud - quiet) - 20) < 0.5)
    }

    @Test("Bands far from a sine stay far below it")
    func leakage() throws {
        let analyzer = try Self.analyzer()
        let bands = analyzer.decibels(of: Self.sine(1_000, amplitude: 1))
        let loudest = bands.indices.max { bands[$0] < bands[$1] }!
        for (index, level) in bands.enumerated() where abs(index - loudest) >= 3 {
            #expect(level < -60, "band \(index) read \(level) dB")
        }
    }

    @Test("Pink noise reads level across the bands, untilted")
    func pinkIsLevel() throws {
        let analyzer = try Self.analyzer()
        // Pink noise built as equal-power sines, one per third of an octave band's worth of
        // pitch: as much in each octave as the next.
        var generator = SeededGenerator(seed: 7)
        var samples = [Float](repeating: 0, count: 4096)
        var frequency = 30.0
        while frequency < 18_000 {
            let phase = Double.random(in: 0..<(2 * .pi), using: &generator)
            for index in samples.indices {
                samples[index] += Float(0.02 * sin(2 * .pi * frequency * Double(index) / Self.rate + phase))
            }
            frequency *= 1.03
        }
        let bands = analyzer.decibels(of: samples)
        // The wider bands up high hold several sines; low down, one or two land in each.
        let spread = bands.dropFirst(4).max()! - bands.dropFirst(4).min()!
        #expect(spread < 8, "bands spread \(spread) dB: \(bands)")
    }

    @Test("Silence reads as nothing")
    func silence() throws {
        let analyzer = try Self.analyzer()
        let bands = analyzer.decibels(of: [Float](repeating: 0, count: 4096))
        #expect(bands.allSatisfy { $0 < -100 })
    }

    @Test("The tilt lifts the treble and lowers the bass about 1 kHz")
    func tilt() throws {
        let flat = try Self.analyzer()
        let tilted = try #require(SpectrumAnalyzer(size: 4096, sampleRate: Self.rate, bandCount: 24, tilt: 3))
        let samples = Self.sine(8_000, amplitude: 0.5)
        let difference = tilted.decibels(of: samples).max()! - flat.decibels(of: samples).max()!
        // Three octaves up from 1 kHz, give or take the band's middle.
        #expect(difference > 7 && difference < 11)
    }
}

@Suite("Spectrum gain")
struct SpectrumGainTests {
    @Test("A loud master and a quiet one fill the same height")
    func evensOutMastering() {
        var loud = SpectrumGain()
        var quiet = SpectrumGain()
        var loudLevels: [Float] = []
        var quietLevels: [Float] = []
        // Once each has played a while: the gain lets go slowly, so a verse stays a verse.
        for _ in 0..<1800 {
            loudLevels = loud.levels(for: [-6, -18, -30], elapsed: 1 / 60)
            quietLevels = quiet.levels(for: [-20, -32, -44], elapsed: 1 / 60)
        }
        for (a, b) in zip(loudLevels, quietLevels) {
            #expect(abs(a - b) < 0.02)
        }
        #expect(loudLevels[0] > 0.9 && loudLevels[0] <= 1)
    }

    @Test("Rises at once, falls under a decibel a second")
    func riseAndFall() {
        var gain = SpectrumGain(top: -30)
        _ = gain.levels(for: [-3], elapsed: 1 / 60)
        #expect(gain.top == 0)
        for _ in 0..<60 { _ = gain.levels(for: [-20], elapsed: 1 / 60) }
        #expect(abs(gain.top - -0.3) < 0.05)
        // Through the silence between two songs, it lets go quickly.
        for _ in 0..<60 { _ = gain.levels(for: [-90], elapsed: 1 / 60) }
        #expect(gain.top < -10)
    }

    @Test("A quiet verse after a loud chorus stays visibly quieter, and the chorus opens up again")
    func sectionsStayApart() {
        var gain = SpectrumGain()
        var contrast = LevelContrast()
        // How full the bars are, on average, over the second half of a stretch.
        func fullness(_ decibels: [Float], seconds: Double) -> Float {
            var total: Float = 0, count: Float = 0
            for frame in 0..<Int(seconds * 60) {
                let swing = Float(frame % 20) / 20 * 6
                let levels = contrast.apply(gain.levels(for: decibels.map { $0 - swing }, elapsed: 1 / 60), elapsed: 1 / 60)
                if Double(frame) > seconds * 30 { total += levels.reduce(0, +) / Float(levels.count); count += 1 }
            }
            return total / count
        }
        let chorus = fullness([-6, -12, -20, -28], seconds: 15)
        let verse = fullness([-16, -22, -30, -38], seconds: 20)
        let again = fullness([-6, -12, -20, -28], seconds: 4)
        #expect(verse < 0.75 * chorus, "verse \(verse), chorus \(chorus)")
        #expect(again > 0.9 * chorus)
    }

    @Test("Never turns near silence up into loud bars")
    func quietStaysQuiet() {
        var gain = SpectrumGain()
        var levels: [Float] = []
        for _ in 0..<600 { levels = gain.levels(for: [-70, -80], elapsed: 1 / 60) }
        #expect(gain.top == gain.lowestTop)
        #expect(levels.allSatisfy { $0 < 0.3 })
    }
}

@Suite("Level smoother")
struct LevelSmootherTests {
    @Test("The same after a second at any frame rate", arguments: [20.0, 30, 60, 120])
    func frameRateIndependent(rate: Double) {
        var smoother = LevelSmoother(count: 1)
        var reference = LevelSmoother(count: 1)
        for _ in 0..<Int(rate / 10) { smoother.step(toward: [1], elapsed: 1 / rate) }
        reference.step(toward: [1], elapsed: 0.1)
        #expect(abs(smoother.values[0] - reference.values[0]) < 0.001)
    }

    @Test("Rises quickly and falls slowly")
    func attackAndRelease() {
        var smoother = LevelSmoother(count: 1)
        smoother.step(toward: [1], elapsed: 0.05)
        #expect(smoother.values[0] > 0.75)
        var falling = LevelSmoother(count: 1, resting: 1)
        falling.step(toward: [0], elapsed: 0.05)
        #expect(falling.values[0] > 0.75 && falling.values[0] < 0.9)
    }

    @Test("A long gap, as after a pause, doesn't overshoot")
    func longGap() {
        var smoother = LevelSmoother(count: 1)
        smoother.step(toward: [0.5], elapsed: 30)
        #expect(smoother.values[0] <= 0.5)
    }
}

@Suite("Ambient levels")
struct AmbientLevelsTests {
    @Test("Stays gentle: never loud, never silent", arguments: [0.0, 0.5, 1])
    func bounded(energy: Double) {
        for step in 0..<3_600 {
            let levels = AmbientLevels.levels(at: Double(step) / 60, energy: energy, count: 24)
            #expect(levels.allSatisfy { $0 >= 0.15 && $0 <= 0.8 })
        }
    }

    @Test("Moves smoothly, with nothing that jumps as a beat would", arguments: [0.0, 1])
    func noJumps(energy: Double) {
        var previous = AmbientLevels.levels(at: 0, energy: energy, count: 24)
        for step in 1..<3_600 {
            let levels = AmbientLevels.levels(at: Double(step) / 60, energy: energy, count: 24)
            let jump = zip(levels, previous).map { abs($0 - $1) }.max()!
            // Sound rises by a third of the height in a frame; this never by a fiftieth.
            #expect(jump < 0.02)
            previous = levels
        }
    }

    @Test("Neighbouring bands move together, as one swell rather than a spectrum")
    func smoothAcross() {
        let step = (0..<1_200).map { tick in
            let levels = AmbientLevels.levels(at: Double(tick) / 2, energy: 1, count: 24)
            return zip(levels, levels.dropFirst()).map { abs($0 - $1) }.max()!
        }.max()!
        #expect(step < 0.12, "neighbours differ by \(step)")
    }
}

/// The same noise every run.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
