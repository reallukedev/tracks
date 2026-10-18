import SwiftUI
import TracksCore

struct SongDetailView: View {
    let songID: String
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback
    @Environment(\.playSongs) private var playSongs
    @Environment(\.openURL) private var openURL
    @Environment(\.openPlayRoute) private var openPlayRoute
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var profile: SongProfile?
    /// The id whose profile was last worked out from a loaded library, so "No Plays" waits
    /// for the answer instead of showing while the first one is still on its way.
    @State private var loadedID: String?
    @State private var showsAllPlays = false

    var body: some View {
        ScrollView {
            if let profile {
                content(profile)
                    .padding()
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
            } else if loadedID == songID {
                ContentUnavailableView("No Plays", systemImage: "music.note")
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 120)
            }
        }
        .groupedBackground()
        .navigationTitle(profile?.song.title ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: "\(songID)|\(model.library.revision)") {
            let (id, history, isLoaded) = (songID, model.library.history, model.library.isLoaded)
            let next = await OffMainActor.run { StatsCalculator.songProfile(id: id, history: history) }
            guard !Task.isCancelled else { return }
            // A lookup that changed nothing on this page doesn't redraw it.
            if next != profile {
                LiveUpdate.apply(isLive: profile?.song.id == songID, reduceMotion: reduceMotion) {
                    profile = next
                }
            }
            if isLoaded { loadedID = id }
        }
    }

    private func content(_ profile: SongProfile) -> some View {
        let song = profile.song
        return VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            VStack(spacing: 14) {
                ArtworkView(url: song.artworkURL, seed: song.albumTitle ?? song.title, size: 200)
                    .shadow(color: .black.opacity(0.18), radius: 20, y: 10)
                VStack(spacing: 4) {
                    // Each artist links where they're named: a feature only the title names
                    // is linked there, so no one is written twice.
                    CreditedText(text: song.title, credits: titleOnlyCredits(song))
                        .font(.title.bold())
                        .multilineTextAlignment(.center)
                    if openPlayRoute.canPush {
                        CreditedText(text: song.artistName, credits: song.credits)
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .multilineTextAlignment(.center)
                    } else {
                        NavigationLink(value: Route.artist(profile.artistID)) {
                            Text(song.artistName)
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                    }
                    if let album = song.albumTitle {
                        Text(album)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    // "Hip-Hop/Rap · 2019", as under a title in Apple Music.
                    if let details = releaseDetails(profile.metadata) {
                        Text(verbatim: details)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                    }
                }
                actions(for: song)
            }
            .frame(maxWidth: .infinity)

            StatStrip(items: [
                .init(title: "Plays", value: song.count.formatted()),
                .init(title: "All-Time Rank", value: "#\(profile.allTimeRank)"),
                .init(title: "First Heard", value: Format.shortDate(song.firstHeard)),
                .init(title: "Last Heard", value: Format.shortDate(song.lastHeard)),
            ])

            if profile.timeline.count(where: { $0.count > 0 }) > 1 {
                PlaysOverTimeCard(timeline: profile.timeline, unit: profile.timelineUnit)
            }

            if profile.sources.count > 1 || !profile.stations.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        CardLabel(title: "How You Heard It", systemImage: "headphones", tint: .accentColor)
                        if profile.sources.count > 1 {
                            SourcesDonut(sources: profile.sources)
                        }
                        ForEach(profile.stations) { station in
                            Label {
                                HStack {
                                    Text(station.name)
                                    Spacer()
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

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Plays") {
                    if profile.plays.count > 8 {
                        Button(showsAllPlays ? "Show Less" : "Show All") {
                            withAnimation { showsAllPlays.toggle() }
                        }
                    }
                }
                Card(padding: 0) {
                    // Lazy: a favourite can have thousands of plays once they're all shown.
                    LazyVStack(spacing: 0) {
                        let plays = showsAllPlays ? profile.plays : Array(profile.plays.prefix(8))
                        ForEach(plays.enumerated(), id: \.offset) { index, date in
                            HStack {
                                Text(Format.day(date))
                                Spacer()
                                Text(date, format: .dateTime.hour().minute())
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .font(.subheadline)
                            .padding(.horizontal, Metrics.cardPadding)
                            .padding(.vertical, 11)
                            if index < plays.count - 1 {
                                Divider().padding(.leading, Metrics.cardPadding)
                            }
                        }
                    }
                }
            }
        }
    }

    /// The artists the title names that the artist line doesn't, like "Song (feat. B)" by A.
    private func titleOnlyCredits(_ song: SongTally) -> [ArtistCredit] {
        let named = Set(CreditedText.links(in: song.artistName, credits: song.credits).map(\.credit.identity))
        return song.credits.filter { !named.contains($0.identity) }
    }

    private func releaseDetails(_ metadata: SongMetadata?) -> String? {
        let parts = [metadata?.genre, metadata?.releaseYear.map(Format.year)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func actions(for song: SongTally) -> some View {
        if !song.songID.isEmpty, !model.isShowingSampleData {
            HStack(spacing: 12) {
                Button("Play", systemImage: "play.fill") {
                    let item = PlaybackItem(songID: song.songID, title: song.title, artistName: song.artistName)
                    if let playSongs {
                        playSongs([item], title: song.title)
                    } else {
                        Task { await playback.play(item) }
                    }
                }
                .buttonStyle(.glassProminent)
                Button("Show in Music", systemImage: "arrow.up.forward.app") {
                    if let url = URL(string: "https://music.apple.com/song/\(song.songID)") {
                        openURL(url)
                    }
                }
                .buttonStyle(.glass)
            }
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
    }
}
