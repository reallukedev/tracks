import SwiftUI
import TracksCore

/// What fills Stage behind the song. Two of its own that move with the music, then Now
/// Playing's.
enum StageBackground: String, CaseIterable, Identifiable {
    /// The cover's colours as a mesh that drifts with the song and swells on the bass.
    case flow
    /// The cover itself, huge and soft, breathing with the beat.
    case bloom
    /// Halo is stored as "pulse", the background it took the place of.
    case colour, artwork, living, glass, aurora
    case halo = "pulse"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .flow: "Flow"
        case .bloom: "Bloom"
        default: nowPlaying?.title ?? ""
        }
    }

    var footer: LocalizedStringKey {
        switch self {
        case .flow: "The cover's colours flow into one another and swell with the bass."
        case .bloom: "The cover fills the screen, soft and slowly turning, and breathes with the music."
        default: nowPlaying?.footer ?? ""
        }
    }

    /// The same background as Now Playing's, for the ones they share.
    var nowPlaying: NowPlayingBackground? {
        switch self {
        case .flow, .bloom: nil
        case .colour: .colour
        case .artwork: .artwork
        case .living: .living
        case .glass: .glass
        case .aurora: .aurora
        case .halo: .halo
        }
    }
}

struct StageBackdrop: View {
    let style: StageBackground
    let cover: CoverArt?
    let tint: Color?
    let palette: [Color]
    let levels: SmoothedLevels
    let energy: Double
    let isPlaying: Bool
    /// Where the cover sits, in this view's space.
    var focus: CGRect?

    var body: some View {
        ZStack {
            Color.black
            switch style {
            case .flow:
                FlowBackdrop(colors: colors, levels: levels, energy: energy, isPlaying: isPlaying)
            case .bloom:
                BloomBackdrop(cover: cover, levels: levels, energy: energy, isPlaying: isPlaying)
            default:
                NowPlayingBackdrop(cover: cover, tint: tint, isPlaying: isPlaying, style: style.nowPlaying, focus: focus)
                    .environment(\.backdropLevels, levels)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: style)
        .accessibilityHidden(true)
    }

    /// At least three colours, deep to light, from the cover or its tint.
    private var colors: [Color] {
        var found = palette
        if found.isEmpty { found = [tint ?? .indigo] }
        while found.count < 3 {
            found.append((found.last ?? .indigo).mix(with: .white, by: 0.3))
        }
        return found
    }
}

/// The cover's colours as a three-by-three mesh. Its inner points wander slowly, the middle
/// one pushed out by the bass, and a light at the centre swells on each kick, the way Apple
/// Music's animated backgrounds move, but in time with the song.
private struct FlowBackdrop: View {
    let colors: [Color]
    let levels: SmoothedLevels
    let energy: Double
    let isPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSettled = false
    @Environment(\.isOnScreen) private var isOnScreen
    @Environment(PlayerModel.self) private var player: PlayerModel?

