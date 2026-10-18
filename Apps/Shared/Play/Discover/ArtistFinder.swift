import SwiftUI
import MusicKit
import TracksCore

/// Finding artists you've never played, as For You introduces them: the best match first,
/// in the spotlight with their best songs ready to play, then shelves of the rest, each under
/// the artist of yours that led to them. The further down, the further out, for as long as
/// you scroll. Narrowed by genre: capsules on iPhone, a pop-up in the Mac's toolbar.
struct ArtistFinder: View {
    @Environment(Discovery.self) private var discovery
    @Environment(PlayerModel.self) private var player
    @Environment(AppModel.self) private var model
    @State private var genre: String?
    /// Whether the end of the page is on screen: only then does it walk further out.
    @State private var isEndInView = false

    var body: some View {
        let artists = artists
        let phase = phase(artists)
        ScrollView {
            VStack(alignment: .leading, spacing: PlayMetrics.sectionSpacing) {
                switch phase {
                case .artists:
                    header
                    ArtistFeed(artists: artists)
                    if discovery.canExpand {
                        if discovery.isExpanding {
                            placeholders
                                .transition(.opacity)
                        } else if discovery.expandFailed {
                            LoadMoreFailedRow(text: "Couldn't load more artists.") {
                                Task { await discovery.expand() }
                            }
                            .padding(.horizontal, PlayMetrics.margin)
                        }
                        Color.clear
                            .frame(height: 1)
                            .onScrollVisibilityChange(threshold: 0.01) { isEndInView = $0 }
                            .onDisappear { isEndInView = false }
                    }
                case .loading:
                    placeholders
                case .empty, .noAccess, .failed:
                    state(phase)
                        .frame(maxWidth: 560, alignment: .leading)
                        .padding(.horizontal, PlayMetrics.margin)
                }
            }
            .padding(.top, Self.topPadding)
            .padding(.bottom, 28)
            .animation(PlayMotion.row, value: artists.map(\.id))
        }
        .animation(PlayMotion.row, value: genre)
        .navigationTitle("Find Artists")
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        .safeAreaBar(edge: .top) {
            if phase == .artists || genre != nil {
                GenreFilter(genres: genres, selection: $genre)
            }
        }
        #else
        .toolbar {
            if phase == .artists || genre != nil {
                ToolbarItem(placement: .primaryAction) {
                    Picker("Genre", selection: $genre) {
                        Text("All Genres").tag(String?.none)
                        Divider()
                        ForEach(genres, id: \.self) { genre in
                            Text(genre).tag(Optional(genre))
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .help("Show Artists of One Genre")
                }
            }
        }
        #endif
        // Again after each step out, even one that found no one new, while the end is in
        // view. A step that couldn't reach Apple Music doesn't count, so it doesn't loop.
        .task(id: "\(isEndInView).\(discovery.expansions).\(genre ?? "")") {
            guard isEndInView, discovery.hasSeeded, discovery.canExpand else { return }
            await discovery.expand()
        }
    }

    // MARK: - Feed

    /// The feed's masthead, as the Today tab dates its stories.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.subheadline.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text("Artists to Meet")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, PlayMetrics.margin)
    }

    /// Cards in the shape of the feed while more are found.
    private var placeholders: some View {
        HStack(spacing: 24) {
            ForEach(0..<2, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.placeholderFill)
                    .frame(height: ArtistFeed.cardHeight)
            }
        }
        .padding(.horizontal, PlayMetrics.margin)
        .accessibilityElement()
        .accessibilityLabel(Text("Loading"))
    }

    #if os(macOS)
    private static let topPadding: CGFloat = 20
    #else
    private static let topPadding: CGFloat = 12
    #endif

    // MARK: - States

    enum Phase: Equatable {
        case noAccess, loading, empty, artists
        /// Apple Music couldn't be reached for the first artists.
        case failed
    }

    private func phase(_ artists: [SuggestedArtist]) -> Phase {
        #if DEBUG
        if let state = FinderDebugState.current {
            switch state {
            case .noAccess: return .noAccess
            case .loading: return .loading
            case .empty: return .empty
            case .long: break
            }
        }
        #endif
        if !player.isDemo, model.musicAuthorization != .authorized { return .noAccess }
        if !artists.isEmpty { return .artists }
        if discovery.expandFailed, !discovery.isExpanding { return .failed }
        if !discovery.hasSeeded || discovery.canExpand { return .loading }
        return .empty
    }

    @ViewBuilder
    private func state(_ phase: Phase) -> some View {
        if phase == .noAccess {
            PlayAccessCard()
        } else if phase == .failed {
            PlayStateCard(
                symbol: "wifi.exclamationmark",
                title: String(localized: "Couldn't Reach Apple Music"),
                message: String(localized: "Check your connection, then try again.")
            ) {
                Button("Try Again") { Task { await discovery.expand() } }
                    .buttonStyle(.glassProminent)
            }
        } else {
            PlayStateCard(
                symbol: "person.crop.circle.badge.plus",
                title: String(localized: "Nothing New Here Yet"),
                message: String(localized: "Suggestions come from the artists you play most. Play a few more, and they'll start. Until then, see what everyone's playing.")
            ) {
                NavigationLink("Find Popular Songs", value: PlayRoute.songFinder(.popular))
                    .buttonStyle(.glassProminent)
            }
        }
    }

    // MARK: - Artists

    private var artists: [SuggestedArtist] {
        var artists = discovery.artists.filter { genre == nil || $0.genre == genre }
        #if DEBUG
        if FinderDebugState.current == .long, let long = FinderDebugState.longArtist { artists.insert(long, at: 0) }
        #endif
        return artists
    }

    /// The genres among the suggestions, the most common first.
    private var genres: [String] {
        var counts: [String: Int] = [:]
        for artist in discovery.artists {
            if let genre = artist.genre { counts[genre, default: 0] += 1 }
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(10).map(\.key)
    }
}

#if os(iOS)
/// All, then each genre, as capsules to scroll through.
private struct GenreFilter: View {
    let genres: [String]
    @Binding var selection: String?
    /// Counts choices made here, so the tap is felt.
    @State private var chosen = 0

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip(String(localized: "All"), isSelected: selection == nil) { selection = nil }
                ForEach(genres, id: \.self) { genre in
                    chip(genre, isSelected: selection == genre) { selection = genre }
                }
            }
            .padding(.vertical, 8)
        }
        .contentMargins(.horizontal, PlayMetrics.margin, for: .scrollContent)
        .scrollIndicators(.hidden)
        .sensoryFeedback(.selection, trigger: chosen)
    }

    private func chip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            guard !isSelected else { return }
            chosen += 1
            action()
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.secondarySystemFill)), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif
