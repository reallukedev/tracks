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
                // The counts above the bars, laid over the chart rather than as its marks'
                // annotations: Charts hosts each annotation in a view graph of its own, and with
                // the counts changing after every song, All Time kept the old ones, a couple of
                // megabytes a minute.
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        if let plot = proxy.plotFrame {
                            let frame = geometry[plot]
                            ForEach(sessions.lengths) { entry in
                                if entry.count > 0,
                                   let x = proxy.position(forX: String(entry.length.rawValue)),
                                   let y = proxy.position(forY: entry.count) {
                                    Text(entry.count.formatted())
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                        .fixedSize()
                                        // Its bottom 3 points above the bar's top.
                                        .frame(width: 0, height: 0, alignment: .bottom)
                                        .position(x: frame.minX + x, y: frame.minY + y - 3)
                                }
                            }
                        }
                    }
                    .accessibilityHidden(true)
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
