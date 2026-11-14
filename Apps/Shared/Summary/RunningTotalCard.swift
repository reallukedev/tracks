import SwiftUI
import Charts
import TracksCore

/// Listening added up across the range, over last period's line for the same days, so
/// being ahead or behind is something you can see. Drag or hover to read a day.
struct RunningTotalCard: View {
    let summary: StatsSummary
    @State private var selection: Date?
    /// The points' labels and the scale, worked out once per range rather than on every
    /// redraw: a drag or hover across the chart redraws it every frame.
    @State private var plotted = Memo<PlotKey, Plot>()
    @Environment(\.statsPaging) private var paging
    private let calendar = Calendar.current

    private struct PlotKey: Equatable {
        let pace: [PacePoint]
        let unit: Calendar.Component
    }

    private struct Point: Identifiable {
        let point: PacePoint
        let dateLabel: String
        let currentLabel: String
        let previousLabel: String?
        var id: Date { point.start }
    }

    private struct Plot {
        let points: [Point]
        /// The points with a current value, up to today.
        let current: [Point]
        let hasComparison: Bool
        let ceiling: Double
        let domain: ClosedRange<Date>
    }

    private var plot: Plot {
        plotted.value(for: PlotKey(pace: summary.pace, unit: summary.timelineUnit)) {
            let unit = summary.timelineUnit
            let points = summary.pace.map { point in
                Point(
                    point: point,
                    dateLabel: ActivityChart.dateLabel(point.start, unit: unit),
                    currentLabel: Format.listening(point.current ?? 0),
                    previousLabel: point.previous.map(Format.listening)
                )
            }
            let peak = summary.pace.map { max($0.current ?? 0, $0.previous ?? 0) }.max() ?? 0
            return Plot(
                points: points,
                current: points.filter { $0.point.current != nil },
                hasComparison: summary.pace.contains { $0.previous != nil },
                ceiling: ChartCeiling.rounded(peak / 60 * 1.08),
                domain: domain
            )
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                CardLabel(title: "Running Total", systemImage: "chart.line.uptrend.xyaxis")

                headline
                    .animation(.snappy(duration: 0.2), value: selected?.start)

                chart

                if hasComparison {
                    HStack(spacing: 16) {
                        ChartKey(title: "\(summary.currentKeyTitle)", swatch: .line(dashed: false))
                        ChartKey(title: "\(summary.previousKeyTitle)", swatch: .line(dashed: true))
                    }
                    .accessibilityHidden(true)
                }
            }
        }
    }

    // MARK: - Headline

    @ViewBuilder
    private var headline: some View {
        if let point = selected {
            StatHeadline(detail: Text(ActivityChart.dateLabel(point.start, unit: summary.timelineUnit))) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    if let current = point.current {
                        ListeningTotal(seconds: current, numberFont: StatValue.font)
                    }
                    if let previous = point.previous {
                        Text("\(summary.previousKeyTitle): \(Format.listening(previous))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else if summary.range != .allTime, let previous = summary.previousListeningSeconds {
            // Against the same stretch of last period, to the minute, not to the day.
            let difference = summary.listeningSeconds - previous
            if abs(difference) < 5 * 60 {
                StatHeadline(detail: Text("Level with \(summary.previousPhrase)")) {
                    StatValue(Text("On Pace"))
                }
            } else {
                StatHeadline(detail: difference > 0
                    ? Text("Ahead of \(summary.previousPhrase)")
                    : Text("Behind \(summary.previousPhrase)")
                ) {
                    ListeningTotal(seconds: abs(difference), numberFont: StatValue.font)
                }
            }
        } else {
            StatHeadline(detail: summary.range == .allTime
                ? Text("Since your first song")
                : summary.isCurrentPeriod ? Text("So far \(summary.phrase)") : Text("In \(summary.periodTitle)")
            ) {
                ListeningTotal(seconds: summary.listeningSeconds, numberFont: StatValue.font)
            }
        }
    }

    // MARK: - Chart

    private var chart: some View {
        let unit = summary.timelineUnit
        let plot = plot
        let selected = selected

        return Chart {
            if plot.hasComparison {
                ForEach(plot.points) { point in
                    if let previous = point.point.previous {
                        LineMark(
                            x: .value("Date", point.point.start, unit: unit),
                            y: .value("Listening", previous / 60),
                            series: .value("Period", "previous")
                        )
                        // A plain grey: `.secondary` inside a chart takes on the accent.
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 3]))
                        .interpolationMethod(.monotone)
                        .accessibilityLabel(Text("\(point.dateLabel), \(summary.previousKeyTitle)"))
                        .accessibilityValue(point.previousLabel ?? "")
                    }
                }
            }

            ForEach(plot.current) { point in
                let minutes = (point.point.current ?? 0) / 60
                AreaMark(
                    x: .value("Date", point.point.start, unit: unit),
                    y: .value("Listening", minutes)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.monotone)
                .accessibilityHidden(true)

                LineMark(
                    x: .value("Date", point.point.start, unit: unit),
                    y: .value("Listening", minutes),
                    series: .value("Period", "current")
                )
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
                .accessibilityLabel(point.dateLabel)
                .accessibilityValue(point.currentLabel)
            }

            // Where today is, or the day under the pointer.
            if let point = selected ?? plot.current.last?.point, let value = point.current {
                PointMark(
                    x: .value("Date", point.start, unit: unit),
                    y: .value("Listening", value / 60)
                )
                .foregroundStyle(Color.accentColor)
                .symbolSize(48)
                .accessibilityHidden(true)
            }

            if let selected {
                RuleMark(x: .value("Date", selected.start, unit: unit))
                    .foregroundStyle(.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .accessibilityHidden(true)
            }
        }
        .chartXScale(domain: plot.domain)
        .chartYScale(domain: 0...max(plot.ceiling, 1))
        .periodSwipe(paging, selection: $selection)
        .chartXAxis { ActivityChart.dateAxis(unit: unit, count: summary.pace.count) }
        .chartYAxis { ActivityChart.amountAxis(ceiling: plot.ceiling, measure: .listening) }
        .chartLegend(.hidden)
        .frame(minHeight: 150, maxHeight: .infinity)
        .chartTextSize()
        .sensoryFeedback(.selection, trigger: selected?.start)
    }

    // MARK: - Values

    private var hasComparison: Bool { plot.hasComparison }

    /// The day or month under the pointer, if it has anything to show.
    private var selected: PacePoint? {
        guard let selection else { return nil }
        return summary.pace.first {
            calendar.isDate($0.start, equalTo: selection, toGranularity: summary.timelineUnit)
                && ($0.current != nil || $0.previous != nil)
        }
    }

    /// The whole range, so the line stops at today with the rest of the range still ahead.
    private var domain: ClosedRange<Date> {
        guard let first = summary.pace.first?.start,
              let last = summary.pace.last?.start,
              let end = calendar.date(byAdding: summary.timelineUnit, value: 1, to: last)
        else { return Date.now...Date.now.addingTimeInterval(1) }
        return first...end
    }
}
