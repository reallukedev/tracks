import SwiftUI
import TracksCore

/// Keeps a background's time: running while `isMoving`, gliding to a stop when it isn't and
/// picking up from there, and drawing nothing new once it's still. Livelier songs run a
/// little faster, easing into the new pace rather than jumping to it.
struct BackdropTimeline<Content: View>: View {
    let isMoving: Bool
    var rate: Double = 1
    /// Where the time starts, in seconds.
    var start: Double = 0
    /// Frames a second, or nil for every frame the display shows.
    var frameRate: Double? = 30
    @ViewBuilder let content: (Double) -> Content
    @State private var clock: BackdropClock?
    @State private var isAtRest = false
    @Environment(\.isOnScreen) private var isOnScreen

    var body: some View {
        // Low Power Mode keeps the motion, at fewer frames: at these speeds it barely shows.
        let interval = LowPowerMode.shared.isOn ? 1 / min(frameRate ?? 20, 20) : frameRate.map { 1 / $0 }
        TimelineView(.animation(minimumInterval: interval, paused: isAtRest || !isOnScreen)) { context in
            content(clock?.phase(at: context.date.timeIntervalSinceReferenceDate) ?? start)
        }
        .keepsBackdropTime(isMoving: isMoving, rate: rate, start: start, clock: $clock, isAtRest: $isAtRest)
    }
}

#if os(macOS)
/// ``BackdropTimeline`` drawn by Metal, for the Mac (see ``BackdropCanvas``): `draw` is given
/// the time and the frame, its moment and the view's size.
struct BackdropCanvasTimeline: View {
    let isMoving: Bool
    var rate: Double = 1
    var start: Double = 0
    var frameRate: Double? = 30
    /// Drawn at this fraction of its size and stretched.
    var factor: CGFloat = 1
    let draw: @MainActor (_ time: Double, _ frame: BackdropFrame) -> BackdropDrawing?
    @State private var clock: BackdropClock?
    @State private var isAtRest = false

    var body: some View {
        BackdropCanvas(isMoving: !isAtRest, frameRate: frameRate, factor: factor) { [clock, start, draw] frame in
            draw(clock?.phase(at: frame.time) ?? start, frame)
        }
        .keepsBackdropTime(isMoving: isMoving, rate: rate, start: start, clock: $clock, isAtRest: $isAtRest)
    }
}
#endif

extension View {
    /// Runs `clock` at `rate` while `isMoving`, and sets `isAtRest` once it's glided to a stop.
    fileprivate func keepsBackdropTime(isMoving: Bool, rate: Double, start: Double, clock: Binding<BackdropClock?>, isAtRest: Binding<Bool>) -> some View {
        let speed = isMoving ? rate : 0
        return task(id: speed) {
            let now = Date.now.timeIntervalSinceReferenceDate
            var next = clock.wrappedValue ?? BackdropClock(speed: speed, at: now, phase: start)
            next.setSpeed(speed, at: now)
            clock.wrappedValue = next
            guard let wait = next.secondsToRest(from: now) else {
                isAtRest.wrappedValue = false
                return
            }
            if wait > 0 {
                isAtRest.wrappedValue = false
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
            }
            isAtRest.wrappedValue = true
        }
    }
}

/// Draws `content` at a fraction of the size and stretches it to fill: a soft field looks
/// the same, for a small part of the work and memory.
struct StretchedBackdrop<Content: View>: View {
    let factor: CGFloat
    @ViewBuilder let content: (CGSize) -> Content

    var body: some View {
        GeometryReader { proxy in
            let small = CGSize(width: max(1, (proxy.size.width / factor).rounded(.up)), height: max(1, (proxy.size.height / factor).rounded(.up)))
            content(small)
                .frame(width: small.width, height: small.height)
                .drawingGroup()
                .scaleEffect(factor, anchor: .topLeading)
        }
    }
}

/// How lively the song on is, for how fast a background flows: 0.75 for the calmest, 1.25
/// for the liveliest.
private struct FlowRate {
    static func of(_ player: PlayerModel?) -> Double {
        0.75 + 0.5 * songEnergy(player?.current)
    }
}

/// Artwork: the cover, large and soft, filling the player, turning slowly while it plays.
///
/// Drawn from the cover at 96 pixels, softened once and stretched: it looks the same as a
/// full cover blurred, for a sliver of the memory. A blur the size of the window would hold
/// a picture of a quarter of a gigabyte on a large display.
struct ArtworkBackdrop: View {
    let art: BackdropArt
    let isMoving: Bool

    var body: some View {
        moving
            .background(art.field)
            .overlay {
                // Deeper toward the foot, where the controls are.
                LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
            }
    }

