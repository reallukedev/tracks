import Foundation
import Accelerate

/// Learns a song's ``Groove`` from a stretch of its sound, such as Apple Music's half-minute
/// preview: its tempo, where in a bar each drum lands, how its sound is spread, and how hard
/// it hits.
///
/// It listens as a drummer counting in would: it marks each moment the sound jumps, finds the
/// gap those jumps repeat at most, and then, bar by bar, where in the bar the low, middle and
/// high jumps fall. Slow work, a fraction of a second for a preview, so it runs once a song
/// and away from the main thread.
public nonisolated enum GrooveAnalysis {
    /// The slowest and fastest beat it settles on. Faster or slower, a song is felt at half or
    /// twice its count, and that's how the drawing should move.
    public static let tempoRange = 60.0...200.0

    /// `samples`, one channel, at `sampleRate`.
    public static func groove(of samples: [Float], sampleRate: Double, bandCount: Int = 24) -> Groove {
        let level = Level(samples, sampleRate: sampleRate)
        guard let heard = Heard(samples, sampleRate: sampleRate, bandCount: bandCount) else {
            var calm = Groove.calm
            // Silence is known to be silent, so nothing moves for it.
            calm.loudness = level?.loudness
            return calm
        }
        let sorted = heard.all.sorted()
        let peaks = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.97))]
        // Each line is scaled to its own loudest jumps, so with nothing jumping more than half
        // a decibel, a beat found in them would be one found in the hiss.
        guard peaks > 0.5, let pulse = pulse(of: heard.beatline, rate: heard.rate), pulse.confidence > 0.06 else {
            var calm = Groove.calm
            calm.shape = shape(heard.decibels, frames: heard.frames, bandCount: bandCount)
            calm.loudness = level?.loudness
            calm.loudnessRange = level?.range
            calm.texture = texture(of: samples, sampleRate: sampleRate, bandCount: bandCount, start: 0, chunk: GrooveTexture.freeChunk, seconds: GrooveTexture.freeChunk)
            return calm
        }
        let period = pulse.period
        var lanes = [heard.low, heard.mid, heard.high].map { lane($0, period: period, phase: pulse.phase) }

        // The bar starts where the kick is strongest on a beat, ahead of the snare.
        let downbeat = stride(from: 0, to: Groove.steps, by: 4).max { first, second in
            lanes[0].hits[first] - 0.5 * lanes[1].hits[first] < lanes[0].hits[second] - 0.5 * lanes[1].hits[second]
        } ?? 0
        let strongest = max(1e-6, lanes.map { $0.hits.max() ?? 0 }.max() ?? 0)
        lanes = lanes.map { finished($0, rotatedBy: downbeat, strongest: strongest) }
        let first = pulse.phase + Double(downbeat / 4) * period
        let bars = level.flatMap { bars(heard, level: $0, period: period, downbeat: first) }
        let tempo = steadied(60 * heard.rate / period)

        return Groove(
            tempo: tempo,
            confidence: Double(min(1, pulse.confidence * 1.6 * min(1, peaks / 1.5))),
            low: lanes[0], mid: lanes[1], high: lanes[2],
            shape: shape(heard.decibels, frames: heard.frames, bandCount: bandCount),
            dynamics: dynamics(heard.loudness, framesPerBar: Int(period * 4)),
            punch: Double(min(1, max(0, peaks / 6))),
            brightness: brightness(heard.decibels, frames: heard.frames, bandCount: bandCount),
            loudness: level?.loudness,
            loudnessRange: level?.range,
            beats: bars?.beats,
            bars: bars?.loudness,
            texture: texture(of: samples, sampleRate: sampleRate, bandCount: bandCount, start: first / heard.rate + heard.delay, chunk: period * 4 / heard.rate, seconds: 240 / tempo)
        )
    }

    /// The stretch's sound in chunks `chunk` seconds long from `start` seconds in, each lasting
    /// `seconds` when replayed: heard as the meter hears your own music, through the same
    /// transform, so it looks the same. Each frame holds the loudest moment of its
    /// thirty-second, so a hit is never missed, the loudest the stretch gets near full and 46
    /// decibels below it nothing. Whole chunks only, from at least a second and a half in to a
    /// second and a half from the end, as a preview fades in and out.
    private static func texture(of samples: [Float], sampleRate: Double, bandCount: Int, start: Double, chunk: Double, seconds: Double) -> GrooveTexture? {
        let size = SpectrumLayout.size(for: sampleRate)
        let hop = size / 4
        guard chunk > 0, seconds > 0, samples.count > size * 2,
              let analyzer = SpectrumAnalyzer(size: size, sampleRate: sampleRate, bandCount: bandCount) else { return nil }
        let frames = (samples.count - size) / hop + 1
        var decibels = [Float](repeating: -120, count: frames * bandCount)
        samples.withUnsafeBufferPointer { buffer in
            for frame in 0..<frames {
                let bands = analyzer.decibels(of: UnsafeBufferPointer(rebasing: buffer[frame * hop ..< frame * hop + size]))
                for band in 0..<bandCount { decibels[frame * bandCount + band] = bands[band].isFinite ? bands[band] : -120 }
            }
        }
        let loudest = (0..<frames).map { decibels[$0 * bandCount ..< ($0 + 1) * bandCount].max() ?? -120 }.sorted()
        let top = loudest[min(frames - 1, Int(Double(frames) * 0.99))] + 3
        let range: Float = 46
        // A frame stands for the middle of its window.
        func frame(at time: Double) -> Double { (time * sampleRate - Double(size) / 2) / Double(hop) }
        let duration = Double(samples.count) / sampleRate
        let width = chunk / Double(GrooveTexture.framesPerChunk)
        var levels = Data()
        var first: Double?
        var place = start
        while place + chunk <= duration - 1.5 {
            if place >= 1.5 {
                first = first ?? place
                for slice in 0..<GrooveTexture.framesPerChunk {
                    let from = place + Double(slice) * width
                    let low = min(frames - 1, max(0, Int(frame(at: from).rounded(.up))))
                    let high = min(frames - 1, max(low, Int(frame(at: from + width).rounded(.down))))
                    for band in 0..<bandCount {
                        var peak: Float = -120
                        for index in low...high { peak = max(peak, decibels[index * bandCount + band]) }
                        let level = min(1, max(0, (peak - (top - range)) / range))
                        levels.append(UInt8((level * 255).rounded()))
                    }
                }
            }
            place += chunk
        }
        guard let first else { return nil }
        let texture = GrooveTexture(chunkSeconds: seconds, bandCount: bandCount, levels: levels, start: first)
        return texture.isPlayable ? texture : nil
    }

    /// How loud a stretch of sound is: as a whole, in LUFS, how far it ranges, and, for any
    /// part of it, how loud that part is.
    struct Level {
        let loudness: Double
        let range: Double
        let sampleRate: Double
        let duration: Double
        /// Running sums of the weighted sound's squares, for the loudness of any stretch.
        private let sums: [Double]

        init?(_ samples: [Float], sampleRate: Double) {
            guard sampleRate.isFinite, sampleRate >= 8_000, Double(samples.count) >= sampleRate * 4 else { return nil }
            let weighted = Loudness.weighted(samples, sampleRate: sampleRate)
            let blocks = Loudness.blocks(weighted, sampleRate: sampleRate)
            loudness = Loudness.integrated(blocks)
            range = Loudness.range(blocks)
            self.sampleRate = sampleRate
            duration = Double(samples.count) / sampleRate
            var sums = [Double](repeating: 0, count: weighted.count + 1)
            for index in weighted.indices { sums[index + 1] = sums[index] + Double(weighted[index]) * Double(weighted[index]) }
            self.sums = sums
        }

        /// The loudness from `start` to `end` seconds, in LU above or below the whole's.
        func relative(from start: Double, to end: Double) -> Double {
            let first = min(sums.count - 1, max(0, Int(start * sampleRate)))
            let last = min(sums.count - 1, max(first + 1, Int(end * sampleRate)))
            guard last > first else { return 0 }
            return Loudness.lufs(meanSquare: (sums[last] - sums[first]) / Double(last - first)) - loudness
        }
    }

    /// Bar by bar from the first downbeat at frame `downbeat`: how hard each beat landed,
    /// 0 to 1 against the stretch's strong ones, and how loud each bar was against the whole.
    /// The first and last seconds are left out, since a preview fades in and out.
    private static func bars(_ heard: Heard, level: Level, period: Double, downbeat: Double) -> (beats: [Float], loudness: [Float])? {
        guard period > 0, level.loudness > Loudness.silence else { return nil }
        let reach = max(1, Int(period / 8))
        var strengths: [Float] = []
        var loudness: [Float] = []
        var start = downbeat
        while Int(start + period * 4) + reach < heard.frames {
            let from = start / heard.rate + heard.delay, to = (start + period * 4) / heard.rate + heard.delay
            if from >= 1.5, to <= level.duration - 2 {
                for beat in 0..<4 {
                    let centre = Int((start + Double(beat) * period).rounded())
                    let low = max(0, centre - reach), high = min(heard.frames - 1, centre + reach)
                    let jump = low <= high ? heard.beatline[low...high].max() ?? 0 : 0
                    // A jump is measured in decibels, the same for a soft hit as a hard one;
                    // weighed by how loud the moment of the hit is, it's as hard as it sounds.
                    let time = Double(centre) / heard.rate + heard.delay
                    let loud = pow(2, level.relative(from: time - 0.03, to: time + 0.12) / Loudness.halving)
                    strengths.append(jump * Float(loud.isFinite ? loud : 0))
                }
                loudness.append(Float(level.relative(from: from, to: to)))
            }
            start += period * 4
        }
        guard loudness.count >= 2 else { return nil }
        let sorted = strengths.sorted()
        let strong = max(1e-6, sorted[Int(Double(sorted.count - 1) * 0.9)])
        return (strengths.map { min(1, max(0, $0 / strong)) }, loudness)
    }

    /// The beats of a stretch of sound, as the analysis hears them: its tempo, and each beat's
    /// time in seconds from the start of `samples`. For checking it against music.
    public static func beats(of samples: [Float], sampleRate: Double, bandCount: Int = 24) -> (tempo: Double, times: [Double])? {
        guard let heard = Heard(samples, sampleRate: sampleRate, bandCount: bandCount),
              let pulse = pulse(of: heard.beatline, rate: heard.rate) else { return nil }
        let times = stride(from: pulse.phase, to: Double(heard.frames), by: pulse.period).map { $0 / heard.rate + heard.delay }
        return (steadied(60 * heard.rate / pulse.period), times)
    }

    /// A stretch of sound, moment by moment: each band's loudness, and how far the low, middle
    /// and high bands jumped.
    private struct Heard {
        let rate: Double
        let frames: Int
        /// Seconds from a frame's start to the moment it stands for, the middle of its window.
        let delay: Double
        let decibels: [Float]
        let loudness: [Float]
        let low: [Float]
        let mid: [Float]
        let high: [Float]
        let all: [Float]
        /// The jumps that carry the beat.
        let beatline: [Float]

        init?(_ samples: [Float], sampleRate: Double, bandCount: Int) {
            guard sampleRate.isFinite, sampleRate >= 8_000, bandCount >= 8,
                  Double(samples.count) >= sampleRate * 4 else { return nil }
            let size = max(1024, SpectrumLayout.size(for: sampleRate) / 2)
            let hop = size / 4
            guard let analyzer = SpectrumAnalyzer(size: size, sampleRate: sampleRate, bandCount: bandCount) else { return nil }
            rate = sampleRate / Double(hop)
            delay = Double(size) / 2 / sampleRate

            var clean = samples
            for index in clean.indices where !clean[index].isFinite { clean[index] = 0 }
            let frames = (clean.count - size) / hop + 1
            self.frames = frames
            var decibels = [Float](repeating: -120, count: frames * bandCount)
            var loudness = [Float](repeating: -120, count: frames)
            clean.withUnsafeBufferPointer { buffer in
                for frame in 0..<frames {
                    let window = UnsafeBufferPointer(rebasing: buffer[frame * hop ..< frame * hop + size])
                    let bands = analyzer.decibels(of: window)
                    for band in 0..<bandCount { decibels[frame * bandCount + band] = bands[band] }
                    var rms: Float = 0
                    vDSP_rmsqv(window.baseAddress!, 1, &rms, vDSP_Length(size))
                    loudness[frame] = 20 * log10(max(rms, 1e-6))
                }
            }
            let loudest = decibels.max() ?? -120
            guard loudest.isFinite, loudest > -70 else { return nil }
            // Anything far below the loudest is the room, not the music.
            for index in decibels.indices { decibels[index] = max(loudest - 60, decibels[index]) }
            self.decibels = decibels
            self.loudness = loudness

            let groups = Groups(bandCount: bandCount)
            let span = max(2, Int(rate * 0.25))
            func jumps(_ bands: Range<Int>) -> [Float] {
                standingOut(rise(decibels, frames: frames, bandCount: bandCount, bands: bands), span: span)
            }
            low = jumps(groups.low)
            mid = jumps(groups.mid)
            high = jumps(groups.high)
            all = jumps(0..<bandCount)
            // The beat is carried by the kick and the snare; hats and melody split it into
            // eighths and sixteenths, which pull a count to twice the tempo or a third off it.
            beatline = blend([(low, 1), (mid, 0.8), (high, 0.35)])
        }
    }

    /// How far each frame's `bands` rose since the frame before, on average.
    private static func rise(_ decibels: [Float], frames: Int, bandCount: Int, bands: Range<Int>) -> [Float] {
        var out = [Float](repeating: 0, count: frames)
        guard !bands.isEmpty else { return out }
        for frame in 1..<frames {
            var sum: Float = 0
            for band in bands { sum += max(0, decibels[frame * bandCount + band] - decibels[(frame - 1) * bandCount + band]) }
            out[frame] = sum / Float(bands.count)
        }
        return out
    }

    /// Each line scaled so its strong moments stand at 1, then weighed and added.
    private static func blend(_ lines: [([Float], Float)]) -> [Float] {
        guard let count = lines.first?.0.count else { return [] }
        var out = [Float](repeating: 0, count: count)
        for (line, weight) in lines {
            let sorted = line.sorted()
            let strong = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.98))]
            guard strong > 1e-6 else { continue }
            let scale = weight / strong
            for index in out.indices { out[index] += min(line[index] * scale, weight * 2) }
        }
        return out
    }

    /// Most studio recordings are played to a click at a whole number of beats a minute. A
    /// count within a hair of one is taken as it, so the beat doesn't creep over four minutes.
    static func steadied(_ tempo: Double) -> Double {
        let whole = tempo.rounded()
        return abs(tempo - whole) < 0.15 ? whole : tempo
    }

    /// The beat in `onsets`: its length and where the first falls, in frames, and how clearly
    /// it repeats, 0 to 1.
    struct Pulse {
        var period: Double
        var phase: Double
        var confidence: Float
    }

    /// Finds the beat as a listener tapping along would. Each candidate length is scored by how
    /// well the jumps line up with themselves one to four beats on, gently weighed toward the
    /// tempos most songs are felt at, around 120, then tuned against as many beats as the
    /// stretch holds. That's the count. Then each beat is found near where the count puts it,
    /// and a line through them all gives the tempo to a hundredth of a beat a minute and where
    /// the beats fall.
    static func pulse(of onsets: [Float], rate: Double) -> Pulse? {
        let count = onsets.count
        let shortest = rate * 60 / tempoRange.upperBound
        let longest = rate * 60 / tempoRange.lowerBound
        let maxLag = min(count - 1, max(Int(longest * 4) + 4, count * 2 / 3))
        guard count > 8, Double(maxLag) > longest * 2 else { return nil }
        var mean: Float = 0
        vDSP_meanv(onsets, 1, &mean, vDSP_Length(count))
        let centred = onsets.map { $0 - mean }
        var match = [Float](repeating: 0, count: maxLag + 1)
        centred.withUnsafeBufferPointer { values in
            for lag in 0...maxLag {
                var sum: Float = 0
                vDSP_dotpr(values.baseAddress!, 1, values.baseAddress! + lag, 1, &sum, vDSP_Length(count - lag))
                match[lag] = sum / Float(count - lag)
            }
        }
        guard match[0] > 1e-9 else { return nil }
        // The best match near `lag`, since a beat a little off a whole frame smears over two.
        func near(_ lag: Double) -> Float {
            let low = Int((lag - 1).rounded(.down)), high = Int((lag + 1).rounded(.up))
            guard low >= 0, high <= maxLag else { return 0 }
            return match[low...high].max() ?? 0
        }
        func along(_ lag: Double) -> Float {
            max(0, (1...4).reduce(0) { $0 + near(lag * Double($1)) } / 4)
        }
        func score(_ lag: Double) -> Float {
            let bpm = rate * 60 / lag
            let prior = Float(exp(-0.5 * pow(log2(bpm / 120) / 0.9, 2)))
            return along(lag) * (0.6 + 0.4 * prior)
        }
        let candidates = stride(from: shortest, through: longest, by: 0.25)
        guard let coarse = candidates.max(by: { score($0) < score($1) }), score(coarse) > 0 else { return nil }

        // Finer, by how well the jumps line up as many beats on as the stretch allows.
        func lined(_ lag: Double) -> Float {
            var total: Float = 0
            var beats = 1.0
            while lag * beats + 1 < Double(maxLag) {
                total += near(lag * beats)
                beats += 1
            }
            return total / Float(max(1, beats - 1))
        }
        var period = stride(from: coarse - 0.5, through: coarse + 0.5, by: 0.02).max { lined($0) < lined($1) } ?? coarse
        var phase = bestPhase(onsets, period: period)
        // Kick and snare taking turns line up best two beats apart, which reads as half the
        // tempo. If halfway between the beats it found lands nearly as hard as on them, those
        // are beats too, not the eighths between them.
        if period / 2 >= shortest * 0.98 {
            func strength(at offset: Double) -> Double {
                var total = 0.0, place = phase + offset
                while Int(place.rounded()) + 1 < count {
                    let index = Int(place.rounded())
                    total += Double(max(onsets[max(0, index - 1)], onsets[index], onsets[index + 1]))
                    place += period
                }
                return total
            }
            if strength(at: period / 2) >= strength(at: 0) * 0.85 {
                period /= 2
                phase = bestPhase(onsets, period: period)
            }
        }
        let sorted = onsets.sorted()
        let strong = Double(sorted[min(count - 1, Int(Double(count) * 0.95))])
        // Each beat where it really landed, following the music from one to the next as a
        // listener would, so a count a little off doesn't wander off the beat; then a line
        // through them all, leaving out the few it caught that aren't on it.
        for _ in 0..<3 {
            var points: [(beat: Double, time: Double, weight: Double)] = []
            let reach = period / 6
            var expected = phase
            var beat = 0.0
            while expected + reach < Double(count - 2) {
                let low = max(1, Int((expected - reach).rounded(.down))), high = Int((expected + reach).rounded(.up))
                var top = low
                for index in low...high where onsets[index] > onsets[top] { top = index }
                let (left, middle, right) = (Double(onsets[top - 1]), Double(onsets[top]), Double(onsets[top + 1]))
                if middle > strong * 0.3, top > low, top < high {
                    let curve = left - 2 * middle + right
                    let shift = curve < 0 ? min(0.5, max(-0.5, 0.5 * (left - right) / curve)) : 0
                    let time = Double(top) + shift
                    points.append((beat, time, middle))
                    // Halfway to where it was heard, so one stray jump can't pull the count off.
                    expected = (expected + time) / 2 + period
                } else {
                    expected += period
                }
                beat += 1
            }
            guard var line = fit(points), points.count >= 8 else { break }
            let kept = points.filter { abs($0.time - (line.phase + line.period * $0.beat)) < period / 12 }
            if kept.count >= 8, let refit = fit(kept) { line = refit }
            // A line far from the count means it caught something else; keep the count.
            guard abs(line.period - period) < period * 0.04 else { break }
            period = line.period
            phase = line.phase - (line.phase / period).rounded(.down) * period
        }
        let confidence = max(0, min(1, max(near(period), near(period * 2)) / match[0]))
        return Pulse(period: period, phase: phase, confidence: confidence)
    }

    /// The straight line through `points`, each counted by its weight.
    private static func fit(_ points: [(beat: Double, time: Double, weight: Double)]) -> (period: Double, phase: Double)? {
        let total = points.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        let meanBeat = points.reduce(0) { $0 + $1.weight * $1.beat } / total
        let meanTime = points.reduce(0) { $0 + $1.weight * $1.time } / total
        let spread = points.reduce(0) { $0 + $1.weight * pow($1.beat - meanBeat, 2) }
        guard spread > 0 else { return nil }
        let slope = points.reduce(0) { $0 + $1.weight * ($1.beat - meanBeat) * ($1.time - meanTime) } / spread
        return (slope, meanTime - slope * meanBeat)
    }

    /// Where the beats fall, in frames from the start: the offset the jumps line up with best.
    private static func bestPhase(_ onsets: [Float], period: Double) -> Double {
        var best = (phase: 0.0, total: -Float.infinity)
        for phase in stride(from: 0, to: period, by: 0.5) {
            var total: Float = 0
            var place = phase
            while Int(place.rounded()) + 1 < onsets.count {
                let index = Int(place.rounded())
                total += max(onsets[index], 0.5 * max(onsets[index - (index > 0 ? 1 : 0)], onsets[index + 1]))
                place += period
            }
            if total > best.total { best = (phase, total) }
        }
        return best.phase
    }

    /// The bands each drum sounds loudest in, out of `bandCount` from 40 Hz to 16 kHz: the
    /// kick under 140 Hz, the snare's body and crack from 300 Hz to 3 kHz, the hats over 6 kHz.
    private struct Groups {
        let low: Range<Int>
        let mid: Range<Int>
        let high: Range<Int>

        init(bandCount: Int) {
            func band(_ hertz: Double) -> Int {
                Int((log(hertz / 40) / log(16_000.0 / 40) * Double(bandCount)).rounded())
            }
            low = 0..<max(1, band(140))
            mid = band(300)..<max(band(300) + 1, band(3_000))
            high = band(6_000)..<bandCount
        }
    }

    /// `values` less their average over `span` either side, never below nothing: the jumps
    /// that stand out from what's around them.
    private static func standingOut(_ values: [Float], span: Int) -> [Float] {
        var prefix = [Float](repeating: 0, count: values.count + 1)
        for index in values.indices { prefix[index + 1] = prefix[index] + values[index] }
        return values.indices.map { index in
            let start = max(0, index - span), end = min(values.count, index + span + 1)
            let average = (prefix[end] - prefix[start]) / Float(end - start)
            return max(0, values[index] - average)
        }
    }

    /// Bar by bar, how hard the jumps land around each sixteenth, and how far off it.
    private static func lane(_ onsets: [Float], period: Double, phase: Double) -> GrooveLane {
        let step = period / 4
        let reach = max(1, Int(step / 2))
        var hits = [Float](repeating: 0, count: Groove.steps)
        var lean = [Float](repeating: 0, count: Groove.steps)
        var bars = 0
        var start = phase
        while Int(start + period * 4) + reach < onsets.count {
            for place in 0..<Groove.steps {
                let centre = Int((start + Double(place) * step).rounded())
                var strongest: Float = 0
                var at = 0
                for offset in -reach...reach where centre + offset >= 0 && onsets[centre + offset] > strongest {
                    strongest = onsets[centre + offset]
                    at = offset
                }
                hits[place] += strongest
                lean[place] += strongest * Float(at) / Float(step)
            }
            bars += 1
            start += period * 4
        }
        guard bars > 0 else { return .quiet }
        for place in 0..<Groove.steps {
            lean[place] = hits[place] > 0 ? lean[place] / hits[place] : 0
            hits[place] /= Float(bars)
        }
        return GrooveLane(hits: hits, lean: lean)
    }

    /// The lane turned so the bar starts at `rotation`, its hits 0 to 1, and quieter than the
    /// other drums by as much as it is.
    private static func finished(_ lane: GrooveLane, rotatedBy rotation: Int, strongest: Float) -> GrooveLane {
        let turn = { (values: [Float]) in (0..<Groove.steps).map { values[($0 + rotation) % Groove.steps] } }
        let hits = turn(lane.hits), lean = turn(lane.lean)
        let top = hits.max() ?? 0
        guard top > 1e-6 else { return .quiet }
        let mean = hits.reduce(0, +) / Float(hits.count)
        let base = 0.5 * mean
        let scale = min(1, max(0.25, top / strongest * 1.3))
        let shaped = hits.map { top - base > 1e-6 ? min(1, max(0, ($0 - base) / (top - base))) * scale : scale }
        return GrooveLane(
            hits: shaped,
            lean: zip(shaped, lean).map { $0 > 0.15 ? min(0.5, max(-0.5, $1)) : 0 }
        )
    }

    /// Each band's average loudness, 0 to 1, as the meter would show it.
    private static func shape(_ decibels: [Float], frames: Int, bandCount: Int) -> [Float] {
        var average = [Float](repeating: 0, count: bandCount)
        for frame in 0..<frames {
            for band in 0..<bandCount { average[band] += decibels[frame * bandCount + band] }
        }
        average = average.map { $0 / Float(max(1, frames)) }
        let top = (average.max() ?? 0) + 3
        return average.map { min(1, max(0, ($0 - (top - 40)) / 40)) }
    }

    /// How far the loud bars stand above the quiet ones, 0 to 1, a twelve-decibel spread full.
    private static func dynamics(_ loudness: [Float], framesPerBar: Int) -> Double {
        guard framesPerBar > 0, loudness.count >= framesPerBar * 2 else { return 0 }
        let bars = stride(from: 0, to: loudness.count - framesPerBar + 1, by: framesPerBar).map { start in
            loudness[start ..< start + framesPerBar].reduce(0, +) / Float(framesPerBar)
        }.sorted()
        let quiet = bars[bars.count / 10], loud = bars[bars.count * 9 / 10]
        return Double(min(1, max(0, (loud - quiet) / 12)))
    }

    /// Where the sound's power sits across the bands, 0 at the lowest to 1 at the highest.
    private static func brightness(_ decibels: [Float], frames: Int, bandCount: Int) -> Double {
        var power = [Double](repeating: 0, count: bandCount)
        for frame in 0..<frames {
            for band in 0..<bandCount { power[band] += pow(10, Double(decibels[frame * bandCount + band]) / 10) }
        }
        let total = power.reduce(0, +)
        guard total > 0, total.isFinite else { return 0.5 }
        let centre = power.enumerated().reduce(0) { $0 + Double($1.offset) * $1.element } / total
        return min(1, max(0, centre / Double(bandCount - 1)))
    }
}
