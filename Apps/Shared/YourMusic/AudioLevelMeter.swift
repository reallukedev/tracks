import AVFoundation
import MediaToolbox
import Synchronization
import TracksCore
import os

/// How loud each part of the sound is right now, low notes to high, for Stage's visualizer and
/// the backgrounds that move with the music.
///
/// Your own music plays through AVFoundation, so each song gets a tap that copies its sound,
/// both channels mixed to one, into a few seconds of buffer on its way out. That's all the
/// audio thread does. The measuring, and finding the beat, happen on a queue of their own
/// while something draws with them (see ``LevelAnalysis``): the moment of sound around what's
/// being heard right then, by the song's own clock. The tap hands sound over well before it's
/// heard, so the picture lands with the sound rather than ahead of it.
///
/// The gain rides each song so a loud master and a quiet one fill the same height, and a gentle
/// stretch after it spreads bars that keep to a narrow part of it (see ``LevelContrast``).
///
/// Apple Music plays in a process Tracks can't tap. On the Mac, the Mac's own sound is heard
/// instead, once it's allowed (see ``SystemAudioListener``); on iPhone, or until then, there
/// are no levels, and the visualizer plays back each song's groove (see ``GrooveStore``).
nonisolated final class AudioLevelMeter: @unchecked Sendable {
    static let shared = AudioLevelMeter()
    static let bandCount = 24

    /// How many views want levels. Read on the audio thread, so it's an atomic, not a lock.
    private let listeners = Atomic<Int>(0)

    private init() {}

    // MARK: - Watching

    func startListening() {
        let (_, now) = listeners.add(1, ordering: .relaxed)
        #if os(macOS)
        if now == 1 { SystemAudioListener.shared.start() }
        #endif
    }

    func stopListening() {
        let (_, now) = listeners.subtract(1, ordering: .relaxed)
        #if os(macOS)
        if now == 0 { SystemAudioListener.shared.stop() }
        #endif
    }

    fileprivate var isListening: Bool { listeners.load(ordering: .relaxed) > 0 }

    // MARK: - Measuring

    /// The songs being heard: each one's sound and the item that plays it.
    @MainActor private var songs: [Song] = []
    /// The clocks of the songs last handed to the analysis, to hand them over only on a change.
    @MainActor private var handedOver: [ObjectIdentifier] = []
    private let analysis = LevelAnalysis()

    @MainActor private struct Song {
        weak var item: AVPlayerItem?
        let sound: HeardSound
    }

    /// The bands, 0 to 1, low to high, and the beat, for what's being heard now. Nil when
    /// nothing Tracks can hear is playing. Measured on a queue of its own while something
    /// draws with it, so this only reads the latest.
    @MainActor
    func current() -> HeardLevels? {
        songs.removeAll { $0.item == nil }
        // Before it's ready to play an item has no clock, so it's looked for each time.
        let playing = songs.compactMap { song in song.item?.timebase.map { (song.sound, $0) } }
        let clocks = playing.map { ObjectIdentifier($0.1) }
        if clocks != handedOver {
            handedOver = clocks
            analysis.hear(playing.map { LevelAnalysis.Source(sound: $0.0, timebase: $0.1) })
        }
        return analysis.latest()
    }

    // MARK: - Hearing a song

    /// Gives a song's player item a tap that hands its sound to the meter. The item plays just
    /// as before; the tap only listens. Only before it starts: a mix set on a song already
    /// playing rebuilds how its sound is made, which can stall or stop it, so a stream whose
    /// tracks took longer to load than it took to start goes without.
    @MainActor
    static func attach(to item: AVPlayerItem, asset: AVAsset) {
        Task { @MainActor in
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return }
            if let timebase = item.timebase, CMTimebaseGetRate(timebase) != 0 { return }
            let sound = HeardSound()
            guard let tap = makeTap(for: sound) else { return }
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            item.audioMix = mix
            // Songs gone are dropped here too, not only when a visualizer draws: with none
            // showing, each one's few seconds of sound would be kept all day.
            shared.songs.removeAll { $0.item == nil }
            shared.songs.append(Song(item: item, sound: sound))
        }
    }

    private static func makeTap(for sound: HeardSound) -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(sound).toOpaque(),
            init: { _, clientInfo, storage in
                storage.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<HeardSound>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                Unmanaged<HeardSound>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(format.pointee)
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                var range = CMTimeRange.invalid
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, &range, framesOut) == noErr,
                      AudioLevelMeter.shared.isListening else { return }
                let sound = Unmanaged<HeardSound>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                sound.hear(buffers, frames: Int(framesOut.pointee), at: range.start)
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        return status == noErr ? tap : nil
    }
}

