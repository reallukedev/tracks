import SwiftUI
import Charts
import TracksCore

/// Plays over the range split into songs heard for the first time and songs heard before.
/// The new ones sit on the baseline in the full accent, so days of discovery stand out and
/// can be compared. Drag or hover to read a day.
///
/// Heard-before plays are paler, and hatched as well with Differentiate Without Color on, so
/// the two read apart without colour. A selection greys out the other days rather than
/// fading them, which would make a faded new bar look like a heard-before one.
struct DiscoveryCard: View {
    let summary: StatsSummary
    @State private var selection: Date?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiatesWithoutColor
    @Environment(\.self) private var environment
    private let calendar = Calendar.current

    private struct Day: Identifiable {
        let start: Date
        let new: Int
        let familiar: Int
        var id: Date { start }
    }

    var body: some View {
        let days = self.days
        let selected = selectedDay(in: days)
        Card {
            VStack(alignment: .leading, spacing: 14) {
                CardLabel(title: "Discovery", systemImage: "sparkles")

                headline(selected: selected)
                    .animation(.snappy(duration: 0.2), value: selected?.start)

                chart(days: days, selected: selected)

                HStack(spacing: 16) {
                    ChartKey(title: "New to You", swatch: .bar(newStyle(isDimmed: false)))
                    ChartKey(title: "Heard Before", swatch: .bar(familiarStyle(isDimmed: false)))
                }
                .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Headline

    @ViewBuilder
    private func headline(selected: Day?) -> some View {
        if let day = selected {
            StatHeadline(detail: Text(ActivityChart.dateLabel(day.start, unit: summary.timelineUnit))) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    StatValue(Text("\(day.new) new"))
                    Text("\(day.familiar) heard before")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            StatHeadline(detail: Text("of plays were new to you, ^[\(summary.firstTimeHeardCount) song](inflect: true) in all")) {
                StatValue(verbatim: Format.percent(summary.firstTimeHeardRate ?? 0))
            }
        }
    }

    // MARK: - Chart

    private func chart(days: [Day], selected: Day?) -> some View {
        let unit = summary.timelineUnit
        // Made once here, not per bar: a hatch is a small drawn image.
        let familiar = familiarStyle(isDimmed: false)
        let familiarDimmed = familiarStyle(isDimmed: true)
        return Chart {
            ForEach(days.filter { $0.new + $0.familiar > 0 }) { day in
                let isDimmed = selected.map { $0.start != day.start } ?? false
                BarMark(
                    x: .value("Date", day.start, unit: unit),
                    y: .value("Plays", day.new)
                )
                .foregroundStyle(newStyle(isDimmed: isDimmed))
                .accessibilityLabel(ActivityChart.dateLabel(day.start, unit: unit))
                .accessibilityValue(Text("\(day.new) new, \(day.familiar) heard before"))

                BarMark(
                    x: .value("Date", day.start, unit: unit),
                    y: .value("Plays", day.familiar)
                )
                .foregroundStyle(isDimmed ? familiarDimmed : familiar)
                .accessibilityHidden(true)
            }

            if let selected {
                RuleMark(x: .value("Date", selected.start, unit: unit))
                    .foregroundStyle(.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .accessibilityHidden(true)
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...max(ceiling, 1))
        .chartXSelection(value: $selection)
        .chartXAxis { ActivityChart.dateAxis(unit: unit, count: days.count) }
        .chartYAxis { ActivityChart.amountAxis(ceiling: ceiling, measure: .plays) }
        .chartLegend(.hidden)
        .frame(minHeight: 150, maxHeight: .infinity)
        .chartTextSize()
        .sensoryFeedback(.selection, trigger: selected?.start)
    }

    // MARK: - Styles

    /// Solid. The accent, or grey on a day that isn't the selected one.
    private func newStyle(isDimmed: Bool) -> AnyShapeStyle {
        guard isDimmed else { return AnyShapeStyle(Color.accentColor.gradient) }
        return AnyShapeStyle(Self.dimmedColor.opacity(contrast == .increased ? 0.8 : 0.55))
    }

    /// A paler shade of the new plays' colour, hatched when colour alone mustn't tell them apart.
    private func familiarStyle(isDimmed: Bool) -> AnyShapeStyle {
        let color = isDimmed ? Self.dimmedColor : .accentColor
        guard differentiatesWithoutColor else {
            return AnyShapeStyle(color.opacity(contrast == .increased ? 0.5 : 0.32))
        }
        return AnyShapeStyle(HatchPattern.paint(color, increasedContrast: contrast == .increased, in: environment))
    }

    private static let dimmedColor = Color.gray

    // MARK: - Values

    /// The timeline and the first hearings share their buckets, so they line up one to one.
    private var days: [Day] {
        let new = Dictionary(summary.newSongTimeline.map { ($0.start, $0.count) }) { first, _ in first }
        return summary.timeline.map { bucket in
            let fresh = min(bucket.count, new[bucket.start] ?? 0)
            return Day(start: bucket.start, new: fresh, familiar: bucket.count - fresh)
        }
    }

    private func selectedDay(in days: [Day]) -> Day? {
        guard let selection else { return nil }
        return days.first {
            calendar.isDate($0.start, equalTo: selection, toGranularity: summary.timelineUnit)
                && $0.new + $0.familiar > 0
        }
    }

    private var ceiling: Double {
        Double(summary.timeline.map(\.count).max() ?? 0) * 1.08
    }

    private var domain: ClosedRange<Date> {
        guard let first = summary.timeline.first?.start,
              let last = summary.timeline.last?.start,
              let end = calendar.date(byAdding: summary.timelineUnit, value: 1, to: last)
        else { return Date.now...Date.now.addingTimeInterval(1) }
        return first...end
    }
}
