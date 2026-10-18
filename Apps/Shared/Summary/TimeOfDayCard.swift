import SwiftUI
import TracksCore

/// Morning, afternoon, evening and night as shares of the listening time, the busiest one
/// named up top and its bar picked out.
struct TimeOfDayCard: View {
    let summary: StatsSummary

    var body: some View {
        let total = max(1, summary.dayParts.reduce(0) { $0 + $1.seconds })
        let busiest = summary.busiestDayPart?.part

        Card {
            VStack(alignment: .leading, spacing: 14) {
                CardLabel(title: "Time of Day", systemImage: "sun.horizon")

                if let top = summary.busiestDayPart {
                    StatHeadline(detail: Text("\(Format.percent(top.seconds / total)) of your listening time")) {
                        StatValue(Text(top.part.name))
                    }
                }

                VStack(spacing: 12) {
                    ForEach(summary.dayParts) { entry in
                        DayPartRow(entry: entry, share: entry.seconds / total, isBusiest: entry.part == busiest)
                    }
                }
            }
        }
    }
}

/// Symbol, name and hours, a bar, and the percentage. The name column is as wide as the
/// widest name in any row, so the bars start and end together.
private struct DayPartRow: View {
    let entry: DayPartCount
    let share: Double
    let isBusiest: Bool
    @ScaledMetric(relativeTo: .body) private var symbolWidth: CGFloat = 24
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            // At accessibility sizes the bar gets a line of its own, rather than being
            // squeezed to nothing between two columns of large text.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        symbol
                        label(for: entry.part, wraps: true)
                        Spacer(minLength: 8)
                        percentage
                            .fixedSize()
                    }
                    bar
                }
            } else {
                HStack(spacing: 12) {
                    symbol
                    ZStack(alignment: .leading) {
                        ForEach(DayPart.allCases, id: \.self) { part in
                            label(for: part).hidden()
                        }
                        label(for: entry.part)
                    }
                    bar
                    ZStack(alignment: .trailing) {
                        Text(Format.percent(1)).hidden()
                        percentage
                    }
                    .monospacedDigit()
                }
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(entry.part.name))
        .accessibilityValue("\(Format.percent(share)), \(entry.part.hours)")
    }

    private var symbol: some View {
        Image(systemName: entry.part.symbol)
            .font(.body)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(isBusiest ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .frame(width: symbolWidth)
    }

    private var bar: some View {
        ProportionBar(
            fraction: share,
            style: isBusiest
                ? AnyShapeStyle(Color.accentColor.gradient)
                : AnyShapeStyle(Color.accentColor.opacity(0.45))
        )
    }

    private var percentage: some View {
        Text(Format.percent(share))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .contentTransition(.numericText(value: share))
    }

    /// Name over hours. On one line each beside the bar, where the widest sets the column;
    /// wrapping at accessibility sizes, where the percentage mustn't be what breaks.
    private func label(for part: DayPart, wraps: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(part.name)
                .font(.subheadline.weight(.medium))
            Text(part.hours)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .lineLimit(wraps ? nil : 1)
        .fixedSize(horizontal: !wraps, vertical: true)
    }
}
