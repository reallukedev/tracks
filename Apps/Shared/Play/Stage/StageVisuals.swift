import SwiftUI

/// The cover's colours as a soft cloud of light that drifts slowly, the way Apple Music's
/// animated covers move. The music makes it swell and brighten a little; it never flashes.
///
/// A four-by-four mesh whose outer points are clear, so the cloud has no edge, and whose inner
/// four wander on slow paths of their own.
struct GlowVisual: View {
    /// The cover's colours as light, at least four.
    let colors: [Color]
    /// How full the music is, 0 to 1, eased.
    let level: Double
    /// Each beat as a slow swell, 0 to 1.
    let bloom: Double
    /// Seconds of drift.
    let phase: Double

    var body: some View {
        MeshGradient(width: 4, height: 4, points: Self.points(phase: phase, level: level), colors: Self.colors(colors), smoothsColors: true)
            .mask {
                EllipticalGradient(
                    stops: [.init(color: .white, location: Self.mask.lowerBound), .init(color: .clear, location: Self.mask.upperBound)],
                    startRadiusFraction: 0,
                    endRadiusFraction: 1
                )
            }
            // A quiet song's cloud sits small and dim; a loud one's fills out and glows.
            .scaleEffect(Self.scale(level: level, bloom: bloom))
            // Brighter by opacity alone: a brightness filter lifts the clear corners too, which
            // shows as an edge over the background.
            .opacity(Self.opacity(level: level, bloom: bloom))
            .blendMode(.plusLighter)
    }

    /// Where the cloud fades out, as parts of the size from its middle.
    static let mask = 0.15...0.5

    static func scale(level: Double, bloom: Double) -> Double { 0.9 + 0.14 * level + 0.04 * bloom }
    static func opacity(level: Double, bloom: Double) -> Double { 0.35 + 0.55 * level + 0.1 * bloom }

    /// The mesh's points: the outer ones still, the inner four wandering.
    static func points(phase: Double, level: Double) -> [SIMD2<Float>] {
        /// An inner point of the mesh near `x`, `y`, wandering on a slow path of its own.
        func inner(_ x: Float, _ y: Float, _ speed: Float, _ offset: Float) -> SIMD2<Float> {
            let t = Float(phase.truncatingRemainder(dividingBy: 10_000))
            let reach = Float(0.07 + 0.03 * level)
            return [x + reach * sin(t * speed + offset), y + reach * cos(t * speed * 0.83 + offset * 1.7)]
        }
        return [
            [0, 0], [0.33, 0], [0.67, 0], [1, 0],
            [0, 0.33], inner(0.33, 0.36, 0.23, 0), inner(0.67, 0.33, 0.19, 2.1), [1, 0.33],
            [0, 0.67], inner(0.31, 0.66, 0.17, 4.2), inner(0.66, 0.67, 0.21, 1.3), [1, 0.67],
            [0, 1], [0.33, 1], [0.67, 1], [1, 1],
        ]
    }

    /// The mesh's colours: the inner four the cover's, the outer ones clear, so the cloud has
    /// no edge.
    static func colors(_ colors: [Color]) -> [Color] {
        let (a, b, c, d) = (colors[0], colors[1 % colors.count], colors[2 % colors.count], colors[3 % colors.count])
        return [
            .clear, b.opacity(0), c.opacity(0), .clear,
            a.opacity(0), a, b, d.opacity(0),
            c.opacity(0), d, c, b.opacity(0),
            .clear, a.opacity(0), d.opacity(0), .clear,
        ]
    }
}

/// Light blooming from behind the cover, as Siri's glow lights the edge of the screen: a
/// line of light hugging the cover's edge, a glow around it and a wide bloom beyond, in the
/// cover's colours turning slowly round it. It breathes with the music and blooms on each
/// beat, most on the first of a bar.
///
/// Drawn at half size and stretched, since soft light looks the same.
struct HaloVisual: View {
    let colors: [Color]
    let level: Double
    /// Each beat, 0 to 1, up quickly and falling away.
    let bloom: Double
    /// Seconds of turning.
    let phase: Double
    /// The cover's side and corner radius, centred in this view.
    let cover: CGFloat
    var radius: CGFloat = 12

