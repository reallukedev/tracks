import Charts
import TracksCore
import SwiftUI

/// Louder at Speed's curve: how loud the music plays from a stop to the highway for the amount
/// chosen, reaching your volume at highway speed. While you drive, a dot shows where you are
/// on it.
struct SpeedCurve: View {
    let amount: SpeedVolumeAmount
    /// Where the car and the music are, while following a drive: metres a second, and decibels
    /// under your highway volume.
    var now: (speed: Double, level: Double)?
    @ScaledMetric(relativeTo: .footnote) private var height: CGFloat = 128
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let tint = Color.pink
    /// The road shown: up to about 130 km/h, a little past where the music is at full.
    private static let fastest = 36.0
    private static let quietest = -13.0
    private static let speeds = Array(stride(from: 0, through: fastest, by: 0.5))
    /// Town at 50 km/h, the highway where the music reaches full.
    private static let marks = [0, 13.9, SpeedLoudness.highwaySpeed]

    var body: some View {
        Chart {
            RuleMark(y: .value("Your Volume", 0))
                .foregroundStyle(.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .annotation(position: .bottom, alignment: .leading, spacing: 4) {
                    Text("Your Volume")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            ForEach(Self.speeds, id: \.self) { speed in
                let level = SpeedLoudness.decibels(atSpeed: speed, amount: amount)
                AreaMark(
                    x: .value("Speed", speed),
                    yStart: .value("Quietest", Self.quietest),
                    yEnd: .value("Level", level)
                )
                .foregroundStyle(LinearGradient(colors: [Self.tint.opacity(0.28), Self.tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Speed", speed), y: .value("Level", level))
                    .foregroundStyle(Self.tint)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
            if let now {
                PointMark(x: .value("Speed", min(now.speed, Self.fastest)), y: .value("Level", now.level))
                    .symbol {
                        Circle()
                            .fill(Self.tint)
                            .stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2.5)
                            .frame(width: 13, height: 13)
                    }
            }
        }
        .chartXScale(domain: 0...Self.fastest)
        .chartYScale(domain: Self.quietest...0)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: Self.marks) { value in
                AxisTick(length: 4, stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(.tertiary)
                AxisValueLabel(anchor: value.index == 0 ? .topLeading : .top) {
                    if let speed = value.as(Double.self) {
                        Text(SpeedVolumeWords.roadLabel(forSpeed: speed))
                            .font(.caption2.weight(.medium))
                    }
                }
            }
        }
        .frame(height: height)
        .padding(.vertical, 8)
        .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: amount)
        .animation(reduceMotion ? nil : .smooth(duration: 0.9), value: now?.speed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Music by Speed")
        .accessibilityValue(summary)
    }

    /// The curve in words: how the music sits stopped, in town and on the highway, and where
    /// it is now.
    private var summary: Text {
        var parts = Self.marks.map { speed in
            "\(SpeedVolumeWords.roadLabel(forSpeed: speed)): \(SpeedVolumeWords.levelPhrase(SpeedLoudness.decibels(atSpeed: speed, amount: amount)))"
        }
        if let now {
            parts.append(String(localized: "Now: \(SpeedVolumeWords.levelPhrase(now.level))"))
        }
        return Text(parts.joined(separator: ". "))
    }
}

#Preview("Moderate") {
    List { SpeedCurve(amount: .moderate) }
}

#Preview("Strong, driving in town") {
    List { SpeedCurve(amount: .strong, now: (speed: 12, level: SpeedLoudness.decibels(atSpeed: 12, amount: .strong))) }
}
