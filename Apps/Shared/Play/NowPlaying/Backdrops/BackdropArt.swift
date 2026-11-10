import SwiftUI
import MusicKit
import TracksCore
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import CoreML

/// A cover made ready for the player's backgrounds: the picture small, softened two ways, the
/// colours it's made of, and its field. Every cover has one: a picture from the web, the
/// stand-in drawn for a song with no cover, or, for a library cover only MusicKit can draw,
/// a picture made from the colours Apple Music gives for it.
struct BackdropArt: Sendable {
    /// Lightly softened, so stretched it reads as the cover without its pixels showing.
    let clear: CGImage
    /// Softened enough to lose its detail and keep its shapes, for colours that flow.
    let flowing: CGImage
    /// Well softened, to fill a screen out of focus.
    let soft: CGImage
    /// The cover's colours as they look, most of it first. At least four.
    let colours: [Color]
    /// Its colours made deep enough for white type, at least four, for Halo and Stage.
    let deep: [Color]
    /// Three of the cover's colours as light, the most vivid first: bright, and a little
    /// richer than on the cover, for light that glows over a dark field.
    let lights: [Color]
    /// The cover's colour, deep enough for white type (see ``CoverTint``).
    let field: Color
    /// How it carries on past its edges, for Full Cover. Nil only for a picture with no
    /// pixels to read.
    let bleed: CoverBleed?
    /// Where what the cover is of sits in it (a face, a figure, a title), as Vision's attention
    /// finds it: parts of the side, from the top left. Nil when nothing stands out.
    let subject: CGRect?
    /// Who or what the cover is of, to bring closer: its people, as Vision finds them, or
    /// failing those its most object-like thing. Parts of the side, from the top left.
    let focus: CGRect?
    /// Where its flow starts, in seconds, so no two songs' backgrounds start alike.
    let start: Double
    /// Made from a stand-in because the cover's picture wouldn't come, this time: not kept,
    /// so it's looked for again the next time it's asked for.
    var isStandIn = false

    /// The picture's side in pixels: enough for a pane of glass across a screen, and cheap.
    static let pixels = 96
}

/// Readies covers for the backgrounds and keeps the last few, so a song's background is
/// there at once when its cover comes round again, and the Settings previews share one.
@MainActor
final class BackdropArtStore {
    static let shared = BackdropArtStore()

    private var ready: [CoverArt: BackdropArt] = [:]
    /// Most recently used last.
    private var order: [CoverArt] = []
    private var loading: [CoverArt: Task<BackdropArt?, Never>] = [:]
    private static let kept = 12

    func cached(_ cover: CoverArt?) -> BackdropArt? {
        guard let cover, let art = ready[cover] else { return nil }
        touch(cover)
        return art
    }

    /// The cover readied, or nil if there's no picture of it at all. Callers asking for the
    /// same cover at once share one load.
    func art(for cover: CoverArt) async -> BackdropArt? {
        if let art = ready[cover] {
            touch(cover)
            return art
        }
        if let task = loading[cover] { return await task.value }
        let task = Task { await Self.make(cover) }
        loading[cover] = task
        let art = await task.value
        loading[cover] = nil
        if let art, !art.isStandIn {
            ready[cover] = art
            touch(cover)
        }
        return art
    }

    /// Readies these covers ahead, one after another, in the background.
    func prepare(_ covers: [CoverArt?]) {
        let covers = covers.compactMap(\.self).filter { ready[$0] == nil }
        guard !covers.isEmpty else { return }
        Task(priority: .utility) {
            for cover in covers {
                _ = await art(for: cover)
            }
        }
    }

    private func touch(_ cover: CoverArt) {
        guard order.last != cover else { return }
        order.removeAll { $0 == cover }
        order.append(cover)
        while order.count > Self.kept {
            ready[order.removeFirst()] = nil
        }
    }

