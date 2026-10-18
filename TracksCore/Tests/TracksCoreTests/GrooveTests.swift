import AVFoundation
import Testing
import Foundation
@testable import TracksCore

/// Made-up drums, the same every run.
private enum Drums {
    static let rate = 44_100.0

    /// A burst of noise at each beat, falling away in a few milliseconds.
    static func clicks(bpm: Double, seconds: Double = 30) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(rate * seconds))
        var random = SeededRandom("clicks")
        var beat = 0.0
        while beat < seconds {
            add(noiseBurst(decay: 0.004, amplitude: 0.8, using: &random), at: beat, to: &samples)
            beat += 60 / bpm
        }
        return samples
    }

    /// A kick on one and three and a snare on two and four, over and over.
    static func backbeat(bpm: Double, seconds: Double = 30) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(rate * seconds))
        var random = SeededRandom("backbeat")
        let kick = (0..<Int(rate * 0.3)).map { index -> Float in
            let time = Double(index) / rate
            return Float(0.9 * min(1, time / 0.004) * exp(-time / 0.12) * sin(2 * .pi * 55 * time))
        }
        var beat = 0
        while Double(beat) * 60 / bpm < seconds {
            let time = Double(beat) * 60 / bpm
            if beat % 2 == 0 {
                add(kick, at: time, to: &samples)
            } else {
                add(noiseBurst(decay: 0.05, amplitude: 0.5, using: &random), at: time, to: &samples)
            }
            beat += 1
        }
        return samples
    }

    private static func noiseBurst(decay: Double, amplitude: Double, using random: inout SeededRandom) -> [Float] {
        (0..<Int(rate * decay * 8)).map { index in
            let noise = Double(random.next() % 20_000) / 10_000 - 1
            return Float(amplitude * noise * exp(-Double(index) / rate / decay))
        }
    }

    private static func add(_ sound: [Float], at time: Double, to samples: inout [Float]) {
        let start = Int(time * rate)
        for (offset, value) in sound.enumerated() where start + offset < samples.count {
            samples[start + offset] += value
        }
    }
}

/// A made-up band, the same every run: drums in one of a few patterns, a bass note on each
/// beat, a sung line in eighths and a held chord, as a preview would be, starting partway
/// into a song whose first downbeat is at its very start.
enum Band {
    /// Half a CD's rate, and shorter than a preview, so the many cases run quickly; the click
    /// tests cover a preview's own rate and length.
    static let rate = 22_050.0

    enum Style: String, CaseIterable, CustomTestStringConvertible {
        /// A kick on every beat, snare on two and four, open hats between.
        case fourOnFloor
        /// Kick on one and three and the and of three, snare on two and four, eighth hats.
        case backbeat
        /// One kick and a pushed one a bar, a snare on three, sixteenth hats.
        case halfTime
        /// Kick on one and the and of three, snare on two and four, eighth hats.
        case breakbeat
        /// Only a kick on one and a snare on three.
        case ballad

        var testDescription: String { rawValue }
    }

