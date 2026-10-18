import SwiftUI
import TracksCore

/// Plays per week or month on a detail page, with the selected bar read out in the header.
struct PlaysOverTimeCard: View {
    let timeline: [TimeBucket]
    let unit: Calendar.Component
    @State private var selected: TimeBucket?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    CardLabel(title: "Plays Over Time", systemImage: "chart.bar.fill", tint: .accentColor)
                    Spacer()
                    if let selected {
                        ChartReadout(bucket: selected, unit: unit, measure: .plays)
                    }
                }
                .animation(.snappy(duration: 0.2), value: selected?.start)
                ActivityChart(buckets: timeline, unit: unit, measure: .plays, height: 150, selected: $selected)
            }
        }
    }
}
