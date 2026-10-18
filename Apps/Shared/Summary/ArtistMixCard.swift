import SwiftUI
import TracksCore

/// How the plays split between the top artists and everyone else: one bar for the whole,
/// then a row per artist. Shades step down with rank, so the order reads without a key.
struct ArtistMixCard: View {
    let summary: StatsSummary
    private static let limit = 5
    /// One shade per rank, strongest first.
    private static let shades: [Double] = [1, 0.78, 0.6, 0.45, 0.32]

    var body: some View {
        let mix = summary.artistMix(limit: Self.limit)
        let total = Double(max(1, mix.whole))

        Card {
            VStack(alignment: .leading, spacing: 14) {
                CardLabel(title: "Artist Mix", systemImage: "chart.pie")

                if let top = mix.artists.first {
                    StatHeadline(detail: Text("of your plays went to \(top.name)")) {
                        StatValue(verbatim: Format.percent(Double(top.count) / total))
                    }
                }

                MixBar(
                    shares: mix.artists.map { Double($0.count) / total },
                    otherShare: Double(mix.otherCount) / total,
                    shades: Self.shades
                )

                VStack(spacing: 0) {
                    ForEach(mix.artists.enumerated(), id: \.element.id) { index, artist in
                        NavigationLink(value: Route.artist(artist.id)) {
                            MixRow(
                                name: Text(artist.name),
                                share: Double(artist.count) / total,
                                swatch: AnyShapeStyle(Color.accentColor.opacity(Self.shades[index])),
                                showsChevron: true
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    if mix.otherCount > 0 {
                        MixRow(
                            name: Text("Everyone Else"),
                            share: Double(mix.otherCount) / total,
                            swatch: AnyShapeStyle(.quaternary),
                            showsChevron: false
                        )
                    }
                }
            }
        }
    }
}

/// The whole range as one capsule, cut into each artist's share.
private struct MixBar: View {
    let shares: [Double]
    let otherShare: Double
    let shades: [Double]
    private static let gap: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            let segments = shares.count + (otherShare > 0 ? 1 : 0)
            let width = max(0, geometry.size.width - Self.gap * CGFloat(max(0, segments - 1)))
            HStack(spacing: Self.gap) {
                ForEach(shares.indices, id: \.self) { index in
                    Rectangle()
                        .fill(Color.accentColor.opacity(shades[index]))
                        .frame(width: width * shares[index])
                }
                if otherShare > 0 {
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: width * otherShare)
                }
            }
        }
        .frame(height: 14)
        .clipShape(.capsule)
        .accessibilityHidden(true)
    }
}

/// A swatch, a name and a percentage; a chevron when it opens the artist.
private struct MixRow: View {
    let name: Text
    let share: Double
    let swatch: AnyShapeStyle
    let showsChevron: Bool
    @ScaledMetric(relativeTo: .subheadline) private var swatchSize: CGFloat = 10
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(swatch)
                .frame(width: swatchSize, height: swatchSize)
            name
                // Wraps at accessibility sizes rather than cutting a name to a few letters.
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            Spacer(minLength: 8)
            Text(Format.percent(share))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
                .contentTransition(.numericText(value: share))
            #if os(iOS)
            // Like a table row that pushes. The Mac's lists open on a click without one.
            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .opacity(showsChevron ? 1 : 0)
                .accessibilityHidden(true)
            #endif
        }
        .font(.subheadline)
        .padding(.vertical, 6)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
