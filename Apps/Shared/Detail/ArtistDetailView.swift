import SwiftUI
import TracksCore

struct ArtistDetailView: View {
    let artistID: String
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var profile: ArtistProfile?
    /// The id whose profile was last worked out from a loaded library, so "No Plays" waits
    /// for the answer instead of showing while the first one is still on its way.
    @State private var loadedID: String?
    @State private var showsAllSongs = false
    @State private var showsAllFeatures = false

    var body: some View {
        ScrollView {
            if let profile {
                content(profile)
                    .padding()
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
            } else if loadedID == artistID {
                ContentUnavailableView("No Plays", systemImage: "music.microphone")
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 120)
            }
        }
        .groupedBackground()
        .navigationTitle(profile?.artist.name ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: "\(artistID)|\(model.library.revision)") {
            let (id, history, isLoaded) = (artistID, model.library.history, model.library.isLoaded)
            let next = await OffMainActor.run { StatsCalculator.artistProfile(id: id, history: history) }
            guard !Task.isCancelled else { return }
            // A lookup that changed nothing on this page doesn't redraw it.
            if next != profile {
                LiveUpdate.apply(isLive: profile?.artist.id == artistID, reduceMotion: reduceMotion) {
                    profile = next
                }
            }
            if isLoaded { loadedID = id }
        }
    }

    private func content(_ profile: ArtistProfile) -> some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            VStack(spacing: 12) {
                ArtworkView(url: profile.artist.artworkURL, seed: profile.artist.name, size: 150, isCircle: true)
                    .shadow(color: .black.opacity(0.15), radius: 16, y: 8)
                Text(profile.artist.name)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                if let details = genreDetails(profile) {
                    Text(verbatim: details)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
                Text("#\(profile.allTimeRank) of all time · \(profile.share.formatted(.percent.precision(.fractionLength(0)))) of your listening")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            StatStrip(items: [
                .init(title: "Plays", value: profile.artist.count.formatted()),
                .init(title: "Listening", value: Format.listening(profile.artist.listeningSeconds)),
                .init(title: "Songs", value: profile.artist.songCount.formatted()),
                .init(title: "First Heard", value: Format.shortDate(profile.artist.firstHeard)),
            ])

            if profile.timeline.count(where: { $0.count > 0 }) > 1 {
                PlaysOverTimeCard(timeline: profile.timeline, unit: profile.timelineUnit)
            }

            if !profile.songs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Top Songs") {
                        if profile.songs.count > 5 {
                            Button(showsAllSongs ? "Show Less" : "Show All") {
                                withAnimation { showsAllSongs.toggle() }
                            }
                        }
                    }
                    TopSongsCard(songs: profile.songs, limit: showsAllSongs ? profile.songs.count : 5)
                }
            }

            // Their own songs first, then the ones they guest on, as Music's "Appears On".
            if !profile.features.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Featured On") {
                        if profile.features.count > 5 {
                            Button(showsAllFeatures ? "Show Less" : "Show All") {
                                withAnimation { showsAllFeatures.toggle() }
                            }
                        }
                    }
                    TopSongsCard(songs: profile.features, limit: showsAllFeatures ? profile.features.count : 5)
                }
            }

            if !profile.collaborators.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader("Collaborators")
                    TopArtistsShelf(artists: profile.collaborators, artworkSize: 80, countsSongs: true)
                }
            }

            if !profile.albums.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader("Albums")
                    AlbumGrid(albums: profile.albums)
                }
            }

            if profile.artist.count >= 10 {
                Card { ListeningClockCard(hourly: profile.hourly) }
            }
        }
    }

    /// "Alternative · 1971–1994": their main genre, and when the songs you played came out.
    private func genreDetails(_ profile: ArtistProfile) -> String? {
        let parts = [profile.genre, profile.releaseYears.map(Format.years)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A row of labelled numbers under a detail header.
struct StatStrip: View {
    struct Item: Identifiable {
        let title: LocalizedStringKey
        let value: String
        var id: String { value + "\(title)" }
    }

    let items: [Item]
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(items.enumerated(), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(item.value)
                                .font(.headline)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        } else {
            strip
        }
    }

    private var strip: some View {
        Card(padding: 14) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(items.enumerated(), id: \.offset) { index, item in
                    if index > 0 {
                        Divider().frame(maxHeight: 36)
                    }
                    VStack(spacing: 3) {
                        Text(item.value)
                            .font(.system(.headline, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(item.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// Albums as a wrapping grid of covers.
struct AlbumGrid: View {
    let albums: [AlbumTally]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 180), spacing: 14, alignment: .top)], spacing: 16) {
            ForEach(albums) { album in
                NavigationLink(value: Route.album(album.id)) {
                    VStack(alignment: .leading, spacing: 6) {
                        // Sized by the column: the cover fills the square the grid offers.
                        ArtworkView(url: album.artworkURL, seed: album.title, size: nil)
                            .aspectRatio(1, contentMode: .fit)
                        Text(album.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text("^[\(album.count) play](inflect: true)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
