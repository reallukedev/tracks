import SwiftUI
import Charts
import TracksCore

/// Plays by the decade each song came out, the favourite decade picked out, with how much
/// was brand new and the oldest song underneath.
struct DecadesCard: View {
    let summary: StatsSummary

    var body: some View {
        let known = Double(max(1, summary.knownYearPlays))
        let top = summary.topDecade

        Card {
            VStack(alignment: .leading, spacing: 14) {
                CardLabel(title: "Decades", systemImage: "calendar.badge.clock")

                if let top {
                    StatHeadline(detail: Text("\(Format.percent(Double(top.count) / known)) of your plays came out then")) {
                        StatValue(Text(verbatim: Format.decade(top.decade)))
                    }
                }

                chart(top: top)

                AdaptiveStack(spacing: 8) {
                    if let share = summary.recentReleaseShare {
                        StatFootnote(title: "Recent Releases", value: Text(Format.percent(share)))
                        Spacer(minLength: 0)
                    }
                    if let median = summary.medianReleaseYear {
                        StatFootnote(title: "Median Year", value: Text(verbatim: Format.year(median)))
                        Spacer(minLength: 0)
                    }
                }

                if let oldest = summary.oldestRelease {
                    Divider()
                    NavigationLink(value: Route.song(oldest.songID)) {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Oldest Song")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(oldest.title) · \(oldest.artistName)")
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Text(verbatim: Format.year(oldest.year))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .fixedSize()
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func chart(top: DecadeCount?) -> some View {
        // Full years while they fit, the short form once there are many decades.
        let isCrowded = summary.decades.count > 6
        return Chart(summary.decades) { entry in
            BarMark(
                x: .value("Decade", String(entry.decade)),
                y: .value("Plays", entry.count)
            )
            .foregroundStyle(entry.decade == top?.decade
                ? AnyShapeStyle(Color.accentColor.gradient)
                : AnyShapeStyle(Color.accentColor.opacity(0.45)))
            .cornerRadius(4)
            .accessibilityLabel(Format.decade(entry.decade))
            .accessibilityValue(Text("^[\(entry.count) play](inflect: true)"))
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let decade = value.as(String.self).flatMap(Int.init) {
                        Text(verbatim: isCrowded ? Format.shortDecade(decade) : Format.decade(decade))
                    }
                }
            }
        }
        .chartYAxis(.hidden)
        .frame(minHeight: 120, maxHeight: .infinity)
        .chartTextSize()
    }
}
