import Foundation
import CoreGraphics

/// Full Cover's colours around the cover, as one small picture to stretch behind it.
///
/// Every point past the cover takes the colour of the nearest point on the cover's edge, as if
/// the edge were drawn on outward, and settles into the colour the type sits on the further it
/// is from the cover. The nearest point on a square moves smoothly with the point, so the
/// colours have no seams anywhere, corners included: each corner is the two edges' ends met.
/// Inside the cover, near an edge the cover fades out at, it's that edge's colour, so the
/// fading cover gives way to exactly what carries on past it.
///
/// Soft by nature, so it's worked out a few points to a pixel and stretched.
public nonisolated struct CoverBleedField: Sendable {
    public let width: Int
    public let height: Int
    /// RGBA, premultiplied (opaque), rows from the top.
    public let rgba: [UInt8]
    /// How much the cover itself, softened and drawn on past its edges, shows over the colours
    /// at each pixel, 0 to 255, rows from the top: wholly under the cover and at its edge,
    /// fading to none a little way past it. It carries the cover's own texture across the edge
    /// before the colours take over, so the hand-off has no line.
    public let continuation: [UInt8]

    /// How the colours lie around the cover.
    public struct Shape: Sendable, Equatable {
        /// The container, in points.
        public var size: CGSize
        /// The part of the cover that shows, in the container's points: its square, or less
        /// when its foot is cut short.
        public var cover: CGRect
        /// The edge the song's words sit past, whose colour the rest settles into.
        public var songEdge: CoverBleed.Edge
        /// How far into the cover it fades on the song's edge, and on the others, as parts of
        /// its side; an edge with no screen past it doesn't fade.
        public var featherToSong: Double
        public var featherElsewhere: Double
        /// How far past the cover its edge's colours take to settle, as a part of its side.
        public var settle: Double
        /// How far past the cover its softened picture carries on, as a part of its side.
        public var reach: Double = 0.1
        /// Points to a pixel.
        public var pointsPerPixel: Double
        public var increasedContrast: Bool

        public init(size: CGSize, cover: CGRect, songEdge: CoverBleed.Edge, featherToSong: Double, featherElsewhere: Double, settle: Double, pointsPerPixel: Double, increasedContrast: Bool) {
            self.size = size
            self.cover = cover
            self.songEdge = songEdge
            self.featherToSong = featherToSong
            self.featherElsewhere = featherElsewhere
            self.settle = settle
            self.pointsPerPixel = pointsPerPixel
            self.increasedContrast = increasedContrast
        }

        /// How deep the cover fades at `edge`: nothing where it meets the container's edge.
        /// Whether there's any of the container past the cover at `edge`.
        public func hasRoom(_ edge: CoverBleed.Edge) -> Bool {
            switch edge {
            case .top: cover.minY > 0.5
            case .bottom: cover.maxY < size.height - 0.5
            case .leading: cover.minX > 0.5
            case .trailing: cover.maxX < size.width - 0.5
            }
        }

        public func feather(_ edge: CoverBleed.Edge) -> Double {
            guard hasRoom(edge) else { return 0 }
            return edge == songEdge ? featherToSong : featherElsewhere
        }
    }

    public init(bleed: CoverBleed, shape: Shape) {
        let scale = max(0.5, shape.pointsPerPixel)
        let width = max(1, Int((shape.size.width / scale).rounded(.up)))
        let height = max(1, Int((shape.size.height / scale).rounded(.up)))
        let painter = Painter(bleed: bleed, shape: shape)
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        var continuation = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                let point = CGPoint(x: (Double(column) + 0.5) * scale, y: (Double(row) + 0.5) * scale)
                let colour = painter.colour(at: point)
                let index = (row * width + column) * 4
                rgba[index] = Self.byte(colour.red)
                rgba[index + 1] = Self.byte(colour.green)
                rgba[index + 2] = Self.byte(colour.blue)
                continuation[row * width + column] = Self.byte(painter.continuation(at: point))
            }
        }
        self.width = width
        self.height = height
        self.rgba = rgba
        self.continuation = continuation
    }

    private static func byte(_ value: Double) -> UInt8 {
        UInt8(min(255, max(0, (value * 255).rounded())))
    }

    /// The colour at any point, in the container's points, without drawing the whole field.
    public static func sampler(bleed: CoverBleed, shape: Shape) -> @Sendable (CGPoint) -> CoverBleed.Colour {
        let painter = Painter(bleed: bleed, shape: shape)
        return { painter.colour(at: $0) }
    }
}

