import SwiftUI
import TracksCore

/// The genres played most, as a ranked list with bars measured against the top one. Shares
/// are out of the plays whose genre is known, and the card says so when that isn't nearly all.
struct TopGenresCard: View {
    let summary: StatsSummary
    var limit = 6

    var body: some View {
        let known = Double(max(1, summary.knownGenrePlays))
        let peak = Double(max(1, summary.topGenres.first?.count ?? 1))

        Card {
            VStack(alignment: .leading, spacing: 14) {
                CardLabel(title: "Top Genres", systemImage: "guitars")

                if let top = summary.topGenres.first {
                    StatHeadline(detail: Text("\(Format.percent(Double(top.count) / known)) of your plays, from ^[\(top.artistCount) artist](inflect: true)")) {
                        StatValue(Text(verbatim: top.name))
                    }
                }

                VStack(spacing: 12) {
                    ForEach(summary.topGenres.prefix(limit).enumerated(), id: \.element.id) { index, genre in
                        GenreRow(
                            genre: genre,
                            share: Double(genre.count) / known,
                            fraction: Double(genre.count) / peak,
                            isTop: index == 0
                        )
                    }
                }

                footnote
            }
        }
    }

    /// How many genres there were, and how much of the range they cover while lookups are
    /// still arriving or for songs Apple Music doesn't have.
    private var footnote: some View {
        Group {
            if summary.genreCoverage < 0.95 {
                Text("^[\(summary.genreCount) genre](inflect: true) · Known for \(Format.percent(summary.genreCoverage)) of plays")
            } else {
                Text("^[\(summary.genreCount) genre](inflect: true) in all")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// A genre's name and share, over a bar as long as its plays against the top genre's.
private struct GenreRow: View {
    let genre: GenreTally
    let share: Double
    let fraction: Double
    let isTop: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: genre.name)
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Text(Format.percent(share))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
                    .contentTransition(.numericText(value: share))
            }
            ProportionBar(
                fraction: fraction,
                style: isTop
                    ? AnyShapeStyle(Color.accentColor.gradient)
                    : AnyShapeStyle(Color.accentColor.opacity(0.45)),
                height: 6
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: genre.name))
        .accessibilityValue(Text("\(Format.percent(share)) of plays, ^[\(genre.artistCount) artist](inflect: true)"))
    }
}