/// A moment of what's heard, band by band, 0 to 1 low to high, as drawn: stretched so a quiet or
/// crowded master still moves (see ``LevelContrast``). And its beat, found as it plays (see
/// ``BeatFollower``).
nonisolated struct HeardLevels: Sendable {
    var bands: [Float]
    var beat: BeatFollower.Reading
    /// When the moment measured is heard, by `CFAbsoluteTimeGetCurrent`: what draws later
    /// carries the beat on from here to the moment it reaches the screen.
    var heardAt: Double
}

/// Measures what's heard, off the main thread: as often as what draws with it asks, thirty or
/// sixty times a second, and not at all once nothing has asked for a moment, so paused or hidden it
/// costs nothing. Each time, the moment of sound being heard right then, by the song's own
/// clock, which already allows for the delay through the speakers, AirPlay included.
nonisolated final class LevelAnalysis: @unchecked Sendable {
    struct Source: @unchecked Sendable {
        let sound: HeardSound
        /// Read from any thread: a timebase is safe to share.
        let timebase: CMTimebase
    }

    private struct Shared {
        var sources: [Source] = []
        var levels: HeardLevels?
        var askedAt: Double = 0
        /// The shortest time between asks lately, so it measures no more often than it's drawn.
        var askEvery = 1.0 / 30
        var isRunning = false
    }

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let queue = DispatchQueue(label: "Tracks.LevelAnalysis", qos: .userInteractive)

    // Only touched on `queue`.
    private var timer: DispatchSourceTimer?
    private var interval = 1.0 / 30
    private var analyzers: [Int: SpectrumAnalyzer] = [:]
    private var window: [Float] = []
    private var gain = SpectrumGain()
    private var contrast = LevelContrast()
    private var beat = BeatFollower()
    private var lastTick: Double?
    /// The sound the beat is being found in, and when anything was last heard, so a new song,
    /// or music back after a while, finds its beat afresh.
    private var followed: ObjectIdentifier?
    private var lastHeard = -Double.infinity

    /// Has nothing asked for this long, it stops.
    private static let idle = 0.5

    func hear(_ sources: [Source]) {
        shared.withLock { $0.sources = sources }
    }

    /// The latest, and keeps it measuring while it's asked for.
    func latest() -> HeardLevels? {
        let now = Self.now()
        let (levels, start) = shared.withLock { shared in
            let gap = now - shared.askedAt
            if gap > 0.004 {
                // Quick to speed up, slow to let a faster drawing go.
                shared.askEvery = gap < shared.askEvery ? gap : shared.askEvery + (gap - shared.askEvery) * 0.02
            }
            shared.askedAt = now
            let start = !shared.isRunning
            shared.isRunning = true
            return (shared.levels, start)
        }
        if start { queue.async { self.run() } }
        return levels
    }

    private func run() {
        guard timer == nil else { return }
        lastTick = nil
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [unowned self] in tick() }
        self.timer = timer
        timer.resume()
    }

    private func tick() {
        let now = Self.now()
        let asked = shared.withLock { shared -> (sources: [Source], every: Double)? in
            guard now - shared.askedAt < Self.idle else {
                shared.isRunning = false
                shared.levels = nil
                return nil
            }
            return (shared.sources, shared.askEvery)
        }
        guard let (sources, every) = asked else {
            timer?.cancel()
            timer = nil
            return
        }
        let wanted = every < 0.025 ? 1.0 / 60 : 1.0 / 30
        if wanted != interval {
            interval = wanted
            timer?.schedule(deadline: .now() + wanted, repeating: wanted, leeway: .milliseconds(2))
        }
        let elapsed = min(max(lastTick.map { now - $0 } ?? 0, 0), 0.25)
        lastTick = now
        let levels = measure(sources, elapsed: elapsed, at: now)
        shared.withLock { $0.levels = levels }
    }

    private func measure(_ sources: [Source], elapsed: Double, at now: Double) -> HeardLevels? {
        var total: [Float]?
        var heard: ObjectIdentifier?
        var heardAt = now
        #if DEBUG
        if let rehearsed = rehearsal(at: now) {
            total = rehearsed
            heard = ObjectIdentifier(self)
        }
        #endif
        for source in sources {
            guard CMTimebaseGetRate(source.timebase) != 0 else { continue }
            let time = CMTimebaseGetTime(source.timebase)
            guard time.isNumeric, let (decibels, centre) = measure(source.sound, at: time.seconds) else { continue }
            // Two songs meeting, gaplessly, add up as sound does; the beat is the newer one's.
            total = total.map { zip($0, decibels).map { 10 * log10(pow(10, $0 / 10) + pow(10, $1 / 10)) } } ?? decibels
            heard = ObjectIdentifier(source.sound)
            heardAt = now - (time.seconds - centre)
        }
        #if os(macOS)
        // Apple Music, or anything else playing on the Mac, heard as it goes to the speakers.
        let mac = SystemAudioListener.shared
        if total == nil, mac.isHearing {
            let time = SystemAudioListener.now()
            if let (decibels, centre) = measure(mac.sound, at: time) {
                total = decibels
                heardAt = now - (time - centre)
            }
            heard = ObjectIdentifier(mac.sound)
        }
        #endif
        guard let total, let heard else { return nil }
        if heard != followed || now - lastHeard > 4 {
            followed = heard
            beat = BeatFollower()
        }
        lastHeard = now
        let even = gain.levels(for: total, elapsed: elapsed)
        // The beat from the sound only evened out: the stretch moves with the music and would
        // read as new sound.
        let reading = beat.step(even, elapsed: elapsed)
        return HeardLevels(bands: contrast.apply(even, elapsed: elapsed), beat: reading, heardAt: heardAt)
    }

    private func analyzer(for rate: Double) -> SpectrumAnalyzer? {
        if let found = analyzers[Int(rate)] { return found }
        let made = SpectrumAnalyzer(size: SpectrumLayout.size(for: rate), sampleRate: rate, bandCount: AudioLevelMeter.bandCount)
        analyzers[Int(rate)] = made
        return made
    }

    /// The moment around `time`, and where its window's centre fell, which is earlier when the
    /// sound around `time` hasn't all arrived yet.
    private func measure(_ sound: HeardSound, at time: Double) -> (decibels: [Float], centre: Double)? {
        guard let rate = sound.sampleRate, let analyzer = analyzer(for: rate) else { return nil }
        let size = analyzer.size
        if window.count != size { window = [Float](repeating: 0, count: size) }
        // Centred on the moment heard, so the picture is neither early nor late.
        guard let centre = sound.copy(around: time, into: &window) else { return nil }
        return (analyzer.decibels(of: window), centre)
    }

    private static func now() -> Double { CFAbsoluteTimeGetCurrent() }

    #if DEBUG
    /// `-TracksVisualizerRehearsal /path/to/song.m4a` in a Debug build: that file, heard as if
    /// it were playing, over and over, without a sound, so what moves with the music can be
    /// seen with real music in the demo, whose songs make no sound.
    private var rehearsalSound: (samples: [Float], rate: Double, start: Double)?
    private var rehearsalLoaded = false

    private func rehearsal(at now: Double) -> [Float]? {
        if !rehearsalLoaded {
            rehearsalLoaded = true
            if let path = UserDefaults.standard.string(forKey: "TracksVisualizerRehearsal"),
               let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
               let format = AVAudioFormat(standardFormatWithSampleRate: file.processingFormat.sampleRate, channels: file.processingFormat.channelCount),
               let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(min(file.length, Int64(format.sampleRate * 120)))),
               (try? file.read(into: buffer)) != nil, let channels = buffer.floatChannelData {
                let count = Int(buffer.frameLength)
                var mono = [Float](repeating: 0, count: count)
                for channel in 0..<Int(format.channelCount) {
                    for index in 0..<count { mono[index] += channels[channel][index] / Float(format.channelCount) }
                }
                rehearsalSound = (mono, format.sampleRate, now)
            }
        }
        guard let sound = rehearsalSound, let analyzer = analyzer(for: sound.rate) else { return nil }
        let size = analyzer.size
        guard sound.samples.count > size * 2 else { return nil }
        if window.count != size { window = [Float](repeating: 0, count: size) }
        let span = sound.samples.count - size
        let first = Int((now - sound.start) * sound.rate) % span
        for index in 0..<size { window[index] = sound.samples[first + index] }
        return analyzer.decibels(of: window)
    }
    #endif
}

