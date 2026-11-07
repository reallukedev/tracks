import SwiftUI
import TracksCore

/// The sound, drawn, one of four ways: bars from low notes to high that spring with the music,
/// a glow of the cover's colours that swells with it, a halo of light blooming from behind the
/// cover on each beat, or a waveform of the last few seconds passing by. See ``BarsVisual``,
/// ``GlowVisual``, ``HaloVisual`` and ``WaveformVisual``.
///
/// It hears your own music. Apple Music plays where Tracks can't hear it, so for it the drawing
/// follows each song's beat, feel and loudness, learned from its preview (see
/// ``GrooveStore``): a quiet ballad moves gently, a loud dance track hits hard.
///
/// Paused, it settles and stops drawing, and off screen it doesn't draw at all. Under Reduce
/// Motion it's still.
struct StageVisualizerView: View {
    let style: StageVisualizer
    /// The cover's colours, deep to light.
    let palette: [Color]
    /// How lively the song is, 0 to 1, for its pace when its groove isn't known.
    let energy: Double
    let isPlaying: Bool
    /// Shared with Stage's background, so both move to the same moment of sound.
    let levels: SmoothedLevels
    /// The side of the cover centred in this view, for the glow and the halo around it.
    var cover: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isOnScreen) private var isOnScreen
    @Environment(PlayerModel.self) private var player: PlayerModel?
    /// The glow swells slowly and never flashes; the halo breathes on each beat.
    @State private var glow = SoftPulse(bloomAttack: 0.12, bloomRelease: 0.7)
    @State private var halo = SoftPulse(bloomAttack: 0.03, bloomRelease: 0.25)
    @State private var history = WaveHistory()
    @State private var springs = BarSprings()
    /// Set once the music has paused and the light has settled, so the drawing stops.
    @State private var isSettled = false

    var body: some View {
        let lights = Self.lights(palette, whiteness: style == .glow ? 0.06 : style == .bars ? 0.35 : 0.18)
        visual(lights)
            .accessibilityHidden(true)
            // Again on coming back on screen, so light caught mid-fall finishes settling.
            .task(id: [isPlaying, isOnScreen]) {
                isSettled = false
                guard !isPlaying else { return }
                // The glow's light and the drift take a few seconds to settle.
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                isSettled = true
            }
    }

    /// What a frame needs, from the view: kept apart from it so the Mac's display link can
    /// draw each frame without SwiftUI.
    private struct Drawing {
        let style: StageVisualizer
        let energy: Double
        let isPlaying: Bool
        let reduceMotion: Bool
        let cover: CGFloat
        let levels: SmoothedLevels
        let player: PlayerModel?
        let glow: SoftPulse
        let halo: SoftPulse
        let history: WaveHistory
        let springs: BarSprings

        func pulse(at time: Double) -> StagePulse {
            reduceMotion ? .still(isPlaying: isPlaying) : levels.next(
                heard: AudioLevelMeter.shared.current(),
                time: time,
                song: SongMoment(player: player, energy: energy),
                isPlaying: isPlaying
            )
        }

        func bars(_ pulse: StagePulse, time: Double, width: CGFloat) -> [Float] {
            let bars = BarsVisual.resampled(pulse.bands, count: BarsVisual.count(for: width))
            return reduceMotion
                ? bars
                : springs.step(toward: bars, kick: pulse.kick, time: time, liveliness: Double(pulse.activity), gentleness: Double(pulse.gentleness))
        }

        func eased(_ soft: SoftPulse, _ pulse: StagePulse, time: Double) -> (level: Double, bloom: Double) {
            if reduceMotion { return (isPlaying ? 0.5 : 0.2, 0) }
            soft.step(bands: pulse.bands, kick: pulse.kick, time: time)
            return (soft.level, soft.bloom)
        }

        func wave(_ pulse: StagePulse, time: Double, width: CGFloat) -> (samples: [Float], shift: Double) {
            let capacity = WaveformVisual.capacity(for: width)
            if reduceMotion { return (StageVisualizerView.stillWave(capacity: capacity, isPlaying: isPlaying), 0) }
            return history.step(WaveHistory.loudness(bands: pulse.bands, kick: pulse.kick), time: time, isPlaying: isPlaying, capacity: capacity)
        }
    }

    private var drawing: Drawing {
        Drawing(
            style: style, energy: energy, isPlaying: isPlaying, reduceMotion: reduceMotion, cover: cover,
            levels: levels, player: player, glow: glow, halo: halo, history: history, springs: springs
        )
    }

    private var isStill: Bool { style == .off || reduceMotion || isSettled }

    #if os(macOS)
    private func visual(_ lights: [Color]) -> some View {
        let drawing = drawing
        let light = lights[0].shaderComponents
        let glowColours = GlowVisual.colors(lights).map(\.shaderComponents)
        let ring = (lights + [lights[0]]).map(\.shaderComponents)
        // Every frame the display shows, so a drum lands the moment it's heard.
        // Soft light looks the same drawn at half the size; the bars and the waveform need
        // every pixel.
        let factor: CGFloat = style == .halo || style == .glow ? 2 : 1
        return BackdropCanvas(isMoving: !isStill, factor: factor, isOpaque: false) { frame in
            let pulse = drawing.pulse(at: frame.time)
            switch drawing.style {
            case .bars:
                let heights = drawing.bars(pulse, time: frame.time, width: frame.size.width)
                let kick = Float(drawing.reduceMotion ? 0 : pulse.kick)
                return BackdropDrawing(function: "barsFragment", inputs: [SIMD4(Float(heights.count), kick, 0, 0), light], values: heights)
            case .glow:
                let (level, bloom) = drawing.eased(drawing.glow, pulse, time: frame.time)
                let phase = drawing.reduceMotion ? 0 : pulse.motion
                let m = MeshInputs.make(
                    columns: 4, rows: 4,
                    points: GlowVisual.points(phase: phase, level: level),
                    colours: glowColours,
                    scale: Float(GlowVisual.scale(level: level, bloom: bloom))
                )
                return BackdropDrawing(
                    function: "glowFragment",
                    shape: .mesh(columns: 4, rows: 4, steps: 24, m: m),
                    inputs: [SIMD4(Float(GlowVisual.mask.lowerBound), Float(GlowVisual.mask.upperBound), Float(GlowVisual.opacity(level: level, bloom: bloom)), 0)]
                )
            case .halo:
                let (level, bloom) = drawing.eased(drawing.halo, pulse, time: frame.time)
                let phase = drawing.reduceMotion ? 0 : pulse.motion
                return BackdropDrawing(function: "haloFragment", inputs: [
                    SIMD4(Float(drawing.cover), Float(CoverImage.radius(for: drawing.cover)), Float(level), Float(bloom)),
                    SIMD4(Float(phase), Float(ring.count), 0, 0),
                ] + ring)
            case .waveform:
                let wave = drawing.wave(pulse, time: frame.time, width: frame.size.width)
                return BackdropDrawing(function: "waveformFragment", inputs: [
                    SIMD4(Float(wave.samples.count), Float(wave.shift), Float(WaveformVisual.width), Float(WaveformVisual.pitch)),
                ], values: wave.samples.isEmpty ? [0] : wave.samples)
            case .off:
                return nil
            }
        }
        .blendMode(.plusLighter)
    }
    #else
    private func visual(_ lights: [Color]) -> some View {
        let drawing = drawing
        return GeometryReader { proxy in
            // Every frame the display shows, so a drum lands the moment it's heard (see
            // ``BackdropFrameRate``).
            TimelineView(.animation(minimumInterval: BackdropFrameRate.everyFrame, paused: isStill || !isOnScreen)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                let pulse = drawing.pulse(at: time)
                let phase = reduceMotion ? 0 : pulse.motion
                switch style {
                case .bars:
                    BarsVisual(heights: drawing.bars(pulse, time: time, width: proxy.size.width), light: lights[0], kick: Double(reduceMotion ? 0 : pulse.kick))
                case .glow:
                    let (level, bloom) = drawing.eased(glow, pulse, time: time)
                    GlowVisual(colors: lights, level: level, bloom: bloom, phase: phase)
                case .halo:
                    let (level, bloom) = drawing.eased(halo, pulse, time: time)
                    HaloVisual(colors: lights, level: level, bloom: bloom, phase: phase, cover: cover, radius: CoverImage.radius(for: cover))
                case .waveform:
                    let wave = drawing.wave(pulse, time: time, width: proxy.size.width)
                    WaveformVisual(samples: wave.samples, shift: wave.shift)
                case .off:
                    Color.clear
                }
            }
        }
    }
    #endif

    /// The cover's colours as light, four at least.
    private static func lights(_ palette: [Color], whiteness: Double) -> [Color] {
        var found = palette.isEmpty ? [Color(white: 0.6), Color(white: 0.8)] : palette
        while found.count < 4 { found.append(found[found.count % max(1, palette.count)]) }
        return found.map { $0.asLight(whiteness: whiteness) }
    }

    /// A waveform that doesn't move, for Reduce Motion: a gentle, even rhythm while playing,
    /// a line of dots otherwise.
    fileprivate static func stillWave(capacity: Int, isPlaying: Bool) -> [Float] {
        guard isPlaying else { return [Float](repeating: 0, count: capacity) }
        return (0..<capacity).map { index in
            let beat = Float(index % 6) / 6
            return 0.18 + 0.22 * (1 - beat) * (index % 24 < 6 ? 1 : 0.7)
        }
    }
}

