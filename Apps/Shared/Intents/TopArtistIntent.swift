import AppIntents
import SwiftUI
import TracksCore

/// "Who's my top artist this week in Tracks": the answer, said and shown, from the history on
/// this device. Returns the artist, so a shortcut can open them or play them next.
struct TopArtistIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Top Artist"
    static let description = IntentDescription(
        "Finds the artist you've listened to most this week, this month, this year or of all time.",
        categoryName: "Your History",
        searchKeywords: ["most played", "favorite", "stats", "listening"]
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Period", default: .week)
    var period: ListeningPeriod

    static var parameterSummary: some ParameterSummary {
        Summary("Get top artist \(\.$period)")
    }

    init() {}

    init(period: ListeningPeriod) {
        self.period = period
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ListenedArtistEntity> & ProvidesDialog & ShowsSnippetView {
        guard let history = await HistoryCatalog.history() else {
            throw TopArtistProblem.unreadable
        }
        let range = period.range
        let summary = await OffMainActor.run {
            StatsCalculator.summary(range: range, history: history, sessions: [], topLimit: 3, songLimit: 1)
        }
        guard let top = summary.topArtists.first else {
            throw TopArtistProblem.nothingPlayed(period)
        }
        let dialog: IntentDialog = switch period {
        case .week: "\(top.name), with ^[\(top.count) play](inflect: true) this week."
        case .month: "\(top.name), with ^[\(top.count) play](inflect: true) this month."
        case .year: "\(top.name), with ^[\(top.count) play](inflect: true) this year."
        case .allTime: "\(top.name), with ^[\(top.count) play](inflect: true) in all."
        }
        return .result(
            value: ListenedArtistEntity(top),
            dialog: dialog,
            view: TopArtistsSnippet(artists: summary.topArtists)
        )
    }
}

enum ListeningPeriod: String, AppEnum {
    case week, month, year, allTime

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Period"
    static let caseDisplayRepresentations: [ListeningPeriod: DisplayRepresentation] = [
        .week: "This Week",
        .month: "This Month",
        .year: "This Year",
        .allTime: "All Time",
    ]

    var range: StatsRange {
        switch self {
        case .week: .week
        case .month: .month
        case .year: .year
        case .allTime: .allTime
        }
    }
}

private enum TopArtistProblem: Error, CustomLocalizedStringResourceConvertible {
    case unreadable
    case nothingPlayed(ListeningPeriod)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .unreadable: "Tracks couldn't open your history. Open Tracks, then ask again."
        case .nothingPlayed(.week): "You haven't listened to anything this week."
        case .nothingPlayed(.month): "You haven't listened to anything this month."
        case .nothingPlayed(.year): "You haven't listened to anything this year."
        case .nothingPlayed(.allTime): "There's nothing in your history yet."
        }
    }
}

/// The top three, as Siri and Shortcuts show the answer: the first large, the others below.
struct TopArtistsSnippet: View {
    let artists: [ArtistTally]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(artists.prefix(3).enumerated()), id: \.element.id) { rank, artist in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(rank + 1, format: .number)
                        .font(rank == 0 ? .title3.weight(.bold) : .body.weight(.semibold))
                        .foregroundStyle(rank == 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .monospacedDigit()
                        .frame(minWidth: 18, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(artist.name)
                            .font(rank == 0 ? .title3.weight(.semibold) : .body)
                            .lineLimit(1)
                        Text("^[\(artist.count) play](inflect: true) · \(Format.listening(artist.listeningSeconds))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding()
    }
}

#Preview("Top artists") {
    TopArtistsSnippet(
        artists: [
            ArtistTally(id: "mara solis", name: "Mara Solís", count: 42, songCount: 9, listeningSeconds: 9_360, artworkURL: nil, firstHeard: .now, lastHeard: .now),
            ArtistTally(id: "the lanterns", name: "The Lanterns", count: 31, songCount: 6, listeningSeconds: 6_900, artworkURL: nil, firstHeard: .now, lastHeard: .now),
            ArtistTally(id: "june atlas", name: "June Atlas", count: 17, songCount: 4, listeningSeconds: 3_840, artworkURL: nil, firstHeard: .now, lastHeard: .now),
        ]
    )
    .tint(.accentColor)
}
