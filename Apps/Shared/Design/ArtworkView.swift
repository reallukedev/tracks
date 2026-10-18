import SwiftUI

/// Album art, with a generated cover for songs that have none.
///
/// While a real cover is on its way the square is a quiet neutral, never a made-up cover that
/// the real one then replaces. The generated cover is only for a song with no cover at all, or
/// one whose cover couldn't be fetched; it's seeded from the album or song name, so the same
/// album always gets the same colours.
struct ArtworkView: View {
    let url: String?
    /// Usually the album name, falling back to title and artist.
    let seed: String
    /// The side of the square. Nil fills the space offered, for a grid whose columns decide
    /// how big a cover is; give it a square with `aspectRatio(1, contentMode: .fit)`.
    var size: CGFloat?
    var isCircle = false
    /// Square corners and no edge, for a cover that's one tile of a larger mosaic.
    var isBare = false
    /// The most the corners round, for big covers that would otherwise look like tiles.
    var maximumCornerRadius: CGFloat = .infinity

    @Environment(\.displayScale) private var displayScale
    /// Set once the cover is loaded. One already in memory is drawn straight from the cache
    /// instead, so it's there in the row's first frame.
    @State private var loaded: (key: ArtworkImages.Key, image: CGImage)?
    /// The address that was asked for and never came, so its generated cover stands in.
    @State private var failed: ArtworkImages.Key?

    /// Covers filling a grid cell are decoded at a size that suits the largest cell.
    private static let unsizedPoints: CGFloat = 300

    var body: some View {
        let shape = CoverShape(isCircle: isCircle, isBare: isBare, maximumCornerRadius: maximumCornerRadius)
        ZStack {
            if key == nil || failed == key {
                GeneratedCover(seed: seed)
                    .transition(.opacity)
            } else {
                Color.placeholderFill
            }
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        // With no size, the offered space. A cover wider than it's tall overflows here and
        // is clipped, as it is inside a fixed frame.
        .frame(maxWidth: size == nil ? .infinity : nil, maxHeight: size == nil ? .infinity : nil)
        .clipShape(shape)
        .overlay { shape.stroke(.primary.opacity(isBare ? 0 : 0.08), lineWidth: 1) }
        .accessibilityHidden(true)
        .task(id: key) {
            guard let key, image == nil else { return }
            // A server's cover that didn't come may be there later, once the services it's
            // found on stop turning the server away: asked once more while it's on screen.
            for attempt in 0..<2 {
                if let image = await ArtworkImages.shared.image(for: key) {
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        loaded = (key, image)
                    }
                    return
                }
                guard attempt == 0, ArtworkImages.mayArriveLater(key.url) else { break }
                try? await Task.sleep(for: .seconds(ArtworkImages.retryAfter))
                guard !Task.isCancelled else { return }
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { failed = key }
        }
    }

    private var key: ArtworkImages.Key? {
        guard let url, let resolved = URL(string: url) else { return nil }
        let points = size ?? Self.unsizedPoints
        return ArtworkImages.Key(url: resolved, pixels: Int((points * displayScale).rounded(.up)))
    }

    /// The loaded cover if it's for the current address and size, otherwise one already in
    /// memory.
    private var image: CGImage? {
        guard let key else { return nil }
        if let loaded, loaded.key == key { return loaded.image }
        return ArtworkImages.shared.cached(key)
    }
}

/// A circle, or a rounded square whose corners scale with its size, so a cover sized by its
/// container rounds the same as one given a size.
nonisolated private struct CoverShape: Shape {
    let isCircle: Bool
    var isBare = false
    var maximumCornerRadius: CGFloat = .infinity

    func path(in rect: CGRect) -> Path {
        if isBare {
            return Rectangle().path(in: rect)
        }
        if isCircle {
            return Circle().path(in: rect)
        }
        let side = min(rect.width, rect.height)
        return RoundedRectangle(cornerRadius: min(maximumCornerRadius, max(4, side * 0.12)), style: .continuous).path(in: rect)
    }
}

/// A simple abstract cover: a two-tone gradient and one soft shape, all derived from a hash.
struct GeneratedCover: View {
    let seed: String

    var body: some View {
        let hash = Self.hash(seed)
        let hue = Double(hash % 360) / 360
        let shift = 0.06 + Double((hash >> 9) % 18) / 100
        let tracks = (hash >> 17) % 4

        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let top = Color(hue: hue, saturation: 0.55, brightness: 0.95)
            let bottom = Color(hue: (hue + shift).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.55)
            context.fill(Path(rect), with: .linearGradient(
                Gradient(colors: [top, bottom]),
                startPoint: .zero,
                endPoint: CGPoint(x: size.width, y: size.height)
            ))

            let light = GraphicsContext.Shading.color(.white.opacity(0.22))
            let w = size.width
            switch tracks {
            case 0:
                context.fill(Path(ellipseIn: CGRect(x: w * 0.38, y: w * 0.32, width: w * 0.8, height: w * 0.8)), with: light)
            case 1:
                for index in 0..<4 {
                    let inset = w * (0.18 + Double(index) * 0.14)
                    let ring = Path(ellipseIn: rect.insetBy(dx: inset, dy: inset).offsetBy(dx: w * 0.28, dy: w * 0.28))
                    context.stroke(ring, with: light, lineWidth: max(1, w * 0.035))
                }
            case 2:
                var stripes = Path()
                for index in stride(from: -1.0, through: 2.0, by: 0.22) {
                    stripes.move(to: CGPoint(x: w * index, y: w))
                    stripes.addLine(to: CGPoint(x: w * (index + 1), y: 0))
                }
                context.stroke(stripes, with: .color(.white.opacity(0.14)), lineWidth: max(1, w * 0.06))
            default:
                var wave = Path()
                wave.move(to: CGPoint(x: 0, y: w * 0.62))
                wave.addCurve(
                    to: CGPoint(x: w, y: w * 0.5),
                    control1: CGPoint(x: w * 0.35, y: w * 0.35),
                    control2: CGPoint(x: w * 0.6, y: w * 0.85)
                )
                wave.addLine(to: CGPoint(x: w, y: w))
                wave.addLine(to: CGPoint(x: 0, y: w))
                wave.closeSubpath()
                context.fill(wave, with: light)
            }
        }
    }

    /// FNV-1a. `hashValue` changes between launches, which would reshuffle every colour.
    static func hash(_ string: String) -> Int {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01B3
        }
        return Int(value & 0x7FFF_FFFF)
    }
}

#Preview {
    HStack {
        ForEach(["Tides", "Glasshouse", "Northbound", "Soft Focus"], id: \.self) {
            ArtworkView(url: nil, seed: $0, size: 80)
        }
        ArtworkView(url: nil, seed: "Mara Solis", size: 80, isCircle: true)
    }
    .padding()
}
