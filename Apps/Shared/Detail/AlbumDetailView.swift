import SwiftUI
import TracksCore

/// One album's listening: how often you played it, which of its songs, and when.
///
/// Laid out like the artist and song pages, so the three read as one family.
struct AlbumDetailView: View {
    let albumID: String
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback
    @Environment(\.playSongs) private var playSongs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var profile: AlbumProfile?
    /// The id whose profile was last worked out from a loaded library, so "No Plays" waits
    /// for the answer instead of showing while the first one is still on its way.
    @State private var loadedID: String?
    @State private var showsAllSongs = false

    var body: some View {
        ScrollView {
            if let profile {
                content(profile)
                    .padding()
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
            } else if loadedID == albumID {
                ContentUnavailableView("No Plays", systemImage: "square.stack")
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 120)
            }
        }
        .groupedBackground()
        .navigationTitle(profile?.album.title ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: "\(albumID)|\(model.library.revision)") {
            let (id, history, isLoaded) = (albumID, model.library.history, model.library.isLoaded)
            let next = await OffMainActor.run { StatsCalculator.albumProfile(id: id, history: history) }
            guard !Task.isCancelled else { return }
            // A lookup that changed nothing on this page doesn't redraw it.
            if next != profile {
                LiveUpdate.apply(isLive: profile?.album.id == albumID, reduceMotion: reduceMotion) {
                    profile = next
                }
            }
            if isLoaded { loadedID = id }
        }
    }

    private func content(_ profile: AlbumProfile) -> some View {
        let album = profile.album
        return VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            VStack(spacing: 14) {
                ArtworkView(url: album.artworkURL, seed: album.title, size: 200)
                    .shadow(color: .black.opacity(0.18), radius: 20, y: 10)
                VStack(spacing: 4) {
                    Text(album.title)
                        .font(.title.bold())
                        .multilineTextAlignment(.center)
                    NavigationLink(value: Route.artist(profile.artistID)) {
                        Text(album.artistName)
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    // "Alternative · 1994", as under a title in Apple Music.
                    if let details = releaseDetails(profile) {
                        Text(verbatim: details)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                    }
                    Text("#\(profile.allTimeRank) of your albums · \(profile.share.formatted(.percent.precision(.fractionLength(0)))) of your listening")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                playButton(for: profile)
            }
            .frame(maxWidth: .infinity)

            StatStrip(items: [
                .init(title: "Plays", value: album.count.formatted()),
                .init(title: "Listening", value: Format.listening(album.listeningSeconds)),
                .init(title: "Songs", value: album.songCount.formatted()),
                .init(title: "First Heard", value: Format.shortDate(profile.firstHeard)),
            ])

            if profile.timeline.count(where: { $0.count > 0 }) > 1 {
                PlaysOverTimeCard(timeline: profile.timeline, unit: profile.timelineUnit)
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Songs") {
                    if profile.songs.count > 5 {
                        Button(showsAllSongs ? "Show Less" : "Show All") {
                            withAnimation { showsAllSongs.toggle() }
                        }
                    }
                }
                TopSongsCard(songs: profile.songs, limit: showsAllSongs ? profile.songs.count : 5)
            }
        }
    }

    /// "Alternative · 1994": the genre its songs are played in, and when it came out.
    private func releaseDetails(_ profile: AlbumProfile) -> String? {
        let parts = [profile.genre, profile.releaseYear.map(Format.year)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Plays the album's songs in the order you play them most. Hidden when none of them
    /// were ever identified in the catalog, since there'd be nothing to hand the player.
    @ViewBuilder
    private func playButton(for profile: AlbumProfile) -> some View {
        let playable = profile.songs.filter { !$0.songID.isEmpty }
        if !playable.isEmpty, !model.isShowingSampleData {
            Button("Play", systemImage: "play.fill") {
                let items = playable.map {
                    PlaybackItem(songID: $0.songID, title: $0.title, artistName: $0.artistName)
                }
                if let playSongs {
                    playSongs(items, title: profile.album.title)
                } else {
                    Task { await playback.play(items) }
                }
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
    }
}