    private static func make(_ cover: CoverArt) async -> BackdropArt? {
        guard let (picture, isStandIn) = await picture(of: cover) else { return nil }
        // A larger copy for Vision, which can't find a small figure in a few dozen pixels.
        let looked = await CoverTint.smallImage(for: cover, pixels: CoverSubject.pixels) ?? picture
        let pixels = BackdropArt.pixels
        let prepared = await OffMainActor.run { () -> (CGImage, CGImage, CGImage, [CoverPalette.Colour], CoverBleed?, CGRect?, CGRect?)? in
            guard let clear = SoftCover.soften(picture, by: 1.5),
                  let flowing = SoftCover.soften(picture, by: 3.5),
                  let soft = SoftCover.soften(picture, by: 8)
            else { return nil }
            let bleed = CoverBleed(rgba: CoverPixels.rgba(of: picture, side: pixels), side: pixels)
            return (clear, flowing, soft, CoverPalette.colours(rgba: CoverPixels.rgba(of: picture, side: 24)), bleed, CoverSubject.bounds(in: looked), CoverSubject.focus(in: looked))
        }
        guard let (clear, flowing, soft, found, bleed, subject, focus) = prepared else { return nil }
        let colours = CoverPalette.filled(found, to: 4).map { Color(red: $0.red, green: $0.green, blue: $0.blue) }
        let field = await CoverTint.color(for: cover) ?? found.first.map { colour in
            let deep = CoverTint.deepened((colour.red, colour.green, colour.blue))
            return Color(red: deep.red, green: deep.green, blue: deep.blue)
        } ?? CoverStage.fallback
        return BackdropArt(
            clear: clear,
            flowing: flowing,
            soft: soft,
            colours: colours.isEmpty ? [field] : colours,
            deep: CoverTint.deepPalette(found),
            lights: lights(from: CoverPalette.filled(found, to: 3)),
            field: field,
            bleed: bleed,
            subject: subject,
            focus: focus,
            start: Double(UInt(bitPattern: cover.hashValue) % 600),
            isStandIn: isStandIn
        )
    }

    private static func lights(from colours: [CoverPalette.Colour]) -> [Color] {
        let vivid = colours.prefix(4).sorted { $0.chroma > $1.chroma }.prefix(3)
        return vivid.map { colour in
            let rich = CoverTint.saturated((colour.red, colour.green, colour.blue), by: 1.3)
            let high = max(rich.red, rich.green, rich.blue, 0.01)
            let lift = max(high, 0.85) / high
            return Color(red: min(1, rich.red * lift), green: min(1, rich.green * lift), blue: min(1, rich.blue * lift))
        }
    }

    /// The cover as a small picture, however it's drawn, and whether it's a stand-in for a
    /// picture that wouldn't come.
    private static func picture(of cover: CoverArt) async -> (CGImage, isStandIn: Bool)? {
        if let image = await CoverTint.smallImage(for: cover, pixels: BackdropArt.pixels) {
            return (image, false)
        }
        let side = CGFloat(BackdropArt.pixels)
        switch cover {
        case .url(let address, let seed):
            // No cover, or one that wouldn't come: the stand-in its row shows.
            return render(GeneratedCover(seed: seed).frame(width: side, height: side)).map { ($0, address != nil) }
        case .artwork(let artwork):
            // A library cover only MusicKit can draw: its own colours, as a soft picture. The
            // same for one whose picture wouldn't come, until it does.
            let isStandIn = CoverImage.loadableURL(of: artwork, pixels: BackdropArt.pixels) != nil
            guard let background = artwork.backgroundColor else { return nil }
            let base = Color(cgColor: background)
            let accents = [artwork.primaryTextColor, artwork.secondaryTextColor]
                .compactMap { $0.map { Color(cgColor: $0) } }
            let accent = accents.first ?? base.mix(with: .white, by: 0.3)
            return render(
                MeshGradient(
                    width: 3,
                    height: 3,
                    points: [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.62, 0.4], [1, 0.5], [0, 1], [0.5, 1], [1, 1]],
                    colors: [
                        base, base, base.mix(with: accent, by: 0.35),
                        base, base.mix(with: accent, by: 0.5), base,
                        base.mix(with: .black, by: 0.3), base, base.mix(with: .black, by: 0.2),
                    ]
                )
                .frame(width: side, height: side)
            ).map { ($0, isStandIn) }
        }
    }

    private static func render(_ view: some View) -> CGImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.cgImage
    }
}