    /// One slow breath every 40 seconds, and a sway half as fast.
    private static func motion(at time: Double) -> (breath: Double, sway: Double) {
        (sin(time * 2 * .pi / 40), sin(time * .pi / 40 + 1))
    }

    #if os(macOS)
    private var moving: some View {
        let field = art.field.shaderComponents
        // A picture this soft looks the same drawn at a quarter of the size.
        return BackdropCanvasTimeline(isMoving: isMoving, start: art.start, factor: 4) { [art] time, frame in
            let (breath, sway) = Self.motion(at: time)
            let size = frame.size
            return BackdropDrawing(function: "artworkFragment", inputs: [
                SIMD4(Float(1.4 + 0.1 * breath), Float(7 * sway * .pi / 180), Float(size.width * 0.04 * breath), Float(size.height * 0.03 * sway)),
                field,
                SIMD4(1, 0, 0, 0),
            ], picture: art.soft)
        }
    }
    #else
    private var moving: some View {
        GeometryReader { proxy in
            BackdropTimeline(isMoving: isMoving, start: art.start, frameRate: 30) { time in
                let (breath, sway) = Self.motion(at: time)
                Image(decorative: art.soft, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scaleEffect(1.4 + 0.1 * breath)
                    .rotationEffect(.degrees(7 * sway))
                    .offset(x: proxy.size.width * 0.04 * breath, y: proxy.size.height * 0.03 * sway)
            }
            // Clipped first, so only what's on screen is made readable.
            .clipped()
            .colorEffect(ShaderLibrary.readableColour(.float(1.3), .float(0.5)))
        }
    }
    #endif
}

/// Living Cover: the cover itself, flowing. Its colours swirl and fold into one another as
/// ink does in water, turning slowly the way Music's animated backgrounds do, for as long
/// as the music plays, and settle when it's paused. See `livingCover` in Backdrops.metal.
///
/// Set to move with the music, as it is unless turned off in Settings, it feels the song as
/// well as flowing with it (see ``LivingCoverFeel``): it leans in as the bass fills out, is
/// pushed softly from the middle on each beat and sways once a bar in time with it, stirs on
/// the snare and glints with the cymbals; it deepens as the song gets loud, folds more as it
/// gets busy, and breathes with a quiet passage's swells. It pulses only on the song's own
/// beat, found as it plays (see ``BeatFollower``), so a ballad with no sure beat never jolts:
/// it glides and breathes. Its flow keeps the music's tempo, speeding up through a chorus,
/// surging on each beat and gliding down through a breakdown, and each of its layers turns
/// with its own part of the sound; when the music jumps to loud it opens out for a moment.
/// Nothing in it flashes: every part eases in and out at a pace of its own. Turned off, it
/// flows on its own, at a calm pace, and doesn't listen.
struct LivingCoverBackdrop: View {
    let art: BackdropArt
    let isMoving: Bool
    @Environment(PlayerModel.self) private var player: PlayerModel?
    @Environment(\.backdropLevels) private var sharedLevels
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage(LivingCoverOption.movesWithMusic) private var movesWithMusic = true
    @State private var ownLevels = SmoothedLevels()
    @State private var feel = LivingCoverMotion()

