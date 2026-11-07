import SwiftUI
import TracksCore

/// How widely the listening ranged: plays per song up top, then the figures behind it.
struct VarietyCard: View {
    let summary: StatsSummary

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                CardLabel(title: "Variety", systemImage: "square.grid.3x3.fill")

                StatHeadline(detail: Text("For each different song, on average")) {
                    playsPerSong
                }

                VStack(spacing: 0) {
                    FigureRow(title: "Played Once") {
                        Text("^[\(summary.oneOffSongCount) song](inflect: true)")
                    }
                    Divider()
                    FigureRow(title: "Albums") {
                        Text(summary.uniqueAlbumCount.formatted())
                    }
                    Divider()
                    FigureRow(title: "Songs per Artist") {
                        Text(Format.decimal(
                            Double(summary.uniqueSongCount) / Double(max(1, summary.uniqueArtistCount))
                        ))
                    }
                    if let artist = summary.deepestArtist {
                        Divider()
                        NavigationLink(value: Route.artist(artist.id)) {
                            FigureRow(title: "Deepest Dive") {
                                Text("\(artist.name) · ^[\(artist.songCount) song](inflect: true)")
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// "1.5 plays", big number and small unit like the listening totals.
    private var playsPerSong: some View {
        let number = Text(Format.decimal(summary.playsPerSong))
            .font(StatValue.font)
            .foregroundStyle(.primary)
        return Text(summary.playsPerSong == 1 ? "\(number) play" : "\(number) plays")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .contentTransition(.numericText(value: summary.playsPerSong))
    }
}

/// A name on the leading edge and its figure on the trailing one, as in a grouped list.
private struct FigureRow<Value: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var value: Value

    var body: some View {
        AdaptiveStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                // A long artist name is what gives way, not the label.
                .layoutPriority(1)
            Spacer(minLength: 8)
            value
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        .font(.subheadline)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
