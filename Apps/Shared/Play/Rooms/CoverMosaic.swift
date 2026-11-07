import SwiftUI
import TracksCore

/// A room's covers in its own arrangement: the covers of what you play in it, or of new songs
/// for it, never invented. While they load, each place holds a faint square of the same size;
/// with none to show, the room's symbol, large and faint.
struct CoverMosaic: View {
    let covers: [CoverArt]
    let layout: RoomStyle.Covers
    /// The size of one cover, which every arrangement is worked out from.
    let side: CGFloat
    let symbol: String
    var isLoading = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let frame = Self.size(of: layout, side: side)
        ZStack {
            if covers.isEmpty, !isLoading {
                Image(systemName: symbol)
                    .font(.system(size: side * 0.9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.18))
                    .rotationEffect(.degrees(-10))
            } else {
                ForEach(Self.places(for: layout, side: side).enumerated().reversed(), id: \.offset) { index, place in
                    slot(index: index, place: place)
                }
            }
        }
        .frame(width: frame.width, height: frame.height)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : PlayMotion.panel, value: covers)
        .accessibilityHidden(true)
    }

    private func slot(index: Int, place: Place) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: CoverImage.radius(for: place.side), style: .continuous)
                .fill(.white.opacity(0.14))
            if index < covers.count {
                CoverImage(cover: covers[index], size: place.side)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(width: place.side, height: place.side)
        .shadow(color: .black.opacity(index < covers.count ? 0.28 : 0), radius: place.side * 0.08, y: place.side * 0.04)
        .rotationEffect(.degrees(place.angle))
        .offset(x: place.x, y: place.y)
    }

    /// Where one cover goes: its size, its offset from the centre and its tilt. The first is
    /// the one in front, the most played.
    struct Place {
        var side: CGFloat
        var x: CGFloat = 0
        var y: CGFloat = 0
        var angle: Double = 0
    }

    /// How many covers an arrangement shows.
    static func count(for layout: RoomStyle.Covers) -> Int {
        places(for: layout, side: 1).count
    }

    static func places(for layout: RoomStyle.Covers, side s: CGFloat) -> [Place] {
        switch layout {
        case .fan:
            [Place(side: s, y: -s * 0.04), Place(side: s * 0.9, x: -s * 0.52, y: s * 0.04, angle: -11), Place(side: s * 0.9, x: s * 0.52, y: s * 0.04, angle: 11)]
        case .pile:
            [Place(side: s, x: s * 0.12, y: s * 0.1, angle: 3), Place(side: s * 0.92, x: -s * 0.36, y: -s * 0.1, angle: -8), Place(side: s * 0.86, x: s * 0.44, y: -s * 0.16, angle: 9)]
        case .grid:
            // Three by two, a crate seen from above, the first top left.
            (0..<6).map { index in
                let cell = s * 0.6, gap = s * 0.04
                return Place(side: cell, x: CGFloat(index % 3 - 1) * (cell + gap), y: CGFloat(index / 3) * (cell + gap) - (cell + gap) / 2)
            }
        case .strip:
            // Rising left to right, each a little bigger than the one before, the most played last.
            (0..<4).map { rank in
                let step = CGFloat(3 - rank)
                return Place(side: s * (0.62 + 0.1 * step), x: (step - 1.5) * s * 0.56, y: -(step - 1.5) * s * 0.14)
            }
        case .single:
            [Place(side: s * 1.12)]
        case .pair:
            [Place(side: s, x: s * 0.26, y: s * 0.06, angle: 5), Place(side: s * 0.94, x: -s * 0.3, y: -s * 0.05, angle: -6)]
        }
    }

    /// The box an arrangement fills, with room for its tilts.
    static func size(of layout: RoomStyle.Covers, side s: CGFloat) -> CGSize {
        switch layout {
        case .fan: CGSize(width: s * 2.15, height: s * 1.18)
        case .pile: CGSize(width: s * 2.0, height: s * 1.36)
        case .grid: CGSize(width: s * 1.88, height: s * 1.26)
        case .strip: CGSize(width: s * 2.5, height: s * 1.32)
        case .single: CGSize(width: s * 1.16, height: s * 1.16)
        case .pair: CGSize(width: s * 1.72, height: s * 1.2)
        }
    }
}