    static func song(bpm: Double, style: Style, start: Double, seconds: Double = 20, rate: Double = Band.rate) -> [Float] {
        var random = SeededRandom("\(bpm)\(style)")
        let count = Int(rate * seconds)
        var out = [Float](repeating: 0, count: count)
        let beat = 60 / bpm
        func noise() -> Double { Double(random.next() % 20_000) / 10_000 - 1 }
        func add(at songTime: Double, length: Double, _ sound: (Double) -> Double) {
            let first = Int(((songTime - start) * rate).rounded())
            for offset in 0..<Int(length * rate) where first + offset >= 0 && first + offset < count {
                out[first + offset] += Float(sound(Double(offset) / rate))
            }
        }
        let kick: (Double) -> Double = { time in
            0.8 * min(1, time / 0.003) * exp(-time / 0.11) * sin(2 * .pi * (50 * time + 2.7 * (1 - exp(-time / 0.03))))
        }
        let snareNoise = (0..<Int(rate * 0.3)).map { _ in noise() }
        let snare: (Double) -> Double = { time in
            let noise = snareNoise[min(snareNoise.count - 1, Int(time * rate))]
            return min(1, time / 0.002) * (0.35 * noise * exp(-time / 0.07) + 0.3 * sin(2 * .pi * 190 * time) * exp(-time / 0.05))
        }
        let raw = (0..<Int(rate * 0.1)).map { _ in noise() }
        let hatNoise = zip(raw, [0] + raw).map { $0 - $1 }
        let hat: (Double) -> Double = { time in 0.12 * hatNoise[min(hatNoise.count - 1, Int(time * rate))] * exp(-time / 0.02) }
        let roots = [55.0, 55, 65.4, 49]
        let tune = [440.0, 494, 523, 587, 659, 587, 523, 494]
        for index in Int((start / beat).rounded(.down)) - 1...Int(((start + seconds) / beat).rounded(.up)) {
            let time = Double(index) * beat
            let inBar = index % 4
            let root = roots[(index / 4) % 4]
            switch style {
            case .fourOnFloor:
                add(at: time, length: 0.4, kick)
                if inBar % 2 == 1 { add(at: time, length: 0.3, snare) }
                add(at: time + beat / 2, length: 0.1, hat)
            case .backbeat:
                if inBar % 2 == 0 { add(at: time, length: 0.4, kick) }
                if inBar == 2 { add(at: time + beat / 2, length: 0.4, kick) }
                if inBar % 2 == 1 { add(at: time, length: 0.3, snare) }
                add(at: time, length: 0.1, hat)
                add(at: time + beat / 2, length: 0.1, hat)
            case .halfTime:
                if inBar == 0 {
                    add(at: time, length: 0.4, kick)
                    add(at: time + beat * 0.75, length: 0.4, kick)
                }
                if inBar == 2 { add(at: time, length: 0.3, snare) }
                for sixteenth in 0..<4 { add(at: time + Double(sixteenth) * beat / 4, length: 0.1, hat) }
            case .breakbeat:
                if inBar == 0 { add(at: time, length: 0.4, kick) }
                if inBar == 2 { add(at: time + beat / 2, length: 0.4, kick) }
                if inBar % 2 == 1 { add(at: time, length: 0.3, snare) }
                add(at: time, length: 0.1, hat)
                add(at: time + beat / 2, length: 0.1, hat)
            case .ballad:
                if inBar == 0 { add(at: time, length: 0.4, kick) }
                if inBar == 2 { add(at: time, length: 0.3, snare) }
            }
            add(at: time, length: beat) { time in
                0.25 * min(1, time / 0.02) * exp(-time / (beat * 0.8)) * (sin(2 * .pi * root * time) + 0.4 * sin(4 * .pi * root * time))
            }
            for eighth in 0..<2 {
                let note = tune[(index * 2 + eighth) % tune.count]
                add(at: time + Double(eighth) * beat / 2, length: beat / 2) { time in
                    0.08 * min(1, time / 0.03) * min(1, (beat / 2 - time) / 0.02) * sin(2 * .pi * note * time + 0.3 * sin(2 * .pi * 5 * time))
                }
            }
            if inBar == 0 {
                add(at: time, length: beat * 4) { time in
                    0.05 * min(1, time / 0.3) * (4...6).reduce(0) { $0 + sin(2 * .pi * root * Double($1) * time) }
                }
            }
        }
        return out
    }

    /// Where a preview starts in its song: anywhere, not on a beat.
    static func start(for bpm: Double) -> Double { 47.3 + bpm.truncatingRemainder(dividingBy: 7) }
}

/// One at a time: each case is seconds of number crunching, and dozens at once hold every
/// thread the other suites' tasks wait on.
@Suite("Groove analysis", .serialized)
struct GrooveAnalysisTests {
    @Test("Finds the tempo of a click track, not half or twice it", arguments: [90.0, 120, 128, 170, 174])
    func tempo(bpm: Double) {
        let groove = GrooveAnalysis.groove(of: Drums.clicks(bpm: bpm), sampleRate: Drums.rate)
        #expect(abs(groove.tempo - bpm) < 0.1, "heard \(groove.tempo) BPM")
        #expect(groove.confidence > 0.3)
    }