    var body: some View {
        ZStack {
            moving
            // Its flow keeps a different time with the music and without it, so turning it on
            // or off crosses over rather than jumping, the one leaving staying whole until it's
            // covered so nothing dips to black.
            .id(movesWithMusic)
            .transition(.asymmetric(insertion: .opacity, removal: .opacity.animation(.linear(duration: 0.05).delay(0.6))))
        }
        .animation(.easeInOut(duration: 0.6), value: movesWithMusic)
        .overlay {
            LinearGradient(stops: [
                .init(color: .black.opacity(0), location: 0.4),
                .init(color: .black.opacity(0.3), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .listensToAudio(movesWithMusic)
    }

    /// Every frame the display shows: a beat's push lands with the beat.
    @ViewBuilder private var moving: some View {
        let listening = movesWithMusic ? Listening(player: player, energy: songEnergy(player?.current), levels: sharedLevels ?? ownLevels, feel: feel, contrast: contrast) : nil
        #if os(macOS)
        BackdropCanvasTimeline(isMoving: isMoving, rate: FlowRate.of(player), start: art.start, frameRate: nil, factor: 4) { [art, isMoving] time, moment in
            // At the frame's own moment, as Stage's visualizer hears it, so both share one.
            let frame = listening.map { Self.felt($0, art: art, isMoving: isMoving, at: moment.time) } ?? Self.calm(at: time)
            return Self.drawing(cover: art.flowing, frame: frame)
        }
        #else
        BackdropTimeline(isMoving: isMoving, rate: FlowRate.of(player), start: art.start, frameRate: nil) { time in
            let frame = listening.map { Self.felt($0, art: art, isMoving: isMoving, at: Date.now.timeIntervalSinceReferenceDate) } ?? Self.calm(at: time)
            StretchedBackdrop(factor: 4) { size in
                Rectangle().fill(Self.shader(size: size, cover: art.flowing, frame: frame))
            }
        }
        #endif
    }

    /// What it listens with, for each frame.
    private struct Listening {
        let player: PlayerModel?
        let energy: Double
        let levels: SmoothedLevels
        let feel: LivingCoverMotion
        let contrast: ColorSchemeContrast
    }

    /// This moment of the music, felt: how the cover moves with it, and where its flow and
    /// its layers' turns are, each keeping time with its part of the music.
    private static func felt(_ listening: Listening, art: BackdropArt, isMoving: Bool, at now: Double) -> LivingCoverFeel.Frame {
        let song = SongMoment(player: listening.player, energy: listening.energy)
        let heard = AudioLevelMeter.shared.current()
        let pulse = listening.levels.next(heard: heard, time: now, song: song, isPlaying: isMoving)
        var character = LivingCoverFeel.Character(groove: song.groove, isHeard: heard != nil)
        // As the sound itself has it, when it's heard or replayed.
        character.gentleness = Double(pulse.gentleness)
        character.lock = Double(pulse.lock)
        character.sureness = Double(pulse.sureness)
        if let punch = pulse.punch { character.punch = punch }
        if let brightness = pulse.brightness { character.brightness = brightness }
        var frame = listening.feel.step(pulse, isPlaying: isMoving, character: character, time: now)
        // Specks of light make words harder to read; with Increase Contrast, none.
        if listening.contrast == .increased { frame.shimmer = 0 }
        // Each song's cover starts from a place of its own, as it does without the music.
        frame.flow += art.start
        frame.deep += art.start
        frame.middle += art.start
        frame.top += art.start
        return frame
    }

    /// Flowing on its own: every layer on the one clock, nothing else moving.
    private static func calm(at time: Double) -> LivingCoverFeel.Frame {
        var frame = LivingCoverFeel.Frame.rest
        (frame.flow, frame.deep, frame.middle, frame.top) = (time, time, time, time)
        return frame
    }

    private static func phase(_ value: Double) -> Double { value.truncatingRemainder(dividingBy: 20_000) }

    #if os(macOS)
    private static func drawing(cover: CGImage, frame: LivingCoverFeel.Frame) -> BackdropDrawing {
        BackdropDrawing(function: "livingCoverFragment", inputs: [
            SIMD4(Float(phase(frame.deep)), Float(phase(frame.middle)), Float(phase(frame.top)), Float(phase(frame.flow))),
            SIMD4(Float(frame.swell), Float(frame.thump), Float(frame.twist), Float(frame.shimmer)),
            SIMD4(Float(frame.body), Float(frame.churn), Float(frame.breath), Float(frame.warmth)),
            SIMD4(Float(frame.lift), 0, 0, 0),
        ], picture: cover)
    }
    #endif

    private static func shader(size: CGSize, cover: CGImage, frame: LivingCoverFeel.Frame) -> Shader {
        var shader = ShaderLibrary.livingCover(
            .float2(size),
            .float4(phase(frame.deep), phase(frame.middle), phase(frame.top), phase(frame.flow)),
            .float4(frame.swell, frame.thump, frame.twist, frame.shimmer),
            .float4(frame.body, frame.churn, frame.breath, frame.warmth),
            .float(frame.lift),
            .image(Image(decorative: cover, scale: 1))
        )
        shader.dithersColor = true
        return shader
    }
}

/// Living Cover's feel, stepped on as each frame is drawn.
private final class LivingCoverMotion {
    private var feel = LivingCoverFeel()
    private var lastTime: Double?

    func step(_ pulse: StagePulse, isPlaying: Bool, character: LivingCoverFeel.Character, time: Double) -> LivingCoverFeel.Frame {
        // Back after a while away, it picks up where the music is rather than catching up.
        let elapsed = min(max(lastTime.map { time - $0 } ?? 0, 0), 0.25)
        lastTime = time
        return feel.step(bands: pulse.bands, kick: pulse.kick, activity: pulse.activity, pace: pulse.pace, beats: pulse.beats, isPlaying: isPlaying, character: character, elapsed: elapsed)
    }
}

/// Living Cover's choices, as their stored keys.
enum LivingCoverOption {
    /// Living Cover moves with the music, wherever it's shown. On by default.
    static let movesWithMusic = "livingCoverMovesWithMusic"
}

extension EnvironmentValues {
    /// The music a screen already follows, for a background on it to share: Stage's, so its
    /// visualizer and its background move to the same moment, measured once.
    @Entry var backdropLevels: SmoothedLevels?
}

/// Reeded Glass: the cover behind a pane of ribbed glass, each reed showing a slice of it,
/// with light on the reeds' faces and shade between them. The cover drifts behind the glass
/// while the music plays, so the slices shift as if you were walking past. See
/// `reededGlass` in Backdrops.metal.
struct ReededGlassBackdrop: View {
    let art: BackdropArt
    let isMoving: Bool

    /// A reed's width in points: wide enough to read as glass, not as stripes.
    static let reed: CGFloat = 26

    var body: some View {
        moving.overlay {
            LinearGradient(stops: [
                .init(color: .black.opacity(0), location: 0.35),
                .init(color: .black.opacity(0.35), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
    }

    #if os(macOS)
    private var moving: some View {
        BackdropCanvasTimeline(isMoving: isMoving, rate: 0.8, start: art.start, factor: 2) { [art] time, _ in
            // Worked out at the view's own size, so the reed is its whole width.
            BackdropDrawing(function: "reededGlassFragment", inputs: [
                SIMD4(Float(time.truncatingRemainder(dividingBy: 20_000)), Float(Self.reed), 0, 0),
            ], picture: art.clear)
        }
    }
    #else
    private var moving: some View {
        BackdropTimeline(isMoving: isMoving, rate: 0.8, start: art.start) { time in
            StretchedBackdrop(factor: 2) { size in
                Rectangle().fill(Self.shader(size: size, time: time, cover: art.clear))
            }
        }
    }
    #endif

    private static func shader(size: CGSize, time: Double, cover: CGImage) -> Shader {
        var shader = ShaderLibrary.reededGlass(
            .float2(size),
            .float(time.truncatingRemainder(dividingBy: 20_000)),
            .float(reed / 2),
            .image(Image(decorative: cover, scale: 1))
        )
        shader.dithersColor = true
        return shader
    }
}

/// Aurora: curtains of light in the cover's colours, rippling over a night sky of its own
/// deepest colour. They hang high, where the cover is; lower down the sky stays dark for the
/// song's name and the controls. See `aurora` in Backdrops.metal.
///
/// On a tall screen the cover fills the upper half, so the curtains hang behind it, their
/// light rising round its edges and into the sky above; on a wide one, where the song sits
/// beside the cover, they hang across the top.
struct AuroraBackdrop: View {
    let art: BackdropArt
    let isMoving: Bool
    /// Where the cover sits, in this view's space.
    let focus: CGRect?
    @Environment(PlayerModel.self) private var player: PlayerModel?

    var body: some View {
        let lights = art.lights.count >= 3 ? art.lights : Array(repeating: art.field.mix(with: .white, by: 0.6), count: 3)
        let sky = art.field.mix(with: .black, by: 0.45)
        #if os(macOS)
        let colours = (lights.prefix(3) + [sky]).map(\.shaderComponents)
        BackdropCanvasTimeline(isMoving: isMoving, rate: FlowRate.of(player), start: art.start, factor: 3) { [focus] time, frame in
            let (hem, tail) = Self.curtains(focus: focus, in: frame.size)
            return BackdropDrawing(function: "auroraFragment", inputs: [
                SIMD4(Float(time.truncatingRemainder(dividingBy: 20_000)), Float(hem), Float(tail), 0),
            ] + colours)
        }
        #else
        GeometryReader { proxy in
            let (hem, tail) = Self.curtains(focus: focus, in: proxy.size)
            BackdropTimeline(isMoving: isMoving, rate: FlowRate.of(player), start: art.start) { time in
                StretchedBackdrop(factor: 3) { size in
                    Rectangle().fill(Self.shader(size: size, time: time, hem: hem, tail: tail, lights: lights, sky: sky))
                }
            }
        }
        #endif
    }

    /// Where the first curtain's hem hangs, as a part of the height, and how steeply its
    /// glow fades above it.
    private static func curtains(focus: CGRect?, in size: CGSize) -> (hem: Double, tail: Double) {
        guard size.height > size.width * 1.1, size.height > 0 else { return (0.2, 7.5) }
        let middle = focus.map { Double($0.midY / size.height) } ?? 0.33
        return (min(0.5, max(0.2, middle - 0.06)), 3.5)
    }

    private static func shader(size: CGSize, time: Double, hem: Double, tail: Double, lights: [Color], sky: Color) -> Shader {
        var shader = ShaderLibrary.aurora(
            .float2(size),
            .float(time.truncatingRemainder(dividingBy: 20_000)),
            .float(hem),
            .float(tail),
            .color(lights[0]),
            .color(lights[1]),
            .color(lights[2]),
            .color(sky)
        )
        shader.dithersColor = true
        return shader
    }
}
