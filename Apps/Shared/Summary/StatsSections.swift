import SwiftUI
import TracksCore

// The Summary's deeper sections, shared by the iPhone and Mac layouts. Each hides
// itself when the range has too little in it to say anything.

/// Songs first heard in the range that got played again.
struct NewFavoritesSection: View {
    let summary: StatsSummary
    var limit = 5

    var body: some View {
        if !summary.newFavourites.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("New Favorites")
                TopSongsCard(songs: summary.newFavourites, limit: limit)
            }
            .id("favorites")
        }
    }
}

/// The genres played most beside the decades the songs came from. Fills in as Tracks looks
/// songs up in Apple Music, so it's missing until enough plays have a genre or a year.
struct GenresSection: View {
    let summary: StatsSummary

    var body: some View {
        if summary.genresAreInformative || summary.decadesAreInformative {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Genres & Eras")
                CardPair {
                    if summary.genresAreInformative {
                        TopGenresCard(summary: summary)
                    }
                    if summary.decadesAreInformative {
                        DecadesCard(summary: summary)
                    }
                }
            }
            .id("genres")
        }
    }
}

/// Time of Day beside Sessions, under the Listening Clock and the week.
struct RhythmDetailsRow: View {
    let summary: StatsSummary

    var body: some View {
        CardPair {
            TimeOfDayCard(summary: summary)
            if summary.sessionsAreInformative {
                SessionsCard(sessions: summary.listeningSessions)
            }
        }
    }
}

/// Listening per weekday and per weekend day, under the week chart.
struct DayTypeFootnotes: View {
    let summary: StatsSummary
    /// Whether a weekday chart is above, whose weekend bars are lighter: then each figure
    /// shows its bars' colour, so the lighter ones read as weekends rather than as less.
    var keysWeekdayChart = false

    var body: some View {
        if summary.weekdayAverageSeconds != nil || summary.weekendAverageSeconds != nil {
            AdaptiveStack(spacing: 8) {
                if let weekday = summary.weekdayAverageSeconds {
                    StatFootnote(title: "Weekdays", value: Text("\(Format.listening(weekday)) a day"), swatch: keysWeekdayChart ? WeekdayChart.weekdayStyle : nil)
                    Spacer(minLength: 0)
                }
                if let weekend = summary.weekendAverageSeconds {
                    StatFootnote(title: "Weekends", value: Text("\(Format.listening(weekend)) a day"), swatch: keysWeekdayChart ? WeekdayChart.weekendStyle : nil)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// How the range built up, and how much of it was new.
struct TrendsSection: View {
    let summary: StatsSummary

    var body: some View {
        if summary.paceIsInformative || summary.newVsFamiliarIsInformative {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Trends")
                CardPair(minimumWidth: 340) {
                    if summary.paceIsInformative {
                        RunningTotalCard(summary: summary)
                    }
                    if summary.newVsFamiliarIsInformative {
                        DiscoveryCard(summary: summary)
                    }
                }
            }
            .id("trends")
        }
    }
}

/// How the plays spread across artists and songs.
struct VarietySection: View {
    let summary: StatsSummary

    var body: some View {
        if summary.uniqueSongCount >= 2 {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Variety")
                CardPair {
                    if summary.uniqueArtistCount >= 2 {
                        ArtistMixCard(summary: summary)
                    }
                    VarietyCard(summary: summary)
                }
            }
            .id("variety")
        }
    }
}

/// Bests inside the range.
struct RecordsSection: View {
    let summary: StatsSummary
    var columns = 3

    var body: some View {
        if summary.recordsAreInformative {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Records")
                RecordsGrid(records: summary.records, columns: columns)
            }
            .id("records")
        }
    }
}

#if DEBUG
extension StatsSummary {
    /// A month of the invented demo listening, for previews.
    static func preview(_ range: StatsRange = .month) -> StatsSummary {
        let captures = DemoLibrary.plays().map {
            CaptureStat(
                songKey: $0.title,
                title: $0.title,
                artistName: $0.artistName,
                albumTitle: $0.albumTitle,
                capturedAt: $0.capturedAt,
                stationName: $0.stationName,
                kind: $0.kind
            )
        }
        let history = ListeningHistory(captures, songMetadata: DemoLibrary.songMetadata())
        return StatsCalculator.summary(range: range, history: history, sessions: [], topLimit: 8)
    }
}

#Preview("Deeper sections") {
    let summary = StatsSummary.preview()
    NavigationStack {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                NewFavoritesSection(summary: summary)
                RhythmDetailsRow(summary: summary)
                TrendsSection(summary: summary)
                VarietySection(summary: summary)
                RecordsSection(summary: summary, columns: 2)
            }
            .padding()
        }
        .background { GroupedBackground() }
    }
}

#Preview("Trends") {
    let summary = StatsSummary.preview()
    NavigationStack {
        ScrollView {
            TrendsSection(summary: summary)
                .padding()
        }
        .background { GroupedBackground() }
    }
}

#if os(macOS)
#Preview("Mac dashboard width", traits: .fixedLayout(width: 1100, height: 1900)) {
    let summary = StatsSummary.preview()
    NavigationStack {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                GenresSection(summary: summary)
                RhythmDetailsRow(summary: summary)
                TrendsSection(summary: summary)
                VarietySection(summary: summary)
                RecordsSection(summary: summary, columns: 3)
            }
            .padding(24)
        }
        .groupedBackground()
    }
}
#endif

#Preview("Genres and eras") {
    let summary = StatsSummary.preview()
    NavigationStack {
        ScrollView {
            GenresSection(summary: summary)
                .padding()
        }
        .background { GroupedBackground() }
    }
}

#Preview("Variety and records") {
    let summary = StatsSummary.preview()
    NavigationStack {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                VarietySection(summary: summary)
                RecordsSection(summary: summary, columns: 2)
            }
            .padding()
        }
        .background { GroupedBackground() }
    }
}
#endif