    /// A song is in time if it's counted at its tempo, or at half it when that's over 160 or
    /// the drums only play every other beat, as a listener would feel it. Twice the tempo, or
    /// a third off it, flashes against the music.
    private static func feels(_ heard: Double, like bpm: Double, style: Band.Style) -> Bool {
        if abs(heard - bpm) < 0.1 { return true }
        let halfTime = bpm > 160 || style == .ballad
        return halfTime && abs(heard - bpm / 2) < 0.05
    }

    @Test("Finds a band's tempo to a tenth of a beat a minute, whatever its drums play",
          arguments: [90.0, 97.3, 128, 140, 174], Band.Style.allCases)
    func bandTempo(bpm: Double, style: Band.Style) {
        let groove = GrooveAnalysis.groove(of: Band.song(bpm: bpm, style: style, start: Band.start(for: bpm)), sampleRate: Band.rate)
        #expect(Self.feels(groove.tempo, like: bpm, style: style), "heard \(groove.tempo) BPM")
        #expect(groove.confidence >= GrooveLevels.leastConfidence)
    }

    @Test("Finds where a band's beats fall, to a fiftieth of a second",
          arguments: [90.0, 128, 174], [Band.Style.fourOnFloor, .backbeat, .breakbeat])
    func bandBeats(bpm: Double, style: Band.Style) throws {
        let start = Band.start(for: bpm)
        let found = try #require(GrooveAnalysis.beats(of: Band.song(bpm: bpm, style: style, start: start), sampleRate: Band.rate))
        #expect(found.times.count >= 14)
        let beat = 60 / bpm
        for time in found.times {
            // Measured from the song's start, every found beat is on one of the song's.
            let place = (time + start) / beat
            #expect(abs(place - place.rounded()) * beat < 0.02, "a beat at \(time) s")
        }
    }

    @Test("Hears a band through an AAC file, as a preview arrives")
    func harness() throws {
        let bpm = 123.0
        let start = Band.start(for: bpm)
        // A preview's own rate and length.
        let rate = 44_100.0
        let samples = Band.song(bpm: bpm, style: .backbeat, start: start, seconds: 30, rate: rate)
        let url = URL.temporaryDirectory.appending(path: "groove-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000]
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
            buffer.frameLength = AVAudioFrameCount(samples.count)
            for channel in 0..<2 {
                let data = try #require(buffer.floatChannelData?[channel])
                for index in samples.indices { data[index] = samples[index] * 0.7 }
            }
            try file.write(from: buffer)
        }
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channels = try #require(buffer.floatChannelData)
        let read = Int(buffer.frameLength), channelCount = Int(file.processingFormat.channelCount)
        let mono = (0..<read).map { index in (0..<channelCount).reduce(Float(0)) { $0 + channels[$1][index] } / Float(channelCount) }

        let groove = GrooveAnalysis.groove(of: mono, sampleRate: file.processingFormat.sampleRate)
        let found = try #require(GrooveAnalysis.beats(of: mono, sampleRate: file.processingFormat.sampleRate))
        print("Groove harness: \(String(format: "%.2f", groove.tempo)) BPM, sure \(String(format: "%.2f", groove.confidence)), beats at \(found.times.prefix(8).map { String(format: "%.3f", $0) }.joined(separator: ", ")) s")
        #expect(abs(groove.tempo - bpm) < 0.1)
        // AAC adds a little delay of its own at the start, which is the only slack here.
        let beat = 60 / bpm
        let places = found.times.map { (($0 + start) / beat).truncatingRemainder(dividingBy: 1) }
        let off = places.map { min($0, 1 - $0) * beat }
        #expect((off.max() ?? 1) < 0.06, "off by \(off.max() ?? 1) s")
    }

