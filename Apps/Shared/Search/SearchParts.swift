import SwiftUI
import TracksCore

/// Recent searches as chips to search again, with Clear.
struct RecentSearchesSection: View {
    let recents: [String]
    let clear: () -> Void
    let search: (String) -> Void
    var remove: ((String) -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Clear goes under the title at the largest sizes, so the title keeps whole words.
        let header = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        VStack(alignment: .leading, spacing: 10) {
            header {
                SearchSectionTitle("Recently Searched")
                Spacer(minLength: 0)
                Button("Clear") { withAnimation(.snappy) { clear() } }
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(.tint)
            }
            .padding(.horizontal, PlayMetrics.margin)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(recents, id: \.self) { recent in
                        SearchChip(title: recent, systemImage: "clock.arrow.circlepath") {
                            search(recent)
                        }
                        .contextMenu {
                            if let remove {
                                Button("Remove from Recent Searches", systemImage: "minus.circle") {
                                    withAnimation(.snappy) { remove(recent) }
                                }
                            }
                        }
                    }
                }
            }
            .contentMargins(.horizontal, PlayMetrics.margin, for: .scrollContent)
            .scrollIndicators(.hidden)
        }
    }
}

/// A search to run again or try, as a chip.
struct SearchChip: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .frame(minHeight: 34)
                .background(.quaternary, in: .capsule)
                // A full-height target around the chip.
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.pressable)
    }
}

/// The moods and genres, as tiles to open, for before a search: Music's Browse Categories,
/// made of the rooms Play already has.
struct BrowseSections: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayFeed.self) private var feed
    /// Nil until they're worked out, which walks the history.
    @State private var genres: [GenreTileItem]?

    var body: some View {
        VStack(alignment: .leading, spacing: PlayMetrics.sectionSpacing) {
            section("Browse by Mood") {
                ForEach(Mood.allCases) { mood in
                    MoodTile(mood: mood, height: Self.tileHeight, fillsWidth: true)
                }
            }
            if let genres {
                if !genres.isEmpty {
                    section("Browse by Genre") {
                        ForEach(genres) { item in
                            GenreTile(item: item, height: Self.tileHeight, fillsWidth: true)
                        }
                    }
                }
            } else {
                // The genres' place, held while they're worked out.
                section("Browse by Genre") {
                    ForEach(0..<(model.musicSource == .appleMusic ? MusicGenre.all.count : 4), id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.quaternary)
                            .frame(height: Self.tileHeight)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .task(id: GenresKey(source: model.musicSource, revision: model.library.revision, songs: model.yourMusic.index.tracks.count)) {
            guard model.library.isLoaded else { return }
            genres = await GenreShelfItems.load(model: model, facts: feed.facts)
        }
    }

    private func section(_ title: LocalizedStringKey, @ViewBuilder tiles: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SearchSectionTitle(title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tileWidth), spacing: 12)], spacing: 12) {
                tiles()
            }
        }
        .padding(.horizontal, PlayMetrics.margin)
    }

    #if os(macOS)
    private static let tileWidth: CGFloat = 170
    #else
    private static let tileWidth: CGFloat = 150
    #endif
    private static let tileHeight: CGFloat = 84
}

private struct GenresKey: Equatable {
    let source: MusicSource
    let revision: Int
    let songs: Int
}

/// A search section's title.
struct SearchSectionTitle: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.title3.bold())
            .accessibilityAddTraits(.isHeader)
    }
}

/// The top result and the songs: side by side on the Mac, as Music lays them out, or one above
/// the other where the window's too narrow for both, and always on iPhone.
struct SearchLead<SongsTitle: View, Songs: View>: View {
    let top: SearchTopResult?
    var topTitle: LocalizedStringKey = "Top Result"
    let hasSongs: Bool
    @ViewBuilder var songsTitle: SongsTitle
    @ViewBuilder var songs: Songs