/// One frame of the music, for anything that moves with it.
struct StagePulse {
    /// Each band, 0 to 1, low notes to high.
    var bands: [Float]
    /// The kick, 0 to 1: full as it lands, then falling away.
    var kick: Float
    /// Seconds of motion so far, gathering quicker for a faster, livelier song, and stopped
    /// while paused: for what ripples and drifts, so a ballad breathes and a dance track hurries.
    var motion: Double
    /// How busy the music is, 0 to 1: how much it's been moving over the last few seconds.
    var activity: Float = 0
    /// How fast `motion` is gathering now: about 1 for a song at 120 beats a minute, easing
    /// to 0 on pause.
    var pace: Double = 0
    /// How gently the song moves, 0 to 1 (see `Groove.gentleness`): what's drawn glides for
    /// a ballad and springs for a dance track.
    var gentleness: Float = 0
    /// How surely `kick` lands where the song's own hits are, 0 to 1: heard, it lands where it's
    /// heard, beat or no beat.
    var lock: Float = 0
    /// How sure the song's beat is, 0 to 1, for what keeps time with its bars.
    var sureness: Float = 0
    /// Beats counted, the fraction how far into the current one, while there's a beat.
    var beats: Double?
    /// How hard the beats land and where the sound sits, dark to bright, when they're heard
    /// rather than known from the song's groove.
    var punch: Double?
    var brightness: Double?