    @Test("Noise, and held chords, have no beat to show")
    func noBeat() {
        var random = SeededRandom("noise")
        let noise = (0..<Int(Drums.rate * 30)).map { _ in Float(Double(random.next() % 20_000) / 40_000 - 0.25) }
        #expect(GrooveAnalysis.groove(of: noise, sampleRate: Drums.rate).confidence < GrooveLevels.leastConfidence)
        let chord = (0..<Int(Drums.rate * 30)).map { index in
            let time = Double(index) / Drums.rate
            return Float([220.0, 277.2, 329.6].reduce(0) { $0 + 0.1 * sin(2 * .pi * $1 * time) } * (0.8 + 0.2 * sin(2 * .pi * time / 7)))
        }
        #expect(GrooveAnalysis.groove(of: chord, sampleRate: Drums.rate).confidence < GrooveLevels.leastConfidence)
    }

    @Test("A count within a hair of a whole number is taken as it, and one further off isn't")
    func steadied() {
        #expect(GrooveAnalysis.steadied(127.93) == 128)
        #expect(GrooveAnalysis.steadied(120.1) == 120)
        #expect(GrooveAnalysis.steadied(97.3) == 97.3)
    }

    @Test("A kick on one and three and a snare on two and four show where they land")
    func backbeat() {
        let groove = GrooveAnalysis.groove(of: Drums.backbeat(bpm: 120), sampleRate: Drums.rate)
        #expect(abs(groove.tempo - 120) < 0.1, "heard \(groove.tempo) BPM")
        let low = groove.low.hits, mid = groove.mid.hits
        // The kick's beats, and the snare's, by the bar the analysis settled on.
        #expect(min(low[0], low[8]) > max(low[4], low[12]) + 0.2, "low \(low)")
        #expect(min(mid[4], mid[12]) > max(mid[0], mid[8]) + 0.2, "mid \(mid)")
        #expect(groove.punch > 0.3)
    }

    @Test("Silence is calm")
    func silence() {
        let groove = GrooveAnalysis.groove(of: [Float](repeating: 0, count: Int(Drums.rate * 30)), sampleRate: Drums.rate)
        #expect(groove.confidence == 0)
        #expect(groove.punch == 0)
        #expect(groove.low.hits.allSatisfy { $0 == 0 })
    }

    /// Sound that's no use, by name, so a failure says which.
    enum Unusable: String, CaseIterable, CustomTestStringConvertible {
        case nothing, tooShort, allNaN, allInfinite, nanRate, zeroRate

        var testDescription: String { rawValue }

        var input: (samples: [Float], rate: Double) {
            let long = Int(Drums.rate * 6)
            return switch self {
            case .nothing: ([], Drums.rate)
            case .tooShort: ([Float](repeating: 0.5, count: 1_000), Drums.rate)
            case .allNaN: ([Float](repeating: .nan, count: long), Drums.rate)
            case .allInfinite: ([Float](repeating: .infinity, count: long), Drums.rate)
            case .nanRate: ([Float](repeating: 0.1, count: long), .nan)
            case .zeroRate: ([Float](repeating: 0.1, count: long), 0)
            }
        }
    }

    @Test("Nothing, too little, NaN or a nonsense rate is safe", arguments: Unusable.allCases)
    func safe(_ unusable: Unusable) {
        let (samples, rate) = unusable.input
        let groove = GrooveAnalysis.groove(of: samples, sampleRate: rate)
        #expect(groove.tempo.isFinite)
        #expect(groove.confidence == 0)
    }

    @Test("Half NaN among the clicks still finds the beat")
    func nanAmongClicks() {
        var samples = Drums.clicks(bpm: 120)
        for index in stride(from: 0, to: samples.count, by: 7) { samples[index] = .nan }
        let groove = GrooveAnalysis.groove(of: samples, sampleRate: Drums.rate)
        #expect(abs(groove.tempo - 120) < 0.1)
    }
}

@Suite("Groove levels")
struct GrooveLevelsTests {
    static let floor: Groove = {
        var groove = Groove.calm
        groove.tempo = 124
        groove.confidence = 1
        groove.punch = 0.8
        groove.low.hits = (0..<16).map { $0 % 4 == 0 ? 1 : 0 }
        return groove
    }()