    var body: some View {
        Group {
            #if os(macOS)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 28) {
                    if top != nil {
                        topBlock
                            .frame(width: Self.cardWidth)
                    }
                    if hasSongs {
                        songsBlock
                            .frame(minWidth: 420, maxWidth: .infinity, alignment: .leading)
                    }
                }
                stacked
            }
            #else
            stacked
            #endif
        }
        .padding(.horizontal, PlayMetrics.margin)
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: PlayMetrics.sectionSpacing) {
            topBlock
                #if os(macOS)
                .frame(maxWidth: Self.cardWidth)
                #endif
            if hasSongs { songsBlock }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var topBlock: some View {
        if let top {
            VStack(alignment: .leading, spacing: 10) {
                SearchSectionTitle(topTitle)
                TopResultCard(result: top)
            }
        }
    }

    private var songsBlock: some View {
        VStack(alignment: .leading, spacing: Self.titleSpacing) {
            songsTitle
            songs
        }
    }

    private static var cardWidth: CGFloat { 340 }
    #if os(macOS)
    private static var titleSpacing: CGFloat { 10 }
    #else
    private static var titleSpacing: CGFloat { 6 }
    #endif
}

/// Search's songs, in rows: one column on iPhone; on the Mac, as many as fit, as Music lays
/// them out.
struct SearchSongGrid<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder var row: (Item) -> Row

    var body: some View {
        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                row(item)
            }
        }
    }

    #if os(macOS)
    private static var columns: [GridItem] { [GridItem(.adaptive(minimum: 260), spacing: 28)] }
    #else
    private static var columns: [GridItem] { [GridItem(.flexible())] }
    #endif
}

/// The best match for a search, whatever it's from: what it's called, what it is, its
/// picture, and what opening and playing it do.
struct SearchTopResult {
    let title: String
    /// "Artist", "Album · Mara Solis", "Song · Mara Solis".
    let kind: String
    let cover: CoverArt?
    /// For an artist: a round picture, or their initials without one.
    var isArtist = false
    let open: () -> Void
    /// Nil when nothing of it can play right now.
    let play: (() -> Void)?
}

/// The best match, large: its picture, what it is, and Play, as Music's Top Result is.
struct TopResultCard: View {
    let result: SearchTopResult
    @State private var tint: Color?

    var body: some View {
        Button(action: result.open) {
            VStack(alignment: .leading, spacing: 14) {
                picture
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(result.kind)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                // Clear of Play in the corner, however large the text.
                .padding(.trailing, 60)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 64)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
            .background {
                CoverStage(tint: tint, deepens: true)
                    .clipShape(.rect(cornerRadius: 18, style: .continuous))
            }
            .overlay(alignment: .bottomTrailing) {
                if let play = result.play {
                Button(action: play) {
                    Image(systemName: "play.fill")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(width: 48, height: 48)
                        .background(.white, in: .circle)
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                }
                .buttonStyle(.pressable)
                // A fixed circle, so its symbol can't outgrow it at the largest text sizes.
                .dynamicTypeSize(.large)
                .padding(16)
                // Reached as the card's Play action with VoiceOver.
                .accessibilityHidden(true)
                }
            }
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.pressable)
        .coverTint(of: result.cover ?? .url(nil, seed: result.title), into: $tint)
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if let play = result.play {
                Button("Play", action: play)
            }
        }
    }

    @ViewBuilder
    private var picture: some View {
        if result.isArtist {
            ArtistPicture(cover: result.cover, name: result.title, size: 112, onStage: true)
        } else {
            CoverImage(cover: result.cover ?? .url(nil, seed: result.title), size: 112)
        }
    }
}

/// No results, with the other places the same search could look, a click away.
struct SearchNoResults: View {
    let query: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let session = model.search
        let others = SearchScope.scopes(for: model.musicSource).filter { $0 != session.scope }
        ContentUnavailableView {
            Label("No Results", systemImage: "magnifyingglass")
        } description: {
            Text("Nothing in \(Text(session.scope.title(for: model.musicSource))) matches “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”.")
        } actions: {
            ForEach(others) { scope in
                Button {
                    session.scope = scope
                } label: {
                    Text("Search \(Text(scope.title(for: model.musicSource)))")
                }
            }
        }
    }
}
