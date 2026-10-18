import SwiftUI
import TracksCore

/// Top songs, artists and albums, one list at a time.
struct ChartsScreen: View {
    @AppStorage(ChartKind.storageKey) private var kind: ChartKind = .songs

    var body: some View {
        TopChartView(kind: kind, kindSelection: $kind)
            .navigationTitle("Charts")
    }
}