    @Test("The low bands pulse once a beat, up at once and well down before the next")
    func pulsesAtTempo() throws {
        let tick = 0.002
        let lows = (0..<2_000).map { GrooveLevels.levels(playbackTime: Double($0) * tick, groove: Self.floor, count: 24)[0] }
        let peaks = lows.indices.dropFirst().dropLast().filter { lows[$0] > lows[$0 - 1] && lows[$0] >= lows[$0 + 1] && lows[$0] > 0.4 }
        try #require(peaks.count >= 6)
        let beat = 60 / 124.0
        for (first, second) in zip(peaks, peaks.dropFirst()) {
            #expect(abs(Double(second - first) * tick - beat) < 0.01)
        }
        for peak in peaks {
            // Within a fiftieth of a second of the beat.
            let place = Double(peak) * tick / beat
            #expect((place - place.rounded(.down)) * beat < 0.02)
        }
        #expect((lows.min() ?? 1) < (lows.max() ?? 0) - 0.3)
    }

    @Test("The first beat of a bar lands hardest")
    func downbeat() {
        var groove = Self.floor
        groove.mid.hits = [Float](repeating: 0, count: 16)
        let beat = 60 / groove.tempo
        let kicks = (0..<4).map { GrooveLevels.hits(playbackTime: (Double(4 + $0) + 0.015) * beat, groove: groove).kick }
        #expect(kicks[0] > kicks[1] + 0.15)
        #expect(kicks[0] > kicks[2])
        #expect(kicks[2] > kicks[1])
    }

    @Test("Every beat shows, even with no drums heard on it, and only the beats")
    func everyBeat() {
        var groove = Groove.calm
        groove.tempo = 100
        groove.confidence = 0.8
        groove.punch = 0.5
        let beat = 0.6
        var bumps = 0
        var rising = false
        var last: Float = 0
        for frame in 0..<(8 * 60) {
            // Thirty frames a second, as the Mac draws.
            let kick = GrooveLevels.hits(playbackTime: Double(frame) / 30, groove: groove).kick
            if kick > last + 0.05, !rising { bumps += 1; rising = true }
            if kick < last { rising = false }
            last = kick
        }
        #expect(bumps == Int(8 * 60 / 30 / beat) || bumps == Int(8 * 60 / 30 / beat) + 1, "\(bumps) bumps in 16 seconds")
    }

    @Test("Between the hits, nothing flickers")
    func noFlicker() {
        let groove = Groove.sample(seed: "Night Drive")
        let step = 60 / groove.tempo / 4
        var previous = GrooveLevels.levels(playbackTime: 0, groove: groove, count: 24)
        for frame in 1..<(20 * 60) {
            let time = Double(frame) / 60
            let levels = GrooveLevels.levels(playbackTime: time, groove: groove, count: 24)
            // A level only jumps up just after a step, where a drum can land.
            let sinceStep = time - (time / step).rounded(.down) * step
            if sinceStep > 0.04 {
                for (now, before) in zip(levels, previous) { #expect(now - before < 0.03) }
            }
            previous = levels
        }
    }

    @Test("Swing pushes a kick between the beats late")
    func swing() {
        var straight = Self.floor
        straight.low.hits[6] = 1
        var swung = straight
        swung.low.lean[6] = 0.4
        let step = 60 / 124.0 / 4
        let onTime = GrooveLevels.hits(playbackTime: 6 * step + 0.02, groove: straight).kick
        let late = GrooveLevels.hits(playbackTime: 6 * step + 0.02, groove: swung).kick
        #expect(late < onTime * 0.5)
    }

    @Test("Stays between 0 and 1, for any time", arguments: [Groove.calm, GrooveLevelsTests.floor, Groove.sample(seed: "a"), Groove.sample(seed: "b")])
    func bounded(groove: Groove) {
        for time in [-5, 0, 0.001, 1.5, 61.25, 3_600, 1e9, .nan, .infinity] {
            let levels = GrooveLevels.levels(playbackTime: time, groove: groove, count: 24)
            #expect(levels.count == 24)
            #expect(levels.allSatisfy { $0 >= 0 && $0 <= 1 })
        }
    }

    @Test("The same moment of the same song looks the same")
    func deterministic() {
        #expect(Groove.sample(seed: "Night Drive") == Groove.sample(seed: "Night Drive"))
        let groove = Groove.sample(seed: "Night Drive")
        #expect(GrooveLevels.levels(playbackTime: 42.3, groove: groove, count: 24) == GrooveLevels.levels(playbackTime: 42.3, groove: groove, count: 24))
    }

    @Test("Sample songs keep a tempo drummers play at")
    func sampleTempos() {
        for seed in ["a", "b", "c", "d", "e", "f", "g", "h"] {
            #expect((66...132).contains(Groove.sample(seed: seed).tempo))
        }
    }
}

@Suite("Ambient breath")
struct AmbientBreathTests {
    @Test("Moves quicker for a livelier song")
    func tempo() {
        #expect(AmbientLevels.tempo(energy: 1) > AmbientLevels.tempo(energy: 0) + 30)
    }