    /// The low bands, where the bass and the kick are.
    var bass: Float { bands.prefix(5).reduce(0, +) / 5 }

    /// A frame that doesn't move, for Reduce Motion: a gentle, fuller-low shape while playing,
    /// resting otherwise.
    static func still(isPlaying: Bool) -> StagePulse {
        let count = AudioLevelMeter.bandCount
        let bands = isPlaying
            ? (0..<count).map { 0.32 - 0.14 * Float($0) / Float(count - 1) }
            : [Float](repeating: SmoothedLevels.resting, count: count)
        return StagePulse(bands: bands, kick: 0, motion: 0)
    }
}

/// What the drawing knows of the song playing: its groove, once learned (see ``GrooveStore``),
/// where it is, how long it is, and its feel.
struct SongMoment {
    var groove: Groove?
    var energy: Double
    /// Nil for a radio stream, which has no ends to ease.
    var duration: Double?
    /// Which song it is, so a new one's beat is found afresh.
    var id: String?
    private let player: PlayerModel?

    init(player: PlayerModel?, energy: Double) {
        groove = GrooveStore.shared.groove(for: player?.current)
        self.energy = energy
        duration = player?.current?.duration
        id = player?.current?.id
        self.player = player
    }

    /// Where the song is. Asked a few times a second rather than every frame, since asking
    /// Apple Music isn't free.
    func position() -> Double {
        player?.playbackTime ?? 0
    }
}

