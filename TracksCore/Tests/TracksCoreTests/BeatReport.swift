#if os(macOS)
import AVFoundation
import Foundation
import Testing
@testable import TracksCore

/// A report of how every move keeps time, for made-up music and any real music to hand.
/// `TRACKS_BEAT_REPORT=1 swift test --filter BeatReport`; set `TRACKS_BEAT_AUDIO` to a folder of
/// drum loops named with their tempo ("... 92 BPM.wav") to measure those too, each looped to
/// forty seconds from its first downbeat, and `TRACKS_BEAT_SONGS` to song paths split by `|`.
@Suite("Beat report", .enabled(if: ProcessInfo.processInfo.environment["TRACKS_BEAT_REPORT"] != nil))
struct BeatReport {
    @Test func madeUpMusic() {
        for signal in MusicSignal.all {
            print("BEAT", BeatScore(signal, BeatHarness().listen(to: signal.samples)))
        }
    }

    @Test func realLoops() throws {
        guard let folder = ProcessInfo.processInfo.environment["TRACKS_BEAT_AUDIO"] else { return }
        let files = try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0.contains("BPM") }.sorted()
        for name in files {
            guard let signal = Self.loop(URL(fileURLWithPath: folder).appending(path: name)) else { continue }
            let samples = signal.samples
            print("LOOP", BeatScore(signal, BeatHarness().listen(to: samples)), String(format: "beat-in-onsets %.2f", Self.periodicity(signal)))
        }
    }

    /// Whole songs, with no true beats to measure against: how often each move shows, and
    /// how evenly the pulses come.
    @Test func realSongs() throws {
        guard let list = ProcessInfo.processInfo.environment["TRACKS_BEAT_SONGS"] else { return }
        for path in list.split(separator: "|").map(String.init) {
            guard let samples = Self.read(URL(fileURLWithPath: path), seconds: 75) else { continue }
            let moments = BeatHarness().listen(to: samples)
            let signal = MusicSignal(name: String(URL(fileURLWithPath: path).lastPathComponent.prefix(26)), samples: samples, beats: [], downbeats: [], steady: [])
            let score = BeatScore(signal, moments, settle: 8)
            let starts = BeatScore.pulseStarts(moments).map(\.time).filter { $0 > 8 }
            let gaps = zip(starts, starts.dropFirst()).map { $1 - $0 }
            // Even pulses keep to a beat: the share of gaps within 8% of a whole number of the commonest.
            let typical = gaps.sorted().dropFirst(gaps.count / 4).first ?? 0
            let even = typical > 0 ? Double(gaps.filter { gap in
                let beats = (gap / typical).rounded()
                return beats >= 1 && abs(gap / typical - beats) < 0.08 * beats
            }.count) / Double(max(1, gaps.count)) : 0
            print("SONG", score, String(format: "even %.0f%% sure %.2f", even * 100, moments.map(\.reading.confidence).reduce(0, +) / Double(max(1, moments.count))))
        }
    }

    /// A drum loop named with its tempo, looped to forty seconds, its beats starting again
    /// from its start each time round.
    static func loop(_ url: URL) -> MusicSignal? {
        let name = url.lastPathComponent
        guard let tempo = name.firstMatch(of: /(\d+) BPM/).flatMap({ Double($0.1) }), let loop = read(url) else { return nil }
        var samples: [Float] = []
        while Double(samples.count) < 40 * MusicSignal.rate { samples += loop }
        samples = Array(samples.prefix(Int(40 * MusicSignal.rate)))
        // Each time round, the beats start again from the loop's start at its named tempo: a
        // loop may carry a few milliseconds past its last bar.
        let length = Double(loop.count) / MusicSignal.rate
        let count = Int((length / (60 / tempo)).rounded(.down))
        var beats: [Double] = []
        for start in stride(from: 0, to: 40, by: length) {
            for index in 0..<count { beats.append(start + Double(index) * 60 / tempo) }
        }
        beats = beats.filter { $0 < 40 }
        return MusicSignal(name: String(name.dropFirst(18).prefix(26)), samples: samples, beats: beats, downbeats: stride(from: 0, to: beats.count, by: 4).map { beats[$0] }, steady: [6..<40])
    }

    /// How much the sound's arrivals repeat at its true beat: near 1 for drums on the beat,
    /// near 0 or below for a groove whose arrivals only repeat each bar, with no beat in them
    /// for any follower of arrivals to find.
    static func periodicity(_ signal: MusicSignal) -> Double {
        guard signal.beats.count > 1, let analyzer = SpectrumAnalyzer(size: SpectrumLayout.size(for: MusicSignal.rate), sampleRate: MusicSignal.rate, bandCount: 24) else { return 0 }
        let size = analyzer.size, rate = 100.0
        var gain = SpectrumGain()
        var flux: [Double] = [], last: [Float] = []
        var time = Double(size) / MusicSignal.rate
        while Int(time * MusicSignal.rate) + size / 2 < signal.samples.count {
            let centre = Int(time * MusicSignal.rate)
            let levels = gain.levels(for: analyzer.decibels(of: Array(signal.samples[(centre - size / 2)..<(centre + size / 2)])), elapsed: 1 / rate).map { pow(10, 46 * ($0 - 1) / 20) }
            flux.append(last.isEmpty ? 0 : Double(zip(levels, last).reduce(0) { $0 + max(0, $1.0 - $1.1) }))
            last = levels
            time += 1 / rate
        }
        let mean = flux.reduce(0, +) / Double(flux.count)
        let centred = flux.map { $0 - mean }
        func alike(_ lag: Int) -> Double {
            zip(centred, centred.dropFirst(lag)).reduce(0) { $0 + $1.0 * $1.1 } / Double(centred.count - lag)
        }
        let lag = Int(((signal.beats[1] - signal.beats[0]) * rate).rounded())
        return [lag - 1, lag, lag + 1].map(alike).max()! / alike(0)
    }

    static func read(_ url: URL, seconds: Double = 40) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let format = AVAudioFormat(standardFormatWithSampleRate: file.processingFormat.sampleRate, channels: file.processingFormat.channelCount),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(min(file.length, Int64(format.sampleRate * seconds)))),
              (try? file.read(into: buffer)) != nil, let channels = buffer.floatChannelData else { return nil }
        let count = Int(buffer.frameLength)
        var mono = [Float](repeating: 0, count: count)
        for channel in 0..<Int(format.channelCount) {
            for index in 0..<count { mono[index] += channels[channel][index] / Float(format.channelCount) }
        }
        guard format.sampleRate != MusicSignal.rate else { return mono }
        // To the rate the made-up music is measured at, near enough for drums.
        let ratio = format.sampleRate / MusicSignal.rate
        return (0..<Int(Double(count) / ratio)).map { mono[min(count - 1, Int(Double($0) * ratio))] }
    }
}
#endif