/// Works out the field's colours: the edges' colours, made legible for their type, each
/// running from corner to corner.
private nonisolated struct Painter {
    typealias Colour = CoverBleed.Colour
    typealias RGB = (Double, Double, Double)

    let shape: CoverBleedField.Shape
    /// Each edge's legible stops, with its two corners pinned at either end, in the order of
    /// ``CoverBleed/Edge/allCases``: top, bottom, leading, trailing. Arrays rather than
    /// dictionaries, and worked out once: this runs for every pixel of the field.
    let lines: [[(location: Double, colour: RGB)]]
    let floors: [RGB]
    let feathers: [Double]
    let songFloor: RGB

    init(bleed: CoverBleed, shape: CoverBleedField.Shape) {
        self.shape = shape
        var stops: [CoverBleed.Edge: [Colour]] = [:]
        var floors: [CoverBleed.Edge: RGB] = [:]
        let songFloor = bleed.floor(shape.songEdge, increasedContrast: shape.increasedContrast)
        for edge in CoverBleed.Edge.allCases {
            // The edges either side of the song's settle into the song's colour too, so above
            // and below a cover on the Mac it's the colour beside it, not a band of its own.
            let floor = Self.isBeside(edge, shape.songEdge) ? songFloor : bleed.floor(edge, increasedContrast: shape.increasedContrast)
            // Halfway to the one colour already: the softened cover carries the edge's own
            // detail across, and what's left of it here only has to hint at it. Left whole, a
            // patch of sky at the corner of a cover ran down the screen's side as a stripe.
            stops[edge] = bleed.legible(edge, increasedContrast: shape.increasedContrast).map { stop in
                Self.colour(Self.mix(Self.rgb(stop), Self.rgb(floor), Self.towardFloor))
            }
            floors[edge] = Self.rgb(floor)
        }
        func first(_ edge: CoverBleed.Edge) -> RGB { Self.rgb(stops[edge]?.first ?? .black) }
        func last(_ edge: CoverBleed.Edge) -> RGB { Self.rgb(stops[edge]?.last ?? .black) }
        // A corner is where two edges meet, but an edge that meets the screen's edge has
        // nothing past it to show, and mustn't tint its corners either.
        func corner(_ a: RGB, _ aRoom: Bool, _ b: RGB, _ bRoom: Bool) -> RGB {
            switch (aRoom, bRoom) {
            case (true, false): a
            case (false, true): b
            default: Self.mix(a, b, 0.5)
            }
        }
        let room = Dictionary(uniqueKeysWithValues: CoverBleed.Edge.allCases.map { ($0, shape.hasRoom($0)) })
        let topLeading = corner(first(.top), room[.top]!, first(.leading), room[.leading]!)
        let topTrailing = corner(last(.top), room[.top]!, first(.trailing), room[.trailing]!)
        let bottomLeading = corner(first(.bottom), room[.bottom]!, last(.leading), room[.leading]!)
        let bottomTrailing = corner(last(.bottom), room[.bottom]!, last(.trailing), room[.trailing]!)
        let corners: [CoverBleed.Edge: (RGB, RGB)] = [
            .top: (topLeading, topTrailing),
            .bottom: (bottomLeading, bottomTrailing),
            .leading: (topLeading, bottomLeading),
            .trailing: (topTrailing, bottomTrailing),
        ]
        var lines: [[(location: Double, colour: RGB)]] = []
        for edge in CoverBleed.Edge.allCases {
            let colours = stops[edge] ?? []
            let (start, end) = corners[edge] ?? ((0, 0, 0), (0, 0, 0))
            var line: [(location: Double, colour: RGB)] = [(0, start)]
            for (index, colour) in colours.enumerated() {
                line.append(((Double(index) + 0.5) / Double(max(1, colours.count)), Self.rgb(colour)))
            }
            line.append((1, end))
            lines.append(line)
        }
        self.lines = lines
        self.floors = CoverBleed.Edge.allCases.map { floors[$0] ?? (0, 0, 0) }
        self.feathers = CoverBleed.Edge.allCases.map { shape.feather($0) }
        self.songFloor = floors[shape.songEdge] ?? (0, 0, 0)
    }

    private static let top = 0, bottom = 1, leading = 2, trailing = 3

    func colour(at point: CGPoint) -> Colour {
        let cover = shape.cover
        let side = max(1, Double(cover.width))
        let nearest = CGPoint(x: min(max(point.x, cover.minX), cover.maxX), y: min(max(point.y, cover.minY), cover.maxY))
        let dx = Double(point.x - nearest.x)
        let dy = Double(point.y - nearest.y)
        if dx != 0 || dy != 0 {
            // Past the cover: the nearest edge point's colour, settling into the floor, which
            // is the floors of the edges it lies past, in proportion to how far past each.
            let edgeColour = colourOnEdge(at: nearest, outward: (dx, dy))
            let vertical = dy < 0 ? floors[Self.top] : floors[Self.bottom]
            let horizontal = dx < 0 ? floors[Self.leading] : floors[Self.trailing]
            let (v, h) = (abs(dy), abs(dx))
            let floor = Self.mix(vertical, horizontal, h / (v + h))
            let distance = (dx * dx + dy * dy).squareRoot()
            let settled = Self.smooth(min(1, distance / max(1, shape.settle * side)))
            return Self.colour(Self.mix(edgeColour, floor, settled))
        }
        // Inside: the colours of the edges it's fading toward, nearest counting most.
        var sum: RGB = (0, 0, 0)
        var total = 0.0
        let x = Double(point.x - cover.minX) / side
        let y = Double(point.y - cover.minY) / Double(max(1, cover.height))
        for edge in 0..<4 {
            let depth = feathers[edge]
            guard depth > 0 else { continue }
            let (inward, along) = switch edge {
            case Self.top: (y, x)
            case Self.bottom: (1 - y, x)
            case Self.leading: (x, y)
            default: (1 - x, y)
            }
            let weight = max(0, 1 - inward / depth)
            guard weight > 0 else { continue }
            let c = Self.sample(lines[edge], at: along)
            sum = (sum.0 + c.0 * weight, sum.1 + c.1 * weight, sum.2 + c.2 * weight)
            total += weight
        }
        guard total > 0 else {
            // Covered by the cover itself, wholly: the song edge's floor, never seen.
            return Self.colour(songFloor)
        }
        return Self.colour((sum.0 / total, sum.1 / total, sum.2 / total))
    }

    /// How much of the softened cover shows at a point. On the cover, all of it, until the
    /// song's edge nears: across the fade there it gives way to the colours (deepened or lifted
    /// for the type) so the change of shade happens under the fading cover rather than in
    /// the gap above the song's name. Past the edges it eases away over
    /// ``CoverBleedField/Shape/reach``, from whatever it was at the nearest point of the edge,
    /// so there's no seam where the sides meet the song's edge.
    func continuation(at point: CGPoint) -> Double {
        let cover = shape.cover
        let nearest = CGPoint(x: min(max(point.x, cover.minX), cover.maxX), y: min(max(point.y, cover.minY), cover.maxY))
        let onCover = onCoverContinuation(at: nearest)
        let dx = Double(point.x - nearest.x)
        let dy = Double(point.y - nearest.y)
        guard dx != 0 || dy != 0 else { return onCoverContinuation(at: point) }
        let distance = (dx * dx + dy * dy).squareRoot()
        return onCover * (1 - Self.smooth(min(1, distance / max(1, shape.reach * Double(cover.width)))))
    }

    /// How much of the softened cover shows at a point on it: it gives way toward the song's
    /// edge and the edges either side of it, which all settle into the song's colour. The edge
    /// across from the song's keeps it, so a sky above a phone's cover carries on as sky.
    private func onCoverContinuation(at point: CGPoint) -> Double {
        let cover = shape.cover
        let x = Double((point.x - cover.minX) / max(1, cover.width))
        let y = Double((point.y - cover.minY) / max(1, cover.height))
        var shown = 1.0
        for edge in CoverBleed.Edge.allCases where edge == shape.songEdge || Self.isBeside(edge, shape.songEdge) {
            let depth = shape.feather(edge)
            guard depth > 0 else { continue }
            let inward = switch edge {
            case .top: y
            case .bottom: 1 - y
            case .leading: x
            case .trailing: 1 - x
            }
            shown *= 1 - Self.giveWay * Self.smooth(max(0, 1 - inward / depth))
        }
        return shown
    }

    /// Whether `edge` runs alongside `other`, at a right angle to it, rather than across from it.
    static func isBeside(_ edge: CoverBleed.Edge, _ other: CoverBleed.Edge) -> Bool {
        let upright: Set<CoverBleed.Edge> = [.leading, .trailing]
        return upright.contains(edge) != upright.contains(other)
    }

    /// How far each edge's colours are drawn toward the one they settle into.
    private static let towardFloor = 0.5

    /// How much of the softened cover gives way to the colours by the song's edge.
    private static let giveWay = 0.8

    /// The colour at a point on the cover's edge, reached from outside in `outward`'s
    /// direction: a corner when past both its edges.
    private func colourOnEdge(at point: CGPoint, outward: (Double, Double)) -> RGB {
        let cover = shape.cover
        let x = Double((point.x - cover.minX) / max(1, cover.width))
        let y = Double((point.y - cover.minY) / max(1, cover.height))
        let (dx, dy) = outward
        if dy < 0, dx == 0 { return Self.sample(lines[Self.top], at: x) }
        if dy > 0, dx == 0 { return Self.sample(lines[Self.bottom], at: x) }
        if dx < 0, dy == 0 { return Self.sample(lines[Self.leading], at: y) }
        if dx > 0, dy == 0 { return Self.sample(lines[Self.trailing], at: y) }
        // Past a corner: the corner, which both its edges end in.
        return Self.sample(lines[dy < 0 ? Self.top : Self.bottom], at: dx < 0 ? 0 : 1)
    }

    private static func sample(_ line: [(location: Double, colour: RGB)], at t: Double) -> RGB {
        guard let first = line.first else { return (0, 0, 0) }
        if t <= first.location { return first.colour }
        for (a, b) in zip(line, line.dropFirst()) where t <= b.location {
            let span = max(0.000_001, b.location - a.location)
            return mix(a.colour, b.colour, (t - a.location) / span)
        }
        return line.last?.colour ?? first.colour
    }

    private static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }

    private static func smooth(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    private static func rgb(_ colour: Colour) -> RGB { (colour.red, colour.green, colour.blue) }

    private static func colour(_ rgb: RGB) -> Colour { Colour(red: rgb.0, green: rgb.1, blue: rgb.2) }
}
