import Foundation
@testable import TracksCore

/// Runs sound through the same steps the app does, frame by frame: each moment measured,
/// evened out to the song's level, its beat followed, then felt by Living Cover. Then measures
/// each move against the music's true beats.
struct BeatHarness {
    /// The analysis's own rate: the app measures 60 times a second while something draws at 120.
    var fps = 60.0

    struct Moment: Sendable {
        var time: Double
        var reading: BeatFollower.Reading
        var frame: LivingCoverFeel.Frame
        var stirred: Double
        var sway: Double
    }

    func listen(to samples: [Float], rate: Double = MusicSignal.rate) -> [Moment] {
        guard let analyzer = SpectrumAnalyzer(size: SpectrumLayout.size(for: rate), sampleRate: rate, bandCount: 24) else { return [] }
        var gain = SpectrumGain()
        var contrast = LevelContrast()
        var smoother = LevelSmoother(count: 24, resting: 0.04, attack: 0.02, release: 0.18)
        var beat = BeatFollower()
        var feel = LivingCoverFeel()
        var activity: Float = 0
        var previous: [Float]?
        let size = analyzer.size
        let dt = 1 / fps
        var moments: [Moment] = []
        var window = [Float](repeating: 0, count: size)
        var time = Double(size) / rate
        while Int(time * rate) + size / 2 < samples.count {
            // Centred on the moment heard, as the app measures it.
            let centre = Int(time * rate)
            for index in 0..<size { window[index] = samples[centre - size / 2 + index] }
            let even = gain.levels(for: analyzer.decibels(of: window), elapsed: dt)
            let reading = beat.step(even, elapsed: dt)
            let bands = smoother.step(toward: contrast.apply(even, elapsed: dt), elapsed: dt)
            if let previous {
                let travel = zip(bands, previous).reduce(Float(0)) { $0 + abs($1.0 - $1.1) } / Float(bands.count)
                activity += (min(1, travel / Float(dt) / 1.4) - activity) * Float(1 - exp(-dt / 2))
            }
            previous = bands
            let character = LivingCoverFeel.Character(punch: reading.punch, brightness: reading.brightness, intensity: 0.75, lock: 1, gentleness: 1 - reading.drive, sureness: reading.confidence)
            let frame = feel.step(bands: bands, kick: reading.pulse, activity: activity, beats: reading.confidence > 0 ? reading.beats : nil, isPlaying: true, character: character, elapsed: dt)
            moments.append(Moment(time: time, reading: reading, frame: frame, stirred: feel.stirred, sway: feel.sway))
            time += dt
        }
        return moments
    }
}

/// How well what moves keeps time with the music, and how often each move shows.
struct BeatScore: CustomStringConvertible {
    var name = ""
    /// Pulses a minute, all told and where there's a beat.
    var pulses = 0.0
    /// Of the pulses where there's a beat, the share within 50 ms of a true one.
    var onBeat = 1.0
    /// The middle of how far pulses land from their beats, in ms, and on average, signed.
    var medianError = 0.0
    var meanError = 0.0
    /// Of the true beats where there's a beat, the share that got a pulse.
    var coverage = 0.0
    /// Pulses more than 70 ms from any beat.
    var offBeat = 0
    /// Of the pulses on beats, how much harder those on downbeats are than the rest.
    var downbeatAccent = 0.0
    var tempo: Double?
    /// Each move's times a minute past the first few seconds, and the part of the time it sways.
    var swirl = 0.0, glint = 0.0, swell = 0.0, lift = 0.0, breath = 0.0, swaying = 0.0

    /// Where each pulse starts: a frame whose pulse jumps up.
    static func pulseStarts(_ moments: [BeatHarness.Moment]) -> [(time: Double, height: Float)] {
        zip(moments, moments.dropFirst()).compactMap { before, after in
            after.reading.pulse >= 0.1 && after.reading.pulse > before.reading.pulse + 0.08 ? (after.time, after.reading.pulse) : nil
        }
    }

    static func times(_ values: [Double], above: Double, below: Double, minutes: Double) -> Double {
        var armed = true, count = 0
        for value in values {
            if armed, value > above { count += 1; armed = false }
            if value < below { armed = true }
        }
        return Double(count) / minutes
    }

