import SwiftUI

/// A mood's or genre's field behind its hero: its two colours blended, still, up under the bar
/// and into any pull past the top, melting into the page below the hero's last control over an
/// eased fade, so nothing white sits on a faded part.
struct RoomField: View {
    let style: RoomStyle

    var body: some View {
        MeshGradient(width: 3, height: 3, points: Self.points, colors: style.field)
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(
                        stops: Self.fadeStops,
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: Self.fade)
                }
            }
            .padding(.top, -400)
            .accessibilityHidden(true)
    }

    /// Below the last control, where the page shows through at last.
    static let fade: CGFloat = 72

    /// A little off the grid, so the blend has no straight seams.
    private static let points: [SIMD2<Float>] = [
        [0, 0], [0.55, 0], [1, 0],
        [0, 0.45], [0.62, 0.52], [1, 0.4],
        [0, 1], [0.45, 1], [1, 1],
    ]

    /// Smoothstep, so the fade has no start or end to see.
    private static let fadeStops: [Gradient.Stop] = (0...10).map { step in
        let t = Double(step) / 10
        return .init(color: .black.opacity(1 - t * t * (3 - 2 * t)), location: t)
    }
}

/// A mood's or genre's field on a tile: the same blend, without the fade.
struct RoomTileField: View {
    let style: RoomStyle

    var body: some View {
        MeshGradient(width: 3, height: 3, points: Self.points, colors: style.field)
            .accessibilityHidden(true)
    }

    private static let points: [SIMD2<Float>] = [
        [0, 0], [0.5, 0], [1, 0],
        [0, 0.5], [0.6, 0.45], [1, 0.5],
        [0, 1], [0.5, 1], [1, 1],
    ]
}