    private static let scale: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .frame(width: proxy.size.width / Self.scale, height: proxy.size.height / Self.scale)
            .drawingGroup()
            .scaleEffect(Self.scale, anchor: .topLeading)
        }
        // The bloom's soft tail reaches past this square; faded out before the edge, or the
        // square's edge shows as a line across the background.
        .mask {
            EllipticalGradient(
                stops: [.init(color: .white, location: 0.55), .init(color: .clear, location: 1)],
                startRadiusFraction: 0,
                endRadiusFraction: 0.5
            )
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let side = cover / Self.scale
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        func edge(outset: CGFloat) -> Path {
            let rect = CGRect(x: centre.x - side / 2 - outset, y: centre.y - side / 2 - outset, width: side + outset * 2, height: side + outset * 2)
            return Path(roundedRect: rect, cornerRadius: radius / Self.scale + outset, style: .continuous)
        }
        // Round the cover in the cover's colours, the first again at the end so it closes.
        let ring = Gradient(colors: colors + [colors[0]])
        let turning = GraphicsContext.Shading.conicGradient(ring, center: centre, angle: .radians(phase * 0.35))
        let opposite = GraphicsContext.Shading.conicGradient(ring, center: centre, angle: .radians(-phase * 0.22 + 2))

        // The wide bloom, breathing with the music and opening on the beat.
        context.drawLayer { layer in
            let spread = side * (0.1 + 0.08 * level + 0.08 * bloom)
            layer.addFilter(.blur(radius: side * 0.1 + spread * 0.6))
            layer.opacity = 0.35 + 0.35 * level + 0.3 * bloom
            layer.stroke(edge(outset: spread * 0.5), with: opposite, lineWidth: spread * 2)
        }
        // The glow close round the edge.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: side * 0.035))
            layer.opacity = 0.55 + 0.25 * level + 0.2 * bloom
            layer.stroke(edge(outset: side * 0.02), with: turning, lineWidth: side * (0.05 + 0.03 * bloom))
        }
        // The line of light along the edge itself, a little whiter.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 1.2))
            layer.opacity = 0.6 + 0.4 * max(level, bloom)
            layer.stroke(edge(outset: 1), with: turning, lineWidth: 2.5)
            layer.opacity *= 0.5
            layer.stroke(edge(outset: 1), with: .color(.white), lineWidth: 1)
        }
    }
}

/// The music passing by, as Voice Memos draws a recording: thin rounded bars, each how loud
/// a moment was, the newest arriving at the right and moving left as time goes on, so the
/// rhythm can be seen going past. Mirrored about the middle, in white that takes on the
/// colour behind it.
struct WaveformVisual: View {
    /// Each moment's loudness, 0 to 1, oldest first.
    let samples: [Float]
    /// How far past the newest the drawing has moved, as a part of one bar's step.
    let shift: Double

    static let width: CGFloat = 3
    static let pitch: CGFloat = 6

    /// How many bars fit across `width`, and two more for the ends.
    static func capacity(for width: CGFloat) -> Int {
        Int(width / pitch) + 2
    }

    var body: some View {
        Canvas { context, size in
            let middle = size.height / 2
            let barWidth = Self.width
            var bars = Path()
            for (index, sample) in samples.reversed().enumerated() {
                let x = size.width - (CGFloat(index) + CGFloat(shift)) * Self.pitch - barWidth
                guard x > -barWidth else { break }
                let level = CGFloat(min(1, max(0, sample)))
                let height = barWidth + pow(level, 0.85) * (size.height - barWidth)
                bars.addRoundedRect(
                    in: CGRect(x: x, y: middle - height / 2, width: barWidth, height: height),
                    cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2),
                    style: .continuous
                )
            }
            context.fill(bars, with: .color(.white.opacity(0.85)))
        }
        // Older moments fade away to the left; the newest come in softly at the right.
        .mask {
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .white, location: 0.28),
                .init(color: .white, location: 0.96),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        }
        .blendMode(.plusLighter)
    }
}

