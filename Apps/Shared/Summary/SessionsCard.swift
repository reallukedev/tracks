import SwiftUI
import Charts
import TracksCore

/// How long people listen for once they start: the average session up top, how the
/// sessions spread across lengths, and the longest one.
struct SessionsCard: View {
    let sessions: SessionStats

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                CardLabel(title: "Sessions", systemImage: "timer")

                StatHeadline(detail: Text("Average length of ^[\(sessions.count) session](inflect: true)")) {
                    ListeningTotal(seconds: sessions.averageSeconds, numberFont: StatValue.font)
                }

                Chart(sessions.lengths) { entry in
                    BarMark(
                        x: .value("Length", String(entry.length.rawValue)),
                        y: .value("Sessions", entry.count)
                    )
                    .foregroundStyle(Color.accentColor.gradient)
                    .cornerRadius(4)
                    .annotation(position: .top, spacing: 3) {
                        if entry.count > 0 {
                            Text(entry.count.formatted())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .accessibilityLabel(entry.length.spokenLabel)
                    .accessibilityValue(Text("^[\(entry.count) session](inflect: true)"))
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let raw = value.as(String.self).flatMap(Int.init), let length = SessionLength(rawValue: raw) {
                                Text(length.shortLabel)
                            }
                        }
                    }
                }
                .chartYAxis(.hidden)
                // Headroom for the counts above the tallest bar.
                .chartYScale(domain: 0...Double(max(1, sessions.lengths.map(\.count).max() ?? 1)) * 1.25)
                .frame(minHeight: 110, maxHeight: .infinity)
                .chartTextSize()

                AdaptiveStack(spacing: 8) {
                    if let longest = sessions.longest {
                        StatFootnote(title: "Longest", value: Text(Format.listening(longest.seconds)))
                        Spacer(minLength: 0)
                    }
                    StatFootnote(title: "Songs per Session", value: Text(Format.decimal(sessions.averageSongCount)))
                }
            }
        }
    }
}