/// What a cover is of, found by Vision: the part of it the eye goes to first (attention-based
/// saliency), and any words on it (a title the eye may skip, but nobody wants cut off). Full
/// Cover places a cover by it: on the Mac a figure cut off at the waist stands on the window's
/// bottom edge; on iPhone a cover whose subject sits low rises under the top bar.
nonisolated enum CoverSubject {
    /// The salient objects' and words' bounds together, from the top left, in parts of the side.
    static func bounds(in image: CGImage) -> CGRect? {
        let salient = VNGenerateAttentionBasedSaliencyImageRequest()
        let words = VNDetectTextRectanglesRequest()
        onDevicesItRuns(salient, words)
        // Each on its own: one that can't read so small a picture mustn't lose the other.
        for request in [salient, words] as [VNRequest] {
            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        }
        let boxes = (salient.results?.first?.salientObjects ?? []).map(\.boundingBox)
            + (words.results ?? []).map(\.boundingBox)
        let union = boxes.reduce(CGRect.null) { $0.union($1) }
        // Vision's boxes run from the bottom left.
        let found = boxes.isEmpty ? nil : CGRect(x: union.minX, y: 1 - union.maxY, width: union.width, height: union.height)
        // Vision misses some lettering (a hand-drawn script) and the top of a head of hair, so
        // the first row where anything stands out from the top edge counts as the subject's
        // top too.
        guard let standsOut = firstRowStandingOut(in: image) else { return found }
        guard let found else { return CGRect(x: 0, y: standsOut, width: 1, height: 1 - standsOut) }
        guard standsOut < found.minY else { return found }
        return CGRect(x: found.minX, y: standsOut, width: found.width, height: found.maxY - standsOut)
    }

    /// The Simulator has no Neural Engine or GPU for Vision's models, and its requests fail
    /// there unless they're told to use the processor.
    private static func onDevicesItRuns(_ requests: VNRequest...) {
        #if targetEnvironment(simulator)
        guard let cpu = MLComputeDevice.allComputeDevices.first(where: { if case .cpu = $0 { true } else { false } }) else { return }
        for request in requests {
            request.setComputeDevice(cpu, for: .main)
        }
        #endif
    }

    /// The side of the copy Vision reads.
    static let pixels = 512

    /// Who or what the cover is of: its people together, or failing those the most
    /// object-like thing in it. Nil when there's neither.
    static func focus(in image: CGImage) -> CGRect? {
        let people = VNDetectHumanRectanglesRequest()
        people.upperBodyOnly = false
        onDevicesItRuns(people)
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([people])
        var boxes = (people.results ?? []).filter { $0.confidence > 0.5 }.map(\.boundingBox)
        if boxes.isEmpty {
            let objects = VNGenerateObjectnessBasedSaliencyImageRequest()
            onDevicesItRuns(objects)
            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([objects])
            boxes = (objects.results?.first?.salientObjects ?? []).sorted { $0.confidence > $1.confidence }.prefix(1).map(\.boundingBox)
        }
        guard !boxes.isEmpty else { return nil }
        let union = boxes.reduce(CGRect.null) { $0.union($1) }
        return CGRect(x: union.minX, y: 1 - union.maxY, width: union.width, height: union.height)
    }

    /// The first row, from the top, in which more than 2% of the cover differs in lightness (as
    /// the eye has it) by more than 0.3 from its top edge's own: in parts of the side, nil when
    /// nothing does.
    private static func firstRowStandingOut(in image: CGImage) -> CGFloat? {
        let side = 64
        let rgba = CoverPixels.rgba(of: image, side: side)
        guard rgba.count == side * side * 4 else { return nil }
        func lightness(_ index: Int) -> Double {
            let y = CoverBleed.Colour(red: Double(rgba[index]) / 255, green: Double(rgba[index + 1]) / 255, blue: Double(rgba[index + 2]) / 255).luminance
            return (y > 0.008856 ? 116 * cbrt(y) - 16 : 903.3 * y) / 100
        }
        let band = (1..<4).flatMap { row in (0..<side).map { lightness((row * side + $0) * 4) } }.sorted()
        let typical = band[band.count / 2]
        for row in 1..<side {
            let standing = (0..<side).filter { abs(lightness((row * side + $0) * 4) - typical) > 0.3 }.count
            if Double(standing) / Double(side) > 0.02 { return CGFloat(row) / CGFloat(side) }
        }
        return nil
    }
}

/// A cover's pixels, drawn small, for its colours.
nonisolated enum CoverPixels {
    static func rgba(of image: CGImage, side: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? pixels : []
    }
}

/// A small cover softened, so stretched across a screen it reads as the cover out of focus.
nonisolated enum SoftCover {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Softened by `radius` pixels, the picture's own size kept.
    static func soften(_ image: CGImage, by radius: Float) -> CGImage? {
        let input = CIImage(cgImage: image)
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = input.clampedToExtent()
        blur.radius = radius
        guard let output = blur.outputImage?.cropped(to: input.extent) else { return nil }
        return context.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}

enum BackdropFocusMarking { case bounds, none }

/// Where the cover sits in the player, for a background that lights it from behind.
struct BackdropFocusKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

extension View {
    /// Marks this as the cover the background centres on.
    func backdropFocus() -> some View {
        anchorPreference(key: BackdropFocusKey.self, value: .bounds) { $0 }
    }

    /// Marks this as the cover the background centres on, or, with `.none`, leaves it to
    /// something inside it to say where the cover is.
    func backdropFocus(_ marking: BackdropFocusMarking) -> some View {
        transformAnchorPreference(key: BackdropFocusKey.self, value: .bounds) { value, bounds in
            if marking == .bounds { value = bounds }
        }
    }
}