/// The music from one frame to the next, at the same pace whatever the frame rate.
///
/// Your own music is heard, band by band, and its beat found as it plays (see
/// ``BeatFollower``): what moves with it pulses on the song's own beats, carried on from the
/// moment measured to the moment each frame is seen, and a ballad or a held pad, with no sure
/// beat, glides and breathes instead. A song Tracks can't hear replays its preview's own sound
/// in time with where the song is (see ``GrooveTexture``), as if heard: every hit and fill,
/// every held chord and quiet moment, as strong as the song is loud. It pulses on the song's
/// own beat only once the preview is placed in the song. A groove learned before it kept its
/// sound plays back as hits on its beat (see ``GrooveLevels``). Until it's learned, or when it
/// can't be, a slow breath with no beat at all (see ``AmbientLevels``): a made-up beat against
/// the real one looks like random flashing.
///
/// How busy the music is, measured from how much it moves, and its tempo set the pace of
/// everything that drifts: a crowded dance track hurries, a ballad drifts.
final class SmoothedLevels {
    static let resting: Float = 0.04
    /// How long after the time a frame is drawn for that it's seen. The Mac draws each frame
    /// for the moment its display shows it (see ``BackdropCanvas``); a timeline's date on
    /// iPhone is when it was asked for, a frame or so before the screen shows it.
    #if os(macOS)
    static let presentationLead = 0.0
    #else
    static let presentationLead = 1.0 / 60
    #endif
    private var smoother = LevelSmoother(count: AudioLevelMeter.bandCount, resting: SmoothedLevels.resting)
    /// Each band's level over the last second or so, for what's new in it.
    private var settled: [Float] = []
    private var clock = PlaybackClock()
    private var askedAt: Double?
    /// A replay's beat, found as if heard (the meter finds what's heard), and the song it's
    /// followed in and how long the music's been paused, so a new song, or the same one after
    /// a while, finds its beat afresh rather than keeping the last.
    private var beat = BeatFollower()
    private var followed: String?
    private var pausedFor = 0.0
    private var kick: Float = 0
    private var motion: Double = 0
    private var pace: Double = 0
    private var activity: Float = 0
    private var gentleness = 0.0
    private var range: (floor: [Float], ceiling: [Float]) = ([], [])
    private var rangeKey: TextureKey?
    private var previous: [Float]?
    /// When they were last worked out: asked twice in one frame, by the background and the
    /// visualizer, they answer the same.
    private var lastTime: Double?
    private var last = StagePulse(bands: [Float](repeating: SmoothedLevels.resting, count: AudioLevelMeter.bandCount), kick: 0, motion: 0)

    private enum Source { case resting, heard, texture, groove, feel }