    @Test("Breathes slowly, with no beat", arguments: [0.0, 0.5, 1])
    func breathes(energy: Double) {
        var previous = AmbientLevels.levels(at: 0, energy: energy, count: 24)
        for step in 1..<1_200 {
            let levels = AmbientLevels.levels(at: Double(step) / 60, energy: energy, count: 24)
            for (now, before) in zip(levels, previous) { #expect(abs(now - before) < 0.01) }
            previous = levels
        }
    }
}

@Suite("Playback clock")
struct PlaybackClockTests {
    @Test("Smooths a position reported in steps")
    func smooths() {
        var clock = PlaybackClock()
        var previous = clock.position(reported: 10, at: 100, isPlaying: true)
        for frame in 1...120 {
            let now = 100 + Double(frame) / 60
            // Reported a tenth of a second at a time.
            let reported = 10 + (Double(frame) / 60 * 10).rounded(.down) / 10
            let position = clock.position(reported: reported, at: now, isPlaying: true)
            #expect(position >= previous)
            #expect(position - previous < 0.04)
            previous = position
        }
    }

    @Test("Jumps with a seek")
    func seek() {
        var clock = PlaybackClock()
        _ = clock.position(reported: 10, at: 100, isPlaying: true)
        #expect(clock.position(reported: 95, at: 100.02, isPlaying: true) == 95)
    }
}

@Suite("Meter motion")
struct MeterMotionTests {
    @Test("A cap hangs, then falls faster and faster")
    func caps() {
        var caps = PeakCaps()
        caps.step([1], elapsed: 0)
        caps.step([0], elapsed: 0.2)
        #expect(caps.peaks[0] == 1)
        var drops: [Float] = []
        var last: Float = 1
        for _ in 0..<12 {
            caps.step([0], elapsed: 1 / 30)
            drops.append(last - caps.peaks[0])
            last = caps.peaks[0]
        }
        #expect(caps.peaks[0] < 1)
        #expect(drops.last! > drops.first!)
    }

    @Test("A quiet master is stretched over more of the height")
    func contrastStretches() {
        var contrast = LevelContrast()
        var levels: [Float] = []
        for frame in 0..<600 {
            let swing = Float(frame % 30) / 30
            levels = contrast.apply([0.25 + 0.2 * swing, 0.25, 0.3], elapsed: 1 / 60)
        }
        #expect((levels.max() ?? 0) > 0.55)
    }

    @Test("A squashed master's bars are spread apart, its loudest still near the top")
    func contrastSpreads() {
        var contrast = LevelContrast()
        var levels: [Float] = []
        for _ in 0..<1800 { levels = contrast.apply([0.62, 0.93, 0.8, 0.7], elapsed: 1 / 60) }
        #expect(levels[0] < 0.5)
        #expect(levels[1] > 0.9)
    }

    @Test("Silence stays still")
    func contrastLeavesSilence() {
        var contrast = LevelContrast()
        var levels: [Float] = []
        for _ in 0..<600 { levels = contrast.apply([0.04, 0.03, 0.05], elapsed: 1 / 60) }
        #expect(levels.allSatisfy { $0 < 0.08 })
    }
}

@Suite("Groove texture", .serialized)
struct GrooveTextureTests {
    private static func low(_ bands: [Float]) -> Float { bands.prefix(5).reduce(0, +) / 5 }

