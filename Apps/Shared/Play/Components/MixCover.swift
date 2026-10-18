import SwiftUI
import TracksCore

/// A mix's cover: the covers of the songs in it, four to a square when there are four, with
/// the mix's symbol in the corner. Made from what was actually played, never a stock gradient.
struct MixCover: View {
    let mix: Mix
    var size: CGFloat

    var body: some View {
        let covers = mix.covers
        ZStack(alignment: .bottomLeading) {
            if covers.count >= 4 {
                let half = size / 2
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        tile(covers[0], half)
                        tile(covers[1], half)
                    }
                    HStack(spacing: 0) {
                        tile(covers[2], half)
                        tile(covers[3], half)
                    }
                }
            } else {
                ArtworkView(url: covers.first?.url, seed: covers.first?.seed ?? mix.id, size: size, isBare: true)
            }
            Image(systemName: mix.kind.symbol)
                .font(.system(size: size * 0.1, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size * 0.2, height: size * 0.2)
                .background(.black.opacity(0.45), in: .circle)
                .padding(size * 0.05)
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: CoverImage.radius(for: size), style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CoverImage.radius(for: size), style: .continuous)
                .stroke(.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    /// A quarter of the square, drawn without its own rounding.
    private func tile(_ cover: MixCoverArt, _ side: CGFloat) -> some View {
        ArtworkView(url: cover.url, seed: cover.seed, size: side, isBare: true)
    }
}