    func next(heard: HeardLevels?, time: Double, song: SongMoment, isPlaying: Bool) -> StagePulse {
        if let lastTime, abs(time - lastTime) < 0.004 { return last }
        let elapsed = min(max(lastTime.map { time - $0 } ?? 0, 0), 0.25)
        lastTime = time
        let count = AudioLevelMeter.bandCount
        let source: Source = if !isPlaying {
            .resting
        } else if let heard, heard.bands.count == count {
            .heard
        } else if let texture = song.groove?.texture, texture.isPlayable, texture.bandCount == count {
            .texture
        } else if let groove = song.groove, groove.confidence >= GrooveLevels.leastConfidence {
            .groove
        } else {
            .feel
        }
        pausedFor = source == .resting ? pausedFor + elapsed : 0
        if song.id != followed || pausedFor > 1 {
            followed = song.id
            beat = BeatFollower()
        }
        var hit: Float = 0
        var target: [Float]
        var found: BeatFollower.Reading?
        var lock: Float = 0
        var sureness: Float = 0
        var beats: Double?
        switch source {
        case .resting:
            target = [Float](repeating: Self.resting, count: count)
            askedAt = nil
        case .heard:
            target = heard?.bands ?? []
            found = heard?.beat
            // The beat carried on from the moment measured to the moment this frame is seen.
            if let heard { hit = heard.beat.pulse(after: time + Self.presentationLead - heard.heardAt) }
            lock = 1
            sureness = Float(found?.confidence ?? 0)
        case .texture:
            let groove = song.groove ?? .calm
            let position = position(of: song, at: time)
            let origin = groove.songOffset.map { $0 + (groove.texture?.start ?? 0) }
            let replayed = groove.texture?.levels(at: position, origin: origin) ?? []
            // What's new in each band stands out and what's held settles back, as a drum
            // stands out over a held chord to the ear: otherwise a dense mix holds every
            // band near the top and nothing seems to move.
            // Spread across the song's own range first, so a soft song moves as much as a
            // loud one.
            if let texture = groove.texture {
                let key = TextureKey(texture)
                if rangeKey != key { range = texture.bandRange(); rangeKey = key }
            }
            let spread = replayed.indices.map { band -> Float in
                guard band < range.floor.count else { return replayed[band] }
                return min(1, max(0, (replayed[band] - range.floor[band]) / (range.ceiling[band] - range.floor[band])))
            }
            if settled.count != spread.count { settled = spread }
            let follow = Float(1 - exp(-elapsed / 0.9))
            // Hits stand out only where they'll land on the song's own and the song has them
            // to give: a ballad, or a replay that can't be placed, swells and glides instead.
            let emphasis = Float(groove.lock * (1 - 0.75 * groove.gentleness))
            let fresh = zip(spread, settled).map { level, held in
                min(1, (1 - 0.5 * emphasis) * level + 1.3 * emphasis * max(0, level - held))
            }
            for index in settled.indices { settled[index] += (spread[index] - settled[index]) * follow }
            // A quiet song stays a little lower than a loud one, and its ends, which the
            // preview didn't hear, ease in and out.
            let strength = Float(0.6 + 0.4 * groove.intensity) * GrooveLevels.ease(time: position, duration: song.duration)
            target = fresh.map { Self.resting + max(0, $0 - Self.resting) * strength }
            // The replay's beat: the song's own, counted from the preview's first downbeat where
            // it falls in the song, at the moment this frame is seen. Not placed in the song,
            // the preview's beat would fall anywhere against what's heard, so it doesn't pulse;
            // it still moves with the replay's sound.
            let hasBeat = groove.confidence >= GrooveLevels.leastConfidence
            beat.tempoHint = hasBeat ? groove.tempo : nil
            let placed = hasBeat ? groove.beats(at: position + Self.presentationLead) : nil
            beat.knownBeats = placed
            if placed != nil {
                let sure = min(1, max(0, (groove.confidence - 0.2) / 0.3))
                beat.knownSureness = sure * sure * (3 - 2 * sure)
            }
            let reading = beat.step(replayed, elapsed: elapsed)
            found = reading
            hit = placed == nil ? 0 : reading.pulse
            lock = Float(groove.lock)
            sureness = placed == nil ? 0 : Float(reading.confidence)
        case .groove:
            let groove = song.groove ?? .calm
            let hits = GrooveLevels.hits(playbackTime: position(of: song, at: time), groove: groove, duration: song.duration)
            target = GrooveLevels.levels(hits: hits, groove: groove, count: count)
            // Its hits keep time from the song's start, which is only the song's own beat when
            // that's where its bars were learned from, as for a sample song's.
            let isPlaced = groove.songOffset == 0
            hit = isPlaced ? hits.kick : 0
            lock = Float(groove.lock)
            sureness = isPlaced ? Float(groove.lock) : 0
            beats = isPlaced ? hits.bars * 4 : nil
        case .feel:
            target = AmbientLevels.levels(at: time, energy: song.energy, count: count)
            // A song heard too unsure of its beat to show one still breathes as loud as it is.
            if let groove = song.groove {
                let intensity = Float(groove.intensity)
                target = target.map { Self.resting + ($0 - Self.resting) * intensity }
            }
        }
        // Once a bar, from the downbeat.
        if let found, found.confidence > 0 { beats = found.bar }
        // Heard or replayed, they follow the sound closely, quick up and a natural fall; from
        // a groove's hits, closer still, since the hits already have their own shape;
        // breathing, they ease.
        (smoother.attack, smoother.release) = switch source {
        case .heard: (0.02, 0.18)
        case .texture: Self.smoothing(for: song.groove)
        case .groove: (0.012, 0.08)
        case .feel: (0.3, 0.5)
        case .resting: (0.35, 0.45)
        }
        let bands = smoother.step(toward: target, elapsed: elapsed)
        // A found beat's pulse already falls away in time with the song, and is nothing with
        // no sure beat; anything else is up at once on a hit, then away quickly, so a pause
        // never cuts one off.
        kick = found != nil ? hit : max(hit, kick * Float(exp(-elapsed / 0.08)))

        // How busy: how far the bands travel a second, over the last couple of seconds. A
        // crowded track's bands are always on the move; a ballad's glide.
        if let previous, previous.count == bands.count, elapsed > 0 {
            let travel = zip(bands, previous).reduce(Float(0)) { $0 + abs($1.0 - $1.1) } / Float(bands.count)
            let busy = min(1, travel / Float(elapsed) / 1.4)
            activity += (busy - activity) * Float(1 - exp(-elapsed / 2))
        }
        previous = bands
        // A song at 120 beats a minute moves at about a second a second, quicker the busier
        // it is; paused, it glides to a stop. Heard, with no sure beat, it drifts calmly.
        let tempo: Double = switch source {
        case .heard: found?.tempo ?? 84
        case .texture: found?.tempo ?? song.groove?.tempo ?? 90
        case .groove: song.groove?.tempo ?? 90
        default: AmbientLevels.tempo(energy: song.energy)
        }
        let liveliness: Double = switch source {
        case .feel: song.energy
        case .heard, .texture: Double(activity) * (0.5 + 0.5 * (found?.drive ?? 0))
        default: Double(activity)
        }
        let goal = !isPlaying ? 0 : min(1.6, max(0.55, tempo / 120)) * (0.8 + 0.8 * liveliness)
        pace += (goal - pace) * (1 - exp(-elapsed / 0.6))
        motion = (motion + elapsed * pace).truncatingRemainder(dividingBy: 100_000)
        // Heard or replayed, how gently it moves is how little drives it; otherwise the
        // groove's own, and a breath that knows nothing of the song sits in between.
        let gentle: Double = switch source {
        case .heard, .texture: 1 - (found?.drive ?? 0)
        case .groove: song.groove?.gentleness ?? 0
        case .feel: 0.6
        case .resting: gentleness
        }
        gentleness += (gentle - gentleness) * (1 - exp(-elapsed / 1.5))
        var pulse = StagePulse(bands: bands, kick: kick, motion: motion, activity: activity, pace: pace, gentleness: Float(gentleness))
        pulse.lock = lock
        pulse.sureness = sureness
        pulse.beats = beats
        pulse.punch = found?.punch
        pulse.brightness = found?.brightness
        last = pulse
        return pulse
    }

    /// How closely a replay follows its sound: closely where its hits land in time, easing
    /// into swells for a ballad, or where they can't be placed.
    private static func smoothing(for groove: Groove?) -> (attack: Double, release: Double) {
        let soft = max(groove?.gentleness ?? 0.5, 1 - (groove?.lock ?? 0))
        return (0.03 + 0.1 * soft, 0.2 + 0.35 * soft)
    }

    /// Which texture a band range was worked out for.
    private struct TextureKey: Equatable {
        let size: Int, start: Double, chunk: Double

        init(_ texture: GrooveTexture) {
            (size, start, chunk) = (texture.levels.count, texture.start, texture.chunkSeconds)
        }
    }

    /// Where the song is: asked a few times a second, and carried on smoothly in between.
    private func position(of song: SongMoment, at time: Double) -> Double {
        if let askedAt, time - askedAt < 0.25, let carried = clock.position(at: time) {
            return carried
        }
        askedAt = time
        return clock.position(reported: song.position(), at: time, isPlaying: true)
    }
}