/// The music from low notes to high, as Music's playing indicator draws it: a row of capsules
/// rising from one line, each the sound at its pitch. Kicks land in the bass on the left, the
/// snare in the middle, cymbals shimmer at the right, and the whole row stands as tall as the
/// song is loud. At rest it's a row of dots.
struct BarsVisual: View {
    /// Each bar's height, 0 to 1, low notes to high, one per bar, already sprung.
    let heights: [Float]
    /// The cover's light, which the bars rise out of.
    let light: Color
    /// The beat as it lands, 0 to 1: the bars brighten a little with it.
    let kick: Double

    var body: some View {
        Canvas { context, size in
            let levels = heights
            guard !levels.isEmpty else { return }
            let pitch = size.width / CGFloat(levels.count)
            let width = pitch * 0.56
            var bars = Path()
            for (index, level) in levels.enumerated() {
                let x = CGFloat(index) * pitch + (pitch - width) / 2
                // Curved so the loud parts stand clear of the rest and the row has a shape,
                // rather than sitting at one height.
                let shaped = pow(min(1, CGFloat(max(0, level)) * 1.2), 1.35)
                let height = width + shaped * (size.height - width)
                bars.addRoundedRect(
                    in: CGRect(x: x, y: size.height - height, width: width, height: height),
                    cornerSize: CGSize(width: width / 2, height: width / 2),
                    style: .continuous
                )
            }
            context.fill(bars, with: .linearGradient(
                Gradient(colors: [light.opacity(0.75 + 0.15 * kick), .white.opacity(0.92)]),
                startPoint: CGPoint(x: 0, y: size.height),
                endPoint: CGPoint(x: 0, y: size.height * 0.15)
            ))
        }
        .blendMode(.plusLighter)
    }

    /// About one bar every 20 points, between 8 and 40: past that, bars only repeat the bands
    /// beside them.
    static func count(for width: CGFloat) -> Int {
        min(40, max(8, Int(width / 20)))
    }

    /// The bands spread across `count` bars, eased between neighbours, so a wide screen gets
    /// a fuller row that still follows the sound's shape.
    static func resampled(_ heights: [Float], count: Int) -> [Float] {
        guard heights.count > 1, count > 1 else { return heights }
        return (0..<count).map { bar in
            let position = Float(bar) / Float(count - 1) * Float(heights.count - 1)
            let index = min(heights.count - 2, Int(position))
            let fraction = position - Float(index)
            let eased = fraction * fraction * (3 - 2 * fraction)
            return heights[index] + (heights[index + 1] - heights[index]) * eased
        }
    }
}

/// Each bar on a spring of its own, so a hit makes it leap and settle with a little bounce, as
/// things move in iOS, rather than snap. A busy song springs quicker than a slow one. Nothing
/// moves a bar but the music.
final class BarSprings {
    private var positions: [Float] = []
    private var velocities: [Float] = []
    private var lastTime: Double?

    func step(toward targets: [Float], kick: Float, time: Double, liveliness: Double, gentleness: Double = 0) -> [Float] {
        let elapsed = Float(min(max(lastTime.map { time - $0 } ?? 0, 0), 0.1))
        lastTime = time
        if positions.count != targets.count {
            positions = targets
            velocities = [Float](repeating: 0, count: targets.count)
            return positions
        }
        // About a seventh of a second to answer, quicker for a busy song; damped enough that a
        // hit only just leaps past where it's going, so the row flows rather than jitters. A
        // gentle song answers more slowly and never overshoots: it swells, it doesn't bounce.
        let gentle = Float(min(1, max(0, gentleness)))
        let response = Float(0.15 - 0.05 * min(1, max(0, liveliness))) + 0.17 * gentle
        let stiffness = pow(2 * Float.pi / response, 2)
        let damping = 2 * (0.72 + 0.33 * gentle) * sqrt(stiffness)
        let count = Float(max(1, targets.count - 1))
        let goals = targets.indices.map { index -> Float in
            let place = Float(index) / count
            // The kick lifts the bass most, fading out by the middle.
            let lift = kick * 0.3 * (1 - gentle) * max(0, 1 - place * 2.2)
            return max(0, targets[index] + lift)
        }
        // In small steps, so a dropped frame doesn't throw a bar off its spring.
        let steps = max(1, Int((elapsed / (1.0 / 240)).rounded(.up)))
        let dt = elapsed / Float(steps)
        for _ in 0..<steps {
            for index in positions.indices {
                let force = stiffness * (goals[index] - positions[index]) - damping * velocities[index]
                velocities[index] += force * dt
                positions[index] = max(0, positions[index] + velocities[index] * dt)
            }
        }
        return positions
    }
}