    var body: some View {
        TimelineView(.animation(minimumInterval: BackdropFrameRate.everyFrame, paused: reduceMotion || isSettled || !isOnScreen)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let pulse = reduceMotion ? .still(isPlaying: isPlaying) : levels.next(heard: AudioLevelMeter.shared.current(), time: time, song: SongMoment(player: player, energy: energy), isPlaying: isPlaying)
            let bass = pulse.bass
            let mid = Float(pulse.bands[6..<14].reduce(0, +) / 8)
            // The drift keeps the song's pace, hurrying for a busy track and gliding for a
            // ballad, and glides to a stop on pause; the bass and the mids push it about.
            let t = Float(reduceMotion ? 0 : pulse.motion.truncatingRemainder(dividingBy: 10_000))
            let wander: Float = 0.11 + 0.05 * pulse.activity
            let points: [SIMD2<Float>] = [
                [0, 0], [0.5 + wander * sin(t * 0.21), 0], [1, 0],
                [0, 0.5 + wander * cos(t * 0.17)],
                [0.5 + (wander + mid * 0.12) * sin(t * 0.31), 0.5 + (wander + bass * 0.18) * cos(t * 0.27)],
                [1, 0.5 + wander * sin(t * 0.19 + 1)],
                [0, 1], [0.5 + wander * cos(t * 0.23), 1], [1, 1],
            ]
            let (deep, middle, light) = (colors[0], colors[1], colors[2])
            let glow = light.mix(with: .white, by: Double(0.08 + bass * 0.4 + pulse.kick * 0.1))
            MeshGradient(
                width: 3,
                height: 3,
                points: points,
                colors: [
                    deep, middle, light,
                    middle, glow, deep,
                    light, deep, middle,
                ],
                smoothsColors: true
            )
            .overlay {
                // The kick, as light from the middle.
                RadialGradient(colors: [.white.opacity(Double(bass) * 0.2 + Double(pulse.kick) * 0.2), .clear], center: .center, startRadius: 0, endRadius: 700)
                    .blendMode(.plusLighter)
            }
            .overlay {
                LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.4)], startPoint: .top, endPoint: .bottom)
            }
        }
        .settles(isPlaying: isPlaying, into: $isSettled)
    }
}

/// The cover, far larger than the screen and heavily blurred, turning slowly and breathing
/// with the beat: swelling and brightening on each kick. Drawn from the cover readied for the
/// backgrounds, already softened, so no blur the size of the screen is worked out each frame.
private struct BloomBackdrop: View {
    let cover: CoverArt?
    let levels: SmoothedLevels
    let energy: Double
    let isPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var art: BackdropArt?
    @State private var isSettled = false

    init(cover: CoverArt?, levels: SmoothedLevels, energy: Double, isPlaying: Bool) {
        self.cover = cover
        self.levels = levels
        self.energy = energy
        self.isPlaying = isPlaying
        _art = State(initialValue: BackdropArtStore.shared.cached(cover))
    }
    @Environment(\.isOnScreen) private var isOnScreen
    @Environment(PlayerModel.self) private var player: PlayerModel?

    var body: some View {
        GeometryReader { proxy in
            let side = max(proxy.size.width, proxy.size.height) * 1.5
            TimelineView(.animation(minimumInterval: BackdropFrameRate.everyFrame, paused: reduceMotion || isSettled || !isOnScreen)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                let pulse = reduceMotion ? .still(isPlaying: isPlaying) : levels.next(heard: AudioLevelMeter.shared.current(), time: time, song: SongMoment(player: player, energy: energy), isPlaying: isPlaying)
                let bass = CGFloat(pulse.bass)
                let kick = CGFloat(pulse.kick)
                ZStack {
                    if let art {
                        Image(decorative: art.soft, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: side, height: side)
                            .scaleEffect(1.1 + bass * 0.14 + kick * 0.045)
                            .rotationEffect(.degrees(reduceMotion ? 0 : (pulse.motion * 3).truncatingRemainder(dividingBy: 360)))
                            .saturation(1.35)
                            .brightness(Double(bass) * 0.14 + Double(kick) * 0.08 - 0.1)
                            .transition(.opacity)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .background(art?.field ?? CoverStage.fallback)
        .overlay {
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
        }
        .clipped()
        .settles(isPlaying: isPlaying, into: $isSettled)
        .task(id: cover) {
            guard let cover else { return }
            let found = await BackdropArtStore.shared.art(for: cover)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.6)) { art = found }
        }
    }
}

extension View {
    /// Sets `isSettled` a moment after the music pauses, once what moves with it has fallen
    /// still, so the drawing can stop; clears it as soon as the music plays.
    func settles(isPlaying: Bool, into isSettled: Binding<Bool>) -> some View {
        task(id: isPlaying) {
            guard !isPlaying else {
                isSettled.wrappedValue = false
                return
            }
            // The drift takes a couple of seconds to glide to a stop.
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            isSettled.wrappedValue = true
        }
    }
}
