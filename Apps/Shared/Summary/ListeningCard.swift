import SwiftUI
import TracksCore

/// The top card: how much you listened in the range, how that compares, and the bars.
struct ListeningCard: View {
    let summary: StatsSummary
    var chartHeight: CGFloat = 170
    /// Lets the chart grow past `chartHeight`, so the card can match the column beside it
    /// without leaving empty space.
    var fillsHeight = false
    @State private var selected: TimeBucket?
    @Environment(\.statsPaging) private var paging

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                AdaptiveStack(verticalAlignment: .firstTextBaseline) {
                    CardLabel(title: "Listening", systemImage: "headphones", tint: .accentColor)
                    Spacer(minLength: 0)
                    if let paging, summary.range != .allTime {
                        PeriodPager(summary: summary, paging: paging)
                    } else {
                        Text(summary.periodTitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    ListeningTotal(seconds: selected?.seconds ?? summary.listeningSeconds)
                    if let selected {
                        Text(ActivityChart.dateLabel(selected.start, unit: summary.timelineUnit))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        comparison
                    }
                }
                .animation(.snappy(duration: 0.2), value: selected?.start)
                .accessibilityElement(children: .combine)

                if summary.timelineIsInformative {
                    ActivityChart(
                        buckets: summary.timeline,
                        unit: summary.timelineUnit,
                        average: averagePerBucket,
                        height: chartHeight,
                        fillsHeight: fillsHeight,
                        selected: $selected
                    )
                }

                AdaptiveStack(spacing: 8) {
                    StatFootnote(title: "Daily Average", value: Text(Format.listening(summary.dailyAverageSeconds)))
                    Spacer(minLength: 0)
                    StatFootnote(title: "Songs", value: Text(summary.captureCount.formatted()))
                    Spacer(minLength: 0)
                    StatFootnote(title: "Active Days", value: Text(summary.activeDays.formatted()))
                }
            }
        }
    }

    @ViewBuilder
    private var comparison: some View {
        if let change = summary.listeningChange, abs(change) < 0.03, summary.range != .allTime {
            Label {
                Text("About the same as \(summary.previousPhrase)")
            } icon: {
                Image(systemName: "equal")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } else if let change = summary.listeningChange, summary.range != .allTime {
            let symbol = change >= 0 ? "arrow.up.right" : "arrow.down.right"
            Label {
                Text("\(Format.percentChange(change)) from \(summary.previousPhrase)")
            } icon: {
                Image(systemName: symbol)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } else {
            Text("^[\(summary.captureCount) song](inflect: true) from ^[\(summary.uniqueArtistCount) artist](inflect: true)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// The dashed line: average per elapsed bucket, in minutes.
    private var averagePerBucket: Double? {
        let elapsed = summary.timeline.filter { $0.start <= summary.generatedAt }
        guard elapsed.count > 1 else { return nil }
        return elapsed.reduce(0) { $0 + $1.seconds } / Double(elapsed.count) / 60
    }
}

/// "18 hr 20 min" with big numbers and small units.
struct ListeningTotal: View {
    let seconds: TimeInterval
    var numberFont: Font = .system(.largeTitle, design: .rounded, weight: .bold)

    var body: some View {
        Self.text(seconds, numberFont: numberFont)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.secondary)
            .contentTransition(.numericText(value: seconds))
            .accessibilityLabel(Format.listening(seconds))
    }

    /// The numbers in `numberFont` and the primary colour, the units left to take whatever
    /// font and colour surround them, so the result can sit inside a longer sentence.
    static func text(_ seconds: TimeInterval, numberFont: Font) -> Text {
        let parts = Format.listeningParts(seconds)
        func number(_ value: Int) -> Text {
            Text(value.formatted())
                .font(numberFont)
                .foregroundStyle(.primary)
        }
        if parts.hours > 0, parts.minutes == 0 {
            return Text("\(number(parts.hours)) hr")
        } else if parts.hours > 0 {
            return Text("\(number(parts.hours)) hr \(number(parts.minutes)) min")
        } else {
            return Text("\(number(parts.minutes)) min")
        }
    }
}
