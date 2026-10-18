import SwiftUI

/// Diagonal stripes over a pale wash of a colour, for a chart series that has to read as
/// different from a solid one beside it without relying on the colour alone: in greyscale,
/// with a colour vision deficiency, or when the solid one is dimmed.
///
/// Works as a `foregroundStyle` for Charts marks and as a legend swatch.
///
/// `nonisolated` because SwiftUI draws the tile on its async render thread. Under the
/// target's main-actor default the renderer closure inherited main-actor isolation, and
/// Swift's runtime isolation check trapped when SwiftUI called it off the main thread.
nonisolated enum HatchPattern {
    /// The tile, which repeats seamlessly: one stripe corner to corner and the ends of its
    /// neighbours in the opposite corners.
    private static let tile: CGFloat = 6

    /// - Parameters:
    ///   - color: Resolved against `environment` before drawing, since the tile is drawn
    ///     outside the view tree and would otherwise miss dark mode and the app's accent.
    ///   - increasedContrast: A stronger wash and heavier stripes, for Increase Contrast.
    static func paint(
        _ color: Color,
        increasedContrast: Bool,
        in environment: EnvironmentValues
    ) -> ImagePaint {
        let resolved = Color(color.resolve(in: environment))
        let washOpacity = increasedContrast ? 0.45 : 0.25
        let stripeOpacity = increasedContrast ? 1.0 : 0.75
        let lineWidth: CGFloat = increasedContrast ? 2 : 1.5
        let side = tile
        let image = Image(size: CGSize(width: side, height: side)) { @Sendable context in
            context.fill(Path(CGRect(x: 0, y: 0, width: side, height: side)), with: .color(resolved.opacity(washOpacity)))
            var stripes = Path()
            for offset in [-side, 0, side] {
                stripes.move(to: CGPoint(x: offset - 1, y: side + 1))
                stripes.addLine(to: CGPoint(x: offset + side + 1, y: -1))
            }
            context.stroke(stripes, with: .color(resolved.opacity(stripeOpacity)), lineWidth: lineWidth)
        }
        return ImagePaint(image: image, scale: 1)
    }
}
