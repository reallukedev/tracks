import SwiftUI
import Charts
import TracksCore

/// Bars over time with a dashed average line, like Screen Time. Drag or hover to read a bar.
struct ActivityChart: View {
    enum Measure {
        case listening
        case plays
    }

    let buckets: [TimeBucket]
    let unit: Calendar.Component
    var measure: Measure = .listening
    /// In the chart's own units (minutes for listening). `nil` hides the line.
    var average: Double?
    var height: CGFloat = 180
    /// Grows past `height` to fill a card stretched to match its neighbours.
    var fillsHeight = false
    /// The bar under the finger or pointer. The card shows it in place of its headline.
    @Binding var selected: TimeBucket?

    @State private var selection: Date?
    @Environment(\.statsPaging) private var paging
    private let calendar = Calendar.current

    init(
        buckets: [TimeBucket],
        unit: Calendar.Component,
        measure: Measure = .listening,
        average: Double? = nil,
        height: CGFloat = 180,
        fillsHeight: Bool = false,
        selected: Binding<TimeBucket?> = .constant(nil)
    ) {
        self.buckets = buckets
        self.unit = unit
        self.measure = measure
        self.average = average
        self.height = height
        self.fillsHeight = fillsHeight
        self._selected = selected
    }

    var body: some View {
        Chart {
            // Empty buckets are left out; a zero-height bar still draws its rounded corners
            // as a little stub. The x scale below keeps their space.
            ForEach(buckets.filter { $0.count > 0 }) { bucket in
                BarMark(
                    x: .value("Date", bucket.start, unit: unit),
                    y: .value("Amount", value(of: bucket))
                )
                .foregroundStyle(Color.accentColor.gradient)
                .cornerRadius(unit == .day ? 3 : 4)
                .opacity(isDimmed(bucket) ? 0.3 : 1)
                .accessibilityLabel(dateLabel(bucket.start))
                .accessibilityValue(valueLabel(of: bucket))
            }

            if let average, average > 0, selection == nil {
                RuleMark(y: .value("Average", average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        AverageTag()
                    }
                    .accessibilityHidden(true)
            }

            if let selectedBucket {
                RuleMark(x: .value("Date", selectedBucket.start, unit: unit))
                    .foregroundStyle(.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .accessibilityHidden(true)
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...max(yCeiling, 1))
        .periodSwipe(paging, selection: $selection)
        .chartXAxis { Self.dateAxis(unit: unit, count: buckets.count) }
        .chartYAxis { Self.amountAxis(ceiling: yCeiling, measure: measure) }
        .frame(minHeight: height, maxHeight: fillsHeight ? .infinity : height)
        .chartTextSize()
        .sensoryFeedback(.selection, trigger: selectedBucket?.start)
        .onChange(of: selectedBucket) { _, bucket in selected = bucket }
    }

    // MARK: - Values

    private func value(of bucket: TimeBucket) -> Double {
        switch measure {
        case .listening: bucket.seconds / 60
        case .plays: Double(bucket.count)
        }
    }

    private var yCeiling: Double {
        let peak = buckets.map(value).max() ?? 0
        return max(peak, average ?? 0) * 1.08
    }

    /// Round values for the y axis: whole hours (or half hours, or minutes) for listening,
    /// whole numbers for plays. Automatic ticks landed on 1.5 h and printed "2h" twice.
    static func ticks(ceiling: Double, measure: Measure) -> [Double] {
        let ceiling = max(ceiling, 1)
        let steps: [Double] = switch measure {
        case .listening: [5, 10, 15, 30, 60, 120, 180, 300, 600, 1_200, 3_000, 6_000]
        case .plays: [1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1_000, 2_500, 5_000]
        }
        let step = steps.first { ceiling / $0 <= 3 } ?? ceiling / 3
        return Array(stride(from: 0, through: ceiling, by: step))
    }

    private var selectedBucket: TimeBucket? {
        guard let selection else { return nil }
        return buckets.first { calendar.isDate($0.start, equalTo: selection, toGranularity: unit) && $0.count > 0 }
    }

    private func isDimmed(_ bucket: TimeBucket) -> Bool {
        guard let selected = selectedBucket else { return false }
        return selected.start != bucket.start
    }

    /// The whole range, so empty days stay visible as gaps.
    private var domain: ClosedRange<Date> {
        guard let first = buckets.first?.start,
              let last = buckets.last?.start,
              let end = calendar.date(byAdding: unit, value: 1, to: last)
        else { return Date.now...Date.now.addingTimeInterval(1) }
        return first...end
    }

    // MARK: - Labels

    /// Dates along the bottom, the same on every chart over time so they read alike.
    @AxisContentBuilder
    static func dateAxis(unit: Calendar.Component, count: Int) -> some AxisContent {
        switch unit {
        case .day where count <= 7:
            AxisMarks(values: .stride(by: .day)) { value in
                AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
            }
        case .day:
            AxisMarks(values: .stride(by: .day, count: 7)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        case .month where count <= 12:
            AxisMarks(values: .stride(by: .month)) { value in
                AxisValueLabel(format: .dateTime.month(.narrow), centered: true)
            }
        case .weekOfYear:
            AxisMarks(values: .stride(by: .weekOfYear, count: max(1, count / 4))) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        default:
            AxisMarks(values: .stride(by: .month, count: max(1, count / 4))) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel(format: .dateTime.month(.abbreviated).year())
            }
        }
    }

    /// Amounts up the trailing edge on dotted grid lines. `ceiling` is in the chart's own
    /// units: minutes for listening.
    static func amountAxis(ceiling: Double, measure: Measure) -> some AxisContent {
        AxisMarks(position: .trailing, values: ticks(ceiling: ceiling, measure: measure)) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            AxisValueLabel {
                if let amount = value.as(Double.self) {
                    Text(axisLabel(amount, measure: measure))
                }
            }
        }
    }

    static func axisLabel(_ amount: Double, measure: Measure) -> String {
        switch measure {
        case .plays:
            return Int(amount).formatted()
        case .listening:
            return Format.listening(amount * 60)
        }
    }

    private func dateLabel(_ date: Date) -> String {
        Self.dateLabel(date, unit: unit)
    }

    private func valueLabel(of bucket: TimeBucket) -> String {
        Self.valueLabel(of: bucket, measure: measure)
    }

    static func dateLabel(_ date: Date, unit: Calendar.Component) -> String {
        switch unit {
        case .day: date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        case .weekOfYear: String(localized: "Week of \(date.formatted(.dateTime.day().month(.abbreviated)))")
        default: date.formatted(.dateTime.month(.wide).year())
        }
    }

    static func valueLabel(of bucket: TimeBucket, measure: Measure) -> String {
        switch measure {
        case .listening: Format.listening(bucket.seconds)
        case .plays: String(AttributedString(localized: "^[\(bucket.count) play](inflect: true)").characters)
        }
    }
}

/// The selected bar's date and value, for a card's header.
struct ChartReadout: View {
    let bucket: TimeBucket
    let unit: Calendar.Component
    let measure: ActivityChart.Measure

    var body: some View {
        HStack(spacing: 6) {
            Text(ActivityChart.dateLabel(bucket.start, unit: unit))
                .foregroundStyle(.secondary)
            Text(ActivityChart.valueLabel(of: bucket, measure: measure))
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.subheadline)
        .transition(.opacity)
    }
}

/// "avg" over a chart's average line, on a plate of what's behind the chart so it still
/// reads where the line runs into a tall bar. Charts sit in a card by default.
struct AverageTag<Plate: View>: View {
    @ViewBuilder var plate: Plate

    var body: some View {
        Text("avg")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 3)
            .background { plate.clipShape(.rect(cornerRadius: 3)) }
    }
}

extension AverageTag where Plate == CardFill {
    init() { plate = CardFill() }
}
