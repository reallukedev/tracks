import SwiftUI
import TracksCore

/// Four small numbers under the listening card.
struct GlanceGrid: View {
    let summary: StatsSummary
    var columns = 2

    var body: some View {
        TileGrid(tiles: tiles, columns: columns)
    }

    private var tiles: [GlanceTile] {
        [
            GlanceTile(
                title: "Artists",
                value: summary.uniqueArtistCount.formatted(),
                symbol: "music.microphone",
                tint: .pink
            ),
            GlanceTile(
                title: "Different Songs",
                value: summary.uniqueSongCount.formatted(),
                symbol: "music.note.list",
                tint: .blue
            ),
            GlanceTile(
                title: "New to You",
                value: summary.firstTimeHeardCount.formatted(),
                symbol: "sparkles",
                tint: .purple,
                detail: summary.newArtistCount > 0 ? "^[\(summary.newArtistCount) new artist](inflect: true)" : nil
            ),
            GlanceTile(
                title: "Streak",
                value: summary.streak.current.formatted(),
                symbol: "flame.fill",
                tint: .orange,
                unit: "^[\(summary.streak.current) day](inflect: true)",
                detail: summary.streak.longest > summary.streak.current
                    ? "Best: ^[\(summary.streak.longest) day](inflect: true)"
                    : nil
            ),
        ]
    }
}

/// Tiles in rows of `columns`, one column at accessibility text sizes.
struct TileGrid: View {
    let tiles: [GlanceTile]
    var columns = 2
    var spacing: CGFloat = 12
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let columns = typeSize.isAccessibilitySize ? 1 : self.columns
        let rows = stride(from: 0, to: tiles.count, by: columns).map { Array(tiles[$0..<min($0 + columns, tiles.count)]) }
        // Grid rather than LazyVGrid so every tile in a row, and a single column, share heights.
        Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
            ForEach(rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(rows[row].indices, id: \.self) { column in
                        rows[row][column]
                    }
                    // Keeps a short last row's tiles the width of the rest.
                    if rows[row].count < columns {
                        ForEach(rows[row].count..<columns, id: \.self) { _ in
                            Color.clear.gridCellUnsizedAxes(.vertical)
                        }
                    }
                }
            }
        }
    }
}

struct GlanceTile: View {
    let title: LocalizedStringKey
    let value: String
    let symbol: String
    let tint: Color
    /// Replaces the plain value with an inflected phrase, e.g. "12 days".
    var unit: LocalizedStringKey?
    var detail: LocalizedStringKey?

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                Group {
                    if let unit {
                        Text(unit)
                    } else {
                        Text(value)
                    }
                }
                .font(.system(.title2, design: .rounded, weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
