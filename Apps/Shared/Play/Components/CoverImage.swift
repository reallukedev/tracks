import SwiftUI
import MusicKit

/// A cover from either source, at one size, with the app's corner rounding.
struct CoverImage: View {
    let cover: CoverArt
    var size: CGFloat
    var isCircle = false
    /// No rounding or edge of its own, for a tile inside a mosaic that rounds as a whole.
    var isBare = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        switch cover {
        case .artwork(let artwork):
            let shape = isBare ? AnyShape(Rectangle()) : isCircle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: Self.radius(for: size), style: .continuous))
            Group {
                // Catalog covers have an ordinary address, drawn from Tracks’ own cache: MusicKit's
                // ArtworkImage can drop its picture when its size or place changes (the mini
                // player collapsing as you scroll) and not bring it back. Library covers, and
                // the player's own songs, only MusicKit can load, so those keep ArtworkImage.
                let pixels = Self.pixels(for: size, scale: displayScale)
                if let url = Self.loadableURL(of: artwork, pixels: pixels) {
                    LoadedCover(
                        url: url,
                        pixels: pixels,
                        otherSizes: Self.otherSizes(of: artwork, pixels: pixels),
                        placeholder: artwork.backgroundColor.map { Color(cgColor: $0) }
                    )
                } else {
                    // Never asked for a new size in place: Now Playing is laid out once at no
                    // size as it opens from the mini player, then at the screen's, and its
                    // cover lost its picture on the way. It's drawn at one of a few fixed sizes
                    // and scaled to fit, and crossing to another size makes a fresh one, which
                    // loads.
                    let drawn = Self.artworkSide(for: size)
                    ArtworkImage(artwork, width: drawn, height: drawn)
                        .scaleEffect(size / drawn)
                        .id(drawn)
                }
            }
            .frame(width: size, height: size)
            .background(Color(.tertiarySystemFill))
            .clipShape(shape)
            .overlay { shape.stroke(.primary.opacity(isBare ? 0 : 0.08), lineWidth: 1) }
            .accessibilityHidden(true)
        case .url(let url, let seed):
            ArtworkView(url: url, seed: seed, size: size, isCircle: isCircle, isBare: isBare, maximumCornerRadius: Self.maximumRadius)
        }
    }

    /// 12% of the side, as ``ArtworkView`` rounds, but never under 4 points or over 12: Music's
    /// big covers are nearly square-cornered, and a 40-point curve on Now Playing reads as a tile.
    static func radius(for size: CGFloat) -> CGFloat {
        min(maximumRadius, max(4, size * 0.12))
    }

    static let maximumRadius: CGFloat = 12

    /// The size MusicKit draws a cover at: the first of a few steps at least as big as it's
    /// shown, so a cover that changes size a little keeps its picture.
    static func artworkSide(for size: CGFloat) -> CGFloat {
        [48, 96, 200, 420, 640].first { $0 >= size } ?? size
    }

    /// The first of a few steps at least as many pixels as the cover is drawn, so the cache
    /// holds a copy per step rather than per place. A row's cover at 600 pixels cost 20 times
    /// the memory and decoding it needs, and filled the cache in a few screens of scrolling.
    static func pixels(for size: CGFloat, scale: CGFloat = 2) -> Int {
        let needed = Int((size * scale).rounded(.up))
        return pixelSteps.first { $0 >= needed } ?? pixelSteps[pixelSteps.count - 1]
    }

    static let pixelSteps = [160, 400, 600, 1_200]

    /// The same cover at the other steps, largest first, to show while the chosen one loads
    /// when a cover grows or shrinks across a step.
    static func otherSizes(of artwork: Artwork, pixels: Int) -> [ArtworkImages.Key] {
        pixelSteps.reversed().filter { $0 != pixels }.compactMap { other in
            loadableURL(of: artwork, pixels: other).map { ArtworkImages.Key(url: $0, pixels: other) }
        }
    }

    /// A web address for the cover, or nil for a library cover only MusicKit can load.
    static func loadableURL(of artwork: Artwork, pixels: Int) -> URL? {
        guard let url = artwork.url(width: pixels, height: pixels),
              url.scheme == "https" || url.scheme == "http"
        else { return nil }
        return url
    }
}

/// A cover fetched through ``ArtworkImages``, which caches it, so it's there at once the next
/// time it's drawn: the cover's own colour first, then the picture.
private struct LoadedCover: View {
    let url: URL
    let pixels: Int
    let otherSizes: [ArtworkImages.Key]
    let placeholder: Color?
    @Environment(\.displayScale) private var displayScale
    @State private var loaded: (url: URL, image: CGImage)?

    var body: some View {
        ZStack {
            (placeholder ?? Color(.tertiarySystemFill))
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }
        }
        .task(id: url) {
            // Kept here as well as in the cache: the cache can let a big cover go while it's
            // still on screen, and nothing would ask for it again.
            if let cached = ArtworkImages.shared.cached(key) {
                loaded = (url, cached)
                return
            }
            // Once more after a moment if it didn't come, as a dropped request otherwise leaves
            // the cover's colour standing in for good.
            for attempt in 0..<2 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
                guard !Task.isCancelled else { return }
                if let fetched = await ArtworkImages.shared.image(for: key), !Task.isCancelled {
                    withAnimation(.easeOut(duration: 0.2)) { loaded = (url, fetched) }
                    return
                }
            }
        }
    }

    private var key: ArtworkImages.Key {
        // The address already fixes the size; the pixel count only tells the cache apart.
        ArtworkImages.Key(url: url, pixels: pixels)
    }

    private var image: CGImage? {
        if let loaded, loaded.url == url { return loaded.image }
        if let cached = ArtworkImages.shared.cached(key) { return cached }
        for other in otherSizes {
            if let cached = ArtworkImages.shared.cached(other) { return cached }
        }
        return nil
    }
}

/// The cover's own background colour, where Apple Music gave one: the colour Music paints
/// behind Now Playing.
extension CoverArt {
    var backgroundColor: Color? {
        guard case .artwork(let artwork) = self, let color = artwork.backgroundColor else { return nil }
        return Color(cgColor: color)
    }
}
