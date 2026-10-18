import SwiftUI
import TracksCore

/// The week, month, year or all time choice that heads Summary.
struct RangePicker: View {
    @Binding var range: StatsRange

    var body: some View {
        Picker("Range", selection: $range) {
            ForEach(StatsRange.allCases, id: \.self) { range in
                Text(range.label).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}
