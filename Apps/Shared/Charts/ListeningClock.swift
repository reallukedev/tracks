import SwiftUI
import Accessibility
import TracksCore

/// A 24-hour dial: one wedge per hour, reaching further out where there was more listening.
/// Midnight is at the top and the day runs clockwise.
///
/// Drawn by hand rather than with `SectorMark`. Charts sizes each sector's radius against the
/// others, so varying the outer radius per hour pushed the wedges off-centre.
struct ListeningClock: View {
    let hourly: [HourCount]
    var tint: Color = .accentColor
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let peak = max(1, hourly.map(\.count).max() ?? 1)
        ZStack {
            ForEach(hourly) { entry in
                let fraction = Double(entry.count) / Double(peak)
                HourWedge(hour: entry.hour, fraction: max(fraction, 0.05))
                    .fill(entry.count == 0
                        ? AnyShapeStyle(.quaternary)
                        : AnyShapeStyle(tint.opacity(ListeningIntensity.opacity(fraction, contrast: contrast))))
            }
            HourTicks()
                .stroke(.secondary.opacity(0.5), lineWidth: 1)
            centreLabel
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Listening by hour of the day")
        .accessibilityValue(accessibilitySummary)
        // Audio Graphs, and the hour-by-hour detail the spoken summary leaves out.
        .accessibilityChartDescriptor(ListeningClockDescriptor(hourly: hourly))
    }

    @ViewBuilder
    private var centreLabel: some View {
        if let busiest = hourly.max(by: { $0.count < $1.count }), busiest.count > 0 {
            VStack(spacing: 0) {
                Text("Peak")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(Format.hour(busiest.hour))
                    .font(.headline)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
    }

    /// The total and the three busiest hours with their counts, since hour names alone don't
    /// say whether 9 PM was a little busier than 8 PM or ten times busier.
    private var accessibilitySummary: String {
        ListeningClockDescriptor.summary(of: hourly)
    }
}

/// The clock as data for VoiceOver's Audio Graphs: hours along one axis, plays up the other.
private struct ListeningClockDescriptor: AXChartDescriptorRepresentable {
    let hourly: [HourCount]

    func makeChartDescriptor() -> AXChartDescriptor {
        let ordered = hourly.sorted { $0.hour < $1.hour }
        let peak = Double(max(1, ordered.map(\.count).max() ?? 1))

        let hours = AXCategoricalDataAxisDescriptor(
            title: String(localized: "Hour"),
            categoryOrder: ordered.map { Format.hour($0.hour) }
        )
        let plays = AXNumericDataAxisDescriptor(
            title: String(localized: "Plays"),
            range: 0...peak,
            gridlinePositions: []
        ) { value in
            Self.plays(Int(value.rounded()))
        }
        let series = AXDataSeriesDescriptor(
            name: String(localized: "Plays"),
            isContinuous: false,
            dataPoints: ordered.map { AXDataPoint(x: Format.hour($0.hour), y: Double($0.count)) }
        )
        return AXChartDescriptor(
            title: String(localized: "Listening by hour of the day"),
            summary: Self.summary(of: hourly),
            xAxis: hours,
            yAxis: plays,
            additionalAxes: [],
            series: [series]
        )
    }

    /// "42 plays. Busiest: 9 PM, 12 plays; 8 PM, 9 plays; and 10 PM, 7 plays", or that nothing
    /// was played, so an empty clock doesn't read as a label with no value.
    static func summary(of hourly: [HourCount]) -> String {
        let total = hourly.reduce(0) { $0 + $1.count }
        guard total > 0 else { return String(localized: "Nothing played") }
        let busiest = hourly
            .filter { $0.count > 0 }
            .sorted { ($0.count, $1.hour) > ($1.count, $0.hour) }
            .prefix(3)
            .map { String(localized: "\(Format.hour($0.hour)), \(plays($0.count))") }
            .formatted(.list(type: .and))
        return String(localized: "\(plays(total)). Busiest: \(busiest)")
    }

    private static func plays(_ count: Int) -> String {
        String(AttributedString(localized: "^[\(count) play](inflect: true)").characters)
    }
}

/// One hour's wedge, from the inner ring outward by `fraction` of the remaining radius.
nonisolated private struct HourWedge: Shape {
    let hour: Int
    let fraction: Double
    static let innerRatio = 0.36

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let inner = radius * Self.innerRatio
        let outer = inner + (radius - inner) * fraction
        // Midnight at twelve o'clock, with a small gap either side of each wedge.
        let gap = 0.9
        let start = Angle.degrees(Double(hour) * 15 - 90 + gap)
        let end = Angle.degrees(Double(hour + 1) * 15 - 90 - gap)

        var path = Path()
        path.addArc(center: centre, radius: outer, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: centre, radius: inner, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// Small marks inside the ring at midnight, 6, noon and 6, so the dial reads as a clock.
nonisolated private struct HourTicks: Shape {
    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        for quarter in 0..<4 {
            let angle = Double(quarter) * .pi / 2 - .pi / 2
            let from = CGPoint(x: centre.x + cos(angle) * radius * HourWedge.innerRatio * 0.82,
                               y: centre.y + sin(angle) * radius * HourWedge.innerRatio * 0.82)
            let to = CGPoint(x: centre.x + cos(angle) * radius * HourWedge.innerRatio * 0.92,
                             y: centre.y + sin(angle) * radius * HourWedge.innerRatio * 0.92)
            path.move(to: from)
            path.addLine(to: to)
        }
        return path
    }
}

/// The clock with a label and a key for which way round it goes.
struct ListeningClockCard: View {
    let hourly: [HourCount]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardLabel(title: "Listening Clock", systemImage: "clock")
            ZStack {
                ListeningClock(hourly: hourly)
                    .padding(28)
                clockLabels
            }
            .frame(maxWidth: 320)
            .frame(maxWidth: .infinity)
        }
    }

    /// 12 AM at the top, 6 AM right, 12 PM bottom, 6 PM left, in the margin around the dial.
    private var clockLabels: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let centre = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let radius = side / 2 - 9
            ForEach([0, 6, 12, 18], id: \.self) { hour in
                let angle = Double(hour) / 24 * 2 * .pi - .pi / 2
                Text(Format.hour(hour))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .position(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