/// One song's sound, or the Mac's: the last few seconds of it, both channels mixed to one, and where in the
/// song they are. Written on the audio thread, without allocating; read when a frame's drawn.
nonisolated final class HeardSound: @unchecked Sendable {
    private struct Ring {
        var samples: [Float] = []
        var sampleRate: Double = 0
        var channels = 1
        var isInterleaved = false
        var isFloat = false
        /// Samples written, all told; the newest is at `written - 1`.
        var written = 0
        /// The song's time just after the newest sample.
        var end: Double = 0
        /// The first sample of the current run: before it, the song was somewhere else.
        var runStart = 0
    }

    private let ring = OSAllocatedUnfairLock(initialState: Ring())

    var sampleRate: Double? {
        ring.withLock { $0.sampleRate > 0 && !$0.samples.isEmpty ? $0.sampleRate : nil }
    }

    /// Sets aside about three seconds: enough for what AVFoundation hands over ahead of the
    /// speakers, and AirPlay's longer wait.
    func prepare(_ format: AudioStreamBasicDescription) {
        let rate = format.mSampleRate > 0 ? format.mSampleRate : 44_100
        var capacity = 1 << 16
        while Double(capacity) < rate * 3 { capacity <<= 1 }
        ring.withLockUnchecked { ring in
            ring = Ring()
            ring.samples = [Float](repeating: 0, count: capacity)
            ring.sampleRate = rate
            ring.channels = max(1, Int(format.mChannelsPerFrame))
            ring.isInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            ring.isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
        }
    }

    /// Copies a moment of sound in, its channels mixed to one. On the audio thread.
    func hear(_ buffers: UnsafeMutablePointer<AudioBufferList>, frames: Int, at start: CMTime) {
        guard frames > 0 else { return }
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        ring.withLockUnchecked { ring in
            guard ring.isFloat, !ring.samples.isEmpty else { return }
            let time = start.isNumeric ? start.seconds : ring.end
            // A seek, or the first sound after a while unheard: a new run.
            if abs(time - ring.end) * ring.sampleRate > 2 {
                ring.runStart = ring.written
            }
            let capacity = ring.samples.count
            let mask = capacity - 1
            let channels = ring.channels
            let isInterleaved = ring.isInterleaved
            let written = ring.written
            // Plain loops over pointers: this runs for every buffer of sound, even in a Debug
            // build, where a range's iterator costs more than the copying.
            ring.samples.withUnsafeMutableBufferPointer { out in
                guard let out = out.baseAddress else { return }
                if isInterleaved, let data = list.first?.mData {
                    let input = data.assumingMemoryBound(to: Float.self)
                    let share = 1 / Float(channels)
                    var frame = 0
                    while frame < frames {
                        var sum: Float = 0
                        var channel = 0
                        while channel < channels {
                            sum += input[frame * channels + channel]
                            channel += 1
                        }
                        out[(written + frame) & mask] = sum * share
                        frame += 1
                    }
                } else {
                    let present = list.reduce(0) { $0 + ($1.mData == nil ? 0 : 1) }
                    let share = 1 / Float(max(1, present))
                    var isFirst = true
                    for buffer in list {
                        guard let data = buffer.mData else { continue }
                        let input = data.assumingMemoryBound(to: Float.self)
                        var frame = 0
                        while frame < frames {
                            let index = (written + frame) & mask
                            out[index] = (isFirst ? 0 : out[index]) + input[frame] * share
                            frame += 1
                        }
                        isFirst = false
                    }
                    if isFirst {
                        var frame = 0
                        while frame < frames {
                            out[(written + frame) & mask] = 0
                            frame += 1
                        }
                    }
                }
            }
            ring.written += frames
            ring.end = time + Double(frames) / ring.sampleRate
        }
    }

    /// Fills `window` with the sound around `time` in the song, and says the song's time at
    /// its centre. Nil if that moment isn't here: not yet handed over, long gone, or from
    /// before a seek.
    func copy(around time: Double, into window: inout [Float]) -> Double? {
        ring.withLockUnchecked { ring -> Double? in
            guard ring.sampleRate > 0, ring.written > 0 else { return nil }
            let size = window.count
            let capacity = ring.samples.count
            let oldest = max(ring.runStart, ring.written - capacity)
            // The sample being heard, then the window around it, slid back to what's arrived.
            let heard = ring.written - Int(((ring.end - time) * ring.sampleRate).rounded())
            var first = min(heard - size / 2, ring.written - size)
            if first < oldest {
                // Over a quarter of a second off, it's not this moment any more.
                guard oldest - first < Int(ring.sampleRate / 4), ring.written - oldest >= size else { return nil }
                first = oldest
            }
            guard heard > oldest - Int(ring.sampleRate / 4), heard < ring.written + Int(ring.sampleRate / 4) else { return nil }
            let mask = capacity - 1
            // In at most two runs, as the ring wraps: copied whole, since this is asked for
            // every frame something moves with the music.
            let start = first & mask
            let head = min(size, capacity - start)
            ring.samples.withUnsafeBufferPointer { samples in
                window.withUnsafeMutableBufferPointer { out in
                    guard let from = samples.baseAddress, let to = out.baseAddress else { return }
                    to.update(from: from + start, count: head)
                    if head < size { (to + head).update(from: from, count: size - head) }
                }
            }
            return ring.end - Double(ring.written - (first + size / 2)) / ring.sampleRate
        }
    }
}
