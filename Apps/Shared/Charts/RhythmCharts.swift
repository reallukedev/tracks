import SwiftUI
import Charts
import TracksCore

/// Plays per day of the week, weekends in a lighter shade.
struct WeekdayChart: View {
    let weekdays: [WeekdayCount]
    /// Nil fills the height it's offered, at least 140 points, for a card stretched to
    /// match the one beside it.
    var height: CGFloat? = 140

    var body: some View {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        Chart(weekdays) { day in
            BarMark(
                x: .value("Day", String(day.weekday)),
                y: .value("Plays", day.count)
            )
            .foregroundStyle(day.isWeekend ? Self.weekendStyle : Self.weekdayStyle)
            .cornerRadius(4)
            .accessibilityLabel(Calendar.current.weekdaySymbols[day.weekday - 1])
            .accessibilityValue(Text("\(day.count) plays"))
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let weekday = value.as(String.self).flatMap(Int.init) {
                        Text(symbols[weekday - 1])
                    }
                }
            }
        }
        .chartYAxis(.hidden)
        .frame(minHeight: height ?? 140, maxHeight: height ?? .infinity)
        .chartTextSize()
    }

    static let weekdayStyle = AnyShapeStyle(Color.accentColor.gradient)
    static let weekendStyle = AnyShapeStyle(Color.accentColor.opacity(0.5))
}

/// On demand vs radio vs recovered, as a ring with a legend.
struct SourcesDonut: View {
    let sources: [SourceCount]

    var body: some View {
        let total = max(1, sources.reduce(0) { $0 + $1.count })
        AdaptiveStack(spacing: 20) {
            Chart(sources) { source in
                SectorMark(
                    angle: .value("Plays", source.count),
                    innerRadius: .ratio(0.62),
                    angularInset: 1.5
                )
                .cornerRadius(3)
                .foregroundStyle(source.kind.tint)
                .accessibilityLabel(Text(source.kind.label))
                .accessibilityValue(Text("\(source.count) plays"))
            }
            .chartLegend(.hidden)
            .frame(width: 92, height: 92)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(sources) { source in
                    HStack(spacing: 8) {
                        Circle().fill(source.kind.tint).frame(width: 8, height: 8)
                        Text(source.kind.label)
                        Spacer(minLength: 8)
                        Text((Double(source.count) / Double(total)).formatted(.percent.precision(.fractionLength(0))))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// Days down the side, hours across: how much was played at each hour of each weekday.
///
/// A grid rather than Charts, so the day names sit in their own column, centred on their
/// rows, and an empty hour reads as empty in the same grey the Listening Clock uses.
/// Tinting empty cells with the accent turned every row into one long stripe.
struct HeatMapChart: View {
    let cells: [HeatCell]
    /// The shortest a row gets.
    var rowHeight: CGFloat = 24
    /// Rows grow to fill a card stretched to match the one beside it.
    var fillsHeight = false
    /// Room for the widest short day name, growing with the text size.
    @ScaledMetric(relativeTo: .caption) private var labelWidth: CGFloat = 30
    @Environment(\.colorSchemeContrast) private var contrast
    private let calendar = Calendar.current
    private static let gap: CGFloat = 3

    var body: some View {
        let counts = Dictionary(grouping: cells, by: \.weekday)
            .mapValues { Dictionary($0.map { ($0.hour, $0.count) }) { first, _ in first } }
        let peak = max(1, cells.map(\.count).max() ?? 1)

        VStack(spacing: Self.gap) {
            ForEach(orderedWeekdays, id: \.self) { weekday in
                let hours = counts[weekday] ?? [:]
                HStack(spacing: 8) {
                    Text(calendar.shortWeekdaySymbols[weekday - 1])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: labelWidth, alignment: .trailing)
                    HStack(spacing: Self.gap) {
                        ForEach(0..<24, id: \.self) { hour in
                            let count = hours[hour] ?? 0
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(count == 0
                                    ? AnyShapeStyle(.quaternary)
                                        : AnyShapeStyle(Color.accentColor.opacity(
                                        ListeningIntensity.opacity(Double(count) / Double(peak), contrast: contrast)
                                    )))
                        }
                    }
                }
                .frame(minHeight: rowHeight, maxHeight: fillsHeight ? .infinity : rowHeight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(calendar.weekdaySymbols[weekday - 1])
                .accessibilityValue(summary(of: hours))
            }
            HStack(spacing: 8) {
                Color.clear
                    .frame(width: labelWidth, height: 0)
                // Four equal blocks of six hours, so each label starts at its column.
                HStack(spacing: Self.gap) {
                    ForEach([0, 6, 12, 18], id: \.self) { hour in
                        Text(Format.hour(hour))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.top, 3)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
    }

    private var orderedWeekdays: [Int] {
        (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
    }

    private func summary(of hours: [Int: Int]) -> String {
        guard let busiest = hours.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), busiest.value > 0 else {
            return String(localized: "Nothing played")
        }
        let total = hours.values.reduce(0, +)
        return String(AttributedString(
            localized: "^[\(total) play](inflect: true), busiest around \(Format.hour(busiest.key))"
        ).characters)
    }
}
