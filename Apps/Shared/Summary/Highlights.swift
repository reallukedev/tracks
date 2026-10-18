import SwiftUI
import TracksCore

/// One highlight, as a card: coloured heading, symbol, sentence.
struct HighlightCard: View {
    let insight: Insight

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(insight.category.title)
                } icon: {
                    Image(systemName: insight.symbol)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(insight.category.tint)

                HighlightSentence(insight: insight)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The sentence for an insight. Each case is its own literal so plurals inflect properly.
struct HighlightSentence: View {
    let insight: Insight
    private let calendar = Calendar.current

    var body: some View {
        switch insight {
        case .milestone(let count, let date):
            Text("You passed \(count.formatted()) songs on \(Format.shortDate(date)).")
        case .streak(let days):
            Text("You've listened ^[\(days) day](inflect: true) in a row.")
        case .listeningTrend(let percent, let range):
            if percent >= 0 {
                Text("You're listening \(percent)% more than \(Text(range.previousPhrase)).")
            } else {
                Text("You're listening \(abs(percent))% less than \(Text(range.previousPhrase)).")
            }
        case .onRepeat(let title, let artist, let count, _):
            Text("On repeat: you played \(title) by \(artist) ^[\(count) time](inflect: true) in one day.")
        case .topArtistShare(let name, let percent, _):
            Text("\(name) made up \(percent)% of everything you played.")
        case .topGenre(let name, let percent):
            Text("Mostly \(name): \(percent)% of your plays were in that genre.")
        case .favouriteDecade(let decade, let percent):
            Text("\(percent)% of what you played came out in the \(Format.decade(decade)).")
        case .newArtists(let count):
            Text("You discovered ^[\(count) new artist](inflect: true).")
        case .allNew(let count):
            Text("All \(count) songs were new to you.")
        case .mostlyNew(let percent):
            Text("\(percent)% of what you played was new to you.")
        case .persona(.nightOwl, let percent):
            Text("Night owl: \(percent)% of your listening happens after 10 PM.")
        case .persona(.earlyBird, let percent):
            Text("Early bird: \(percent)% of your listening happens before 9 AM.")
        case .busiestHour(let hour, let count):
            Text("You listen most around \(Format.hour(hour)): ^[\(count) song](inflect: true).")
        case .weekendListener(let percent):
            Text("Weekends are for music: \(percent)% of your listening falls on them.")
        case .busiestDay(let weekday, let count):
            Text("\(calendar.weekdaySymbols[weekday - 1]) is your biggest day, with ^[\(count) song](inflect: true).")
        case .dominantStation(let name, let count, let total):
            Text("\(name) played \(count) of your \(total) radio songs.")
        case .repeatedSong(let title, let artist, let count):
            Text("Your most played song is \(title) by \(artist), ^[\(count) time](inflect: true).")
        case .longestSession(let minutes):
            Text("Your longest radio session ran ^[\(minutes) minute](inflect: true).")
        case .playedBack(let count, let total):
            Text("You've played back \(count) of \(total) radio songs, so Apple Music counts them.")
        }
    }
}

/// Every highlight for a range, pushed from "See All".
struct HighlightsList: View {
    let range: StatsRange
    var periodOffset = 0
    @Environment(AppModel.self) private var model
    @State private var insights: [Insight] = []
    @State private var hasLoaded = false
    private var sources = SourceScopeSetting()

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(insights) { insight in
                    HighlightCard(insight: insight)
                }
            }
            .padding()
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if !hasLoaded {
                ProgressView()
            } else if insights.isEmpty {
                ContentUnavailableView("No Highlights", systemImage: "sparkles", description: Text("Play a few more songs and highlights will show up here."))
            }
        }
        .groupedBackground()
        .navigationTitle("Highlights")
        .sourceScopeSubtitle(sources.scope)
        .task(id: "\(sources.scope.rawValue)|\(model.library.revision)") {
            let (range, offset, scope, history, sessions) = (range, periodOffset, sources.scope, model.library.history, model.library.sessions)
            let includesStations = scope.includesStations
            let next = await OffMainActor.run {
                StatsCalculator.summary(
                    range: range,
                    history: history.scoped(to: scope),
                    sessions: includesStations ? sessions : [],
                    periodOffset: offset
                ).insights
            }
            guard !Task.isCancelled else { return }
            insights = next
            hasLoaded = model.library.isLoaded
        }
    }
}