extension Color {
    /// This colour as light: as bright as its hue allows, softened toward white. A grey or a
    /// black becomes white light.
    func asLight(whiteness: Double = 0.18) -> Color {
        let resolved = resolve(in: EnvironmentValues())
        let lift: Float = 0.004
        let top = max(resolved.red, resolved.green, resolved.blue) + lift
        let lit = Color(
            .sRGBLinear,
            red: Double((resolved.red + lift) / top),
            green: Double((resolved.green + lift) / top),
            blue: Double((resolved.blue + lift) / top)
        )
        return lit.mix(with: .white, by: whiteness)
    }
}

/// The music eased for light: how full it is, slow to rise and slower to settle, and each beat
/// as a bloom, quick or gentle by `bloomAttack` and `bloomRelease`. Kept from one frame to the
/// next; not observed, so a frame redraws nothing.
final class SoftPulse {
    private(set) var level = 0.0
    private(set) var bloom = 0.0
    private var lastTime: Double?
    private let bloomAttack: Double
    private let bloomRelease: Double

    init(bloomAttack: Double, bloomRelease: Double) {
        self.bloomAttack = bloomAttack
        self.bloomRelease = bloomRelease
    }

    func step(bands: [Float], kick: Float, time: Double) {
        let elapsed = min(max(lastTime.map { time - $0 } ?? 1, 0), 1)
        lastTime = time
        let full = min(1, Double(bands.reduce(0, +)) / Double(max(1, bands.count)) * 2.2)
        level = Self.ease(level, toward: full, elapsed: elapsed, rise: 0.3, fall: 0.9)
        bloom = Self.ease(bloom, toward: Double(kick), elapsed: elapsed, rise: bloomAttack, fall: bloomRelease)
    }

    private static func ease(_ value: Double, toward goal: Double, elapsed: Double, rise: Double, fall: Double) -> Double {
        value + (goal - value) * (1 - exp(-elapsed / (goal > value ? rise : fall)))
    }
}

/// The moments a waveform shows, one every ``interval`` of playing, each the loudest the music
/// was in it. Time stands still while paused, so the waveform stops where it was.
final class WaveHistory {
    static let interval = 1.0 / 12
    private(set) var samples: [Float] = []
    private var pending: Float = 0
    /// Seconds into the moment being gathered.
    private var into = 0.0
    private var lastTime: Double?

    /// How loud a frame of the music looks, 0 to 1: the sound as a whole, and the beat on it.
    static func loudness(bands: [Float], kick: Float) -> Float {
        let body = bands.reduce(0, +) / Float(max(1, bands.count))
        return min(1, 1.1 * body + 0.5 * kick)
    }

    /// Steps on to `time`, gathering `level`, and keeps `capacity` moments.
    func step(_ level: Float, time: Double, isPlaying: Bool, capacity: Int) -> (samples: [Float], shift: Double) {
        let elapsed = min(max(lastTime.map { time - $0 } ?? 0, 0), 0.25)
        lastTime = time
        if samples.count < capacity {
            samples.insert(contentsOf: [Float](repeating: 0, count: capacity - samples.count), at: 0)
        }
        if isPlaying {
            pending = max(pending, level)
            into += elapsed
            while into >= Self.interval {
                into -= Self.interval
                samples.append(pending)
                pending = 0
            }
        }
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
        return (samples, into / Self.interval)
    }
}
