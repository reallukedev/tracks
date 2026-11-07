import SwiftUI
import TracksCore

/// On demand, radio or recovered, and the stations a song came from, for a song's pages.
struct HowYouHeardItCard: View {
    let sources: [SourceCount]
    let stations: [NamedCount]
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Only worth a card when there's more than one way it was heard, or a station to name.
    static func isWorthShowing(sources: [SourceCount], stations: [NamedCount]) -> Bool {
        sources.count > 1 || !stations.isEmpty
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                CardLabel(title: "How You Heard It", systemImage: "headphones", tint: .accentColor)
                if sources.count > 1 {
                    SourcesDonut(sources: sources)
                }
                ForEach(stations) { station in
                    Label {
                        // At the largest sizes the count goes under the name, which gets the width.
                        let layout = typeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
                        layout {
                            Text(station.name)
                            if !typeSize.isAccessibilitySize { Spacer() }
                            Text("^[\(station.count) time](inflect: true)")
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.pink)
                    }
                    .font(.subheadline)
                }
            }
        }
    }
}