    @Test("Replays a backbeat's kicks on the song's own bars, and lets them fall between")
    func backbeat() throws {
        let groove = GrooveAnalysis.groove(of: Drums.backbeat(bpm: 120), sampleRate: Drums.rate)
        let texture = try #require(groove.texture)
        #expect(texture.chunkSeconds == 2)
        #expect(texture.bandCount == 24)
        #expect(texture.chunkCount >= 10)
        // Bar after bar, forward and back: the kick on one, gone by the and of one.
        for bar in [0, 3, 17, 40] {
            let start = Double(bar) * 2
            let hit = Self.low(texture.levels(at: start + 0.01)), after = Self.low(texture.levels(at: start + 0.35))
            #expect(hit > after + 0.15, "bar \(bar): \(hit) then \(after)")
        }
    }

    @Test("Under a held bass and chords, every band still rises and falls, and none stays up",
          arguments: [Band.Style.backbeat, .fourOnFloor, .ballad])
    func nothingStaysUp(style: Band.Style) throws {
        let song = Band.song(bpm: 112, style: style, start: Band.start(for: 112), seconds: 30)
        let texture = try #require(GrooveAnalysis.groove(of: song, sampleRate: Band.rate).texture)
        let moments = stride(from: 0.0, to: 16, by: 0.02).map { texture.levels(at: $0) }
        for band in 0..<texture.bandCount {
            let values = moments.map { $0[band] }.sorted()
            let median = values[values.count / 2], low = values[values.count / 10], high = values[values.count * 9 / 10]
            #expect(median < 0.8, "band \(band) sits at \(median)")
            // The kick's bands, under the held bass note, rise on each hit and fall away.
            if band < 4 { #expect(high - low > 0.25, "band \(band) moves only from \(low) to \(high)") }
        }
    }

    @Test("Glides from one moment to the next rather than stepping")
    func glides() throws {
        let texture = try #require(GrooveAnalysis.groove(of: Drums.backbeat(bpm: 120), sampleRate: Drums.rate).texture)
        // A sixtieth of a second apart, nothing in the bass jumps more than a frame's change allows.
        let frame = texture.chunkSeconds / Double(GrooveTexture.framesPerChunk)
        var largest: Float = 0
        for step in 0..<600 {
            let time = Double(step) / 60
            let a = Self.low(texture.levels(at: time)), b = Self.low(texture.levels(at: time + 1 / 60.0))
            largest = max(largest, abs(b - a))
        }
        #expect(largest < Float(1 / 60.0 / frame) + 0.01, "jumped \(largest)")
    }

    @Test("A song with no beat replays two seconds at a time")
    func noBeat() throws {
        var random = SeededRandom("noise")
        let noise = (0..<Int(Drums.rate * 30)).map { _ in Float(Double(random.next() % 20_000) / 40_000 - 0.25) }
        let groove = GrooveAnalysis.groove(of: noise, sampleRate: Drums.rate)
        let texture = try #require(groove.texture)
        #expect(texture.chunkSeconds == GrooveTexture.freeChunk)
        #expect(texture.isPlayable)
    }

    @Test("Silence has nothing to replay")
    func silence() {
        #expect(GrooveAnalysis.groove(of: [Float](repeating: 0, count: Int(Drums.rate * 30)), sampleRate: Drums.rate).texture == nil)
    }

    @Test("Chunks play forward, then back, never jumping")
    func turnsBack() {
        #expect((0..<9).map { GrooveTexture.chunk($0, of: 3) } == [0, 1, 2, 1, 0, 1, 2, 1, 0])
        #expect(GrooveTexture.chunk(5, of: 1) == 0)
        #expect((-3..<0).map { GrooveTexture.chunk($0, of: 3) } == [1, 2, 1])
    }

    @Test("Where the preview's place in the song is known, its stretch replays exactly, gliding between frames")
    func placed() {
        // Two chunks of one band: the first rising frame by frame, the second all full.
        var bytes = (0..<GrooveTexture.framesPerChunk).map { UInt8($0 * 8) }
        bytes += [UInt8](repeating: 255, count: GrooveTexture.framesPerChunk)
        let texture = GrooveTexture(chunkSeconds: 3.2, bandCount: 1, levels: Data(bytes))
        // The preview's first chunk starts 40 seconds into the song.
        #expect(texture.levels(at: 40.05, origin: 40)[0] == Float(4) / 255)
        #expect(texture.levels(at: 43.3, origin: 40)[0] == 1)
        // The bar before it is its neighbour turned back, the second chunk.
        #expect(texture.levels(at: 39, origin: 40)[0] == 1)
    }

    @Test("Any moment is safe, and kept small", arguments: [-5.0, 0, 1_000_000, .nan, .infinity])
    func safe(position: Double) throws {
        let groove = GrooveAnalysis.groove(of: Drums.backbeat(bpm: 97), sampleRate: Drums.rate)
        let texture = try #require(groove.texture)
        let levels = texture.levels(at: position)
        #expect(levels.count == 24)
        #expect(levels.allSatisfy { (0...1).contains($0) })
        #expect(try JSONEncoder().encode(groove).count < 30_000)
    }

    @Test("A soft song's range spreads to the full height, and a steady band sits mid-way, not at the top")
    func bandRange() throws {
        let frames = GrooveTexture.framesPerChunk * 4
        // Band 0 a quiet song's swell, between 20 and 120; band 1 held at 150; band 2 silent.
        let bytes = (0..<frames).flatMap { frame -> [UInt8] in
            [UInt8(20 + (frame * 7) % 101), 150, 0]
        }
        let texture = GrooveTexture(chunkSeconds: 2, bandCount: 3, levels: Data(bytes))
        let range = texture.bandRange()
        func spread(_ value: Float, _ band: Int) -> Float {
            min(1, max(0, (value - range.floor[band]) / (range.ceiling[band] - range.floor[band])))
        }
        #expect(spread(118 / 255, 0) > 0.95)
        #expect(spread(25 / 255, 0) < 0.08)
        #expect(abs(spread(150 / 255, 1) - 0.5) < 0.01)
        #expect(spread(0, 2) == 0)
        #expect(GrooveTexture(chunkSeconds: 2, bandCount: 3, levels: Data()).bandRange().floor.isEmpty)
    }

    @Test("A soft, quiet ballad is gentle; a slow rap track that hits hard and loud isn't")
    func gentleness() {
        var ballad = Groove.calm
        (ballad.tempo, ballad.confidence, ballad.punch, ballad.loudness) = (68, 0.7, 0.15, -16)
        var rap = Groove.calm
        (rap.tempo, rap.confidence, rap.punch, rap.loudness) = (72, 0.8, 0.8, -7)
        #expect(ballad.gentleness > 0.8)
        #expect(rap.gentleness == 0)
        // Soft, but mastered loud, or loudness not known: it still moves fully.
        var loudSoft = ballad
        loudSoft.loudness = -8
        #expect(loudSoft.gentleness == 0)
        loudSoft.loudness = nil
        #expect(loudSoft.gentleness == 0)
    }

    @Test("A hard-hitting beat moves fully and keeps its hits, slow or quick", arguments: [(Band.Style.halfTime, 75.0), (.backbeat, 82), (.fourOnFloor, 140)])
    func hardHitting(style: Band.Style, bpm: Double) {
        let groove = GrooveAnalysis.groove(of: Band.song(bpm: bpm, style: style, start: Band.start(for: bpm), seconds: 30), sampleRate: Band.rate)
        #expect(groove.gentleness < 0.2, "punch \(groove.punch), intensity \(groove.intensity)")
        #expect(groove.lock >= 0.85)
    }

    @Test("A replay's hits count fully only once the preview is placed in the song")
    func lock() {
        var groove = Groove.calm
        #expect(groove.lock == 0)
        groove.confidence = 0.8
        #expect(groove.lock > 0.5 && groove.lock < 1)
        groove.songOffset = 42
        #expect(groove.lock == 1)
    }
}