    init(_ signal: MusicSignal, _ moments: [BeatHarness.Moment], settle: Double = 5) {
        name = signal.name
        let starts = Self.pulseStarts(moments).filter { $0.time >= settle }
        let span = max(1, (moments.last?.time ?? 0) - settle)
        pulses = Double(starts.count) / (span / 60)
        func nearest(_ time: Double) -> (error: Double, beat: Double)? {
            signal.beats.min { abs($0 - time) < abs($1 - time) }.map { (time - $0, $0) }
        }
        let inSteady = starts.filter { start in signal.steady.contains { $0.contains(start.time) } }
        let errors = inSteady.compactMap { nearest($0.time)?.error }
        if !errors.isEmpty {
            onBeat = Double(errors.filter { abs($0) <= 0.05 }.count) / Double(errors.count)
            let sorted = errors.map(abs).sorted()
            medianError = sorted[sorted.count / 2] * 1000
            meanError = errors.reduce(0, +) / Double(errors.count) * 1000
        } else if signal.expectsPulses {
            onBeat = 0
        }
        offBeat = starts.filter { start in (nearest(start.time).map { abs($0.error) } ?? .infinity) > 0.07 }.count
        let steadyBeats = signal.beats.filter { beat in signal.steady.contains { $0.contains(beat) } }
        if !steadyBeats.isEmpty {
            let hit = steadyBeats.filter { beat in starts.contains { abs($0.time - beat) <= 0.05 } }
            coverage = Double(hit.count) / Double(steadyBeats.count)
        }
        let downbeats = Set(signal.downbeats.map { Int(($0 * 1000).rounded()) })
        var down: [Float] = [], other: [Float] = []
        for start in inSteady {
            guard let beat = nearest(start.time), abs(beat.error) <= 0.05 else { continue }
            if downbeats.contains(Int((beat.beat * 1000).rounded())) { down.append(start.height) } else { other.append(start.height) }
        }
        if !down.isEmpty, !other.isEmpty {
            downbeatAccent = Double(down.reduce(0, +) / Float(down.count)) / Double(other.reduce(0, +) / Float(other.count))
        }
        tempo = moments.last?.reading.tempo

        let late = moments.filter { $0.time >= settle }
        guard late.count > 2 else { return }
        let minutes = (late.last!.time - late.first!.time) / 60
        swirl = Self.times(late.map { abs($0.stirred) }, above: 0.25, below: 0.08, minutes: minutes)
        glint = Self.times(late.map(\.frame.shimmer), above: 0.25, below: 0.1, minutes: minutes)
        swell = Self.times(late.map(\.frame.swell), above: 0.6, below: 0.45, minutes: minutes)
        lift = Self.times(late.map(\.frame.lift), above: 0.3, below: 0.1, minutes: minutes)
        breath = Self.times(late.map { abs($0.frame.breath) }, above: 0.15, below: 0.05, minutes: minutes)
        swaying = Double(late.filter { $0.sway > 0.1 }.count) / Double(late.count)
    }

    var description: String {
        func f(_ value: Double, _ digits: Int = 0) -> String { String(format: "%.\(digits)f", value) }
        return [
            name.padding(toLength: 26, withPad: " ", startingAt: 0),
            "tempo \(tempo.map { f($0, 1) } ?? "-")".padding(toLength: 12, withPad: " ", startingAt: 0),
            "pulse/min \(f(pulses))".padding(toLength: 14, withPad: " ", startingAt: 0),
            "on beat \(f(onBeat * 100))%".padding(toLength: 13, withPad: " ", startingAt: 0),
            "median \(f(medianError))ms".padding(toLength: 13, withPad: " ", startingAt: 0),
            "mean \(f(meanError))ms".padding(toLength: 12, withPad: " ", startingAt: 0),
            "covers \(f(coverage * 100))%".padding(toLength: 12, withPad: " ", startingAt: 0),
            "off \(offBeat)".padding(toLength: 7, withPad: " ", startingAt: 0),
            "down x\(f(downbeatAccent, 2))".padding(toLength: 11, withPad: " ", startingAt: 0),
            "swirl \(f(swirl)) glint \(f(glint)) swell \(f(swell)) lift \(f(lift)) breath \(f(breath)) sway \(f(swaying * 100))%",
        ].joined(separator: " ")
    }
}
