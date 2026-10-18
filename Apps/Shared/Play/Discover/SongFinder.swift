import SwiftUI
import MusicKit
import TracksCore

/// Finding songs you've never played, through one lens at a time: everything suggested, your
/// own artists' songs, artists like them, new releases, what's popular, or a mood. The lens is
/// the page's subject, with a header that says what it shows and plays all of it. On iPhone the
/// lenses are capsules over a list whose rows play at a tap and swipe to keep or dismiss; on the
/// Mac they're a list beside a table of the songs. Not Interested can be undone.
struct SongFinder: View {
    @Environment(Discovery.self) private var discovery
    @Environment(PlayFeed.self) private var feed
    @Environment(PlayerModel.self) private var player
    @Environment(AppModel.self) private var model
    @Environment(YourMusic.self) private var music
    @Environment(\.undoManager) private var undoManager
    @AppStorage(SuggestionMode.storageKey) private var mode = SuggestionMode.everything
    @State private var lens: SongLens
    /// Songs for the lenses Discovery doesn't keep, by lens, once loaded.
    @State private var loaded: [String: [Suggestion]] = [:]
    /// Songs brought back by Undo after Not Interested, by lens, with where they were.
    @State private var returned: [String: [Returned]] = [:]

    init(lens: SongLens) {
        _lens = State(initialValue: lens)
    }

    var body: some View {
        let all = songs(for: lens)
        let songs = all.visible(in: music, source: model.musicSource, mode: mode)
        let unanswered = all.unanswered(in: music, source: model.musicSource)
        let phase = phase(songs: songs, unanswered: unanswered)
        page(songs: songs, phase: phase, isFindingMore: !songs.isEmpty && (unanswered > 0 || (expands(lens) && discovery.isExpanding)))
            .navigationTitle("Find Songs")
            .task(id: lens) { await load(lens) }
            .task(id: "\(lens.id).\(all.count).\(music.availabilityGeneration).\(mode.rawValue).\(unanswered)") {
                await all.lookUp(in: music, source: model.musicSource, mode: mode, first: 16)
            }
    }

    // MARK: - Pages

    /// What the page can show of the lens right now.
    enum Phase: Equatable {
        /// Apple Music is where suggestions come from, and Tracks can't reach it yet.
        case noAccess
        case loading
        case empty
        case songs
    }

    private func phase(songs: [Suggestion], unanswered: Int) -> Phase {
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
        if !songs.isEmpty { return .songs }
        let isWalking = expands(lens) && discovery.canExpand && !discovery.expandFailed
        if isLoading(lens) || unanswered > 0 || isWalking { return .loading }
        return .empty
    }

    /// The lenses as chips over the lens's pile of songs, one on top at a time.
    private func page(songs: [Suggestion], phase: Phase, isFindingMore: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lens.title)
                        .font(.largeTitle.bold())
                        .contentTransition(.opacity)
                    Text(lens.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
                .padding(.horizontal, PlayMetrics.margin)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                LensChips(selection: $lens)

                switch phase {
                case .songs:
                    SongDeck(
                        suggestions: songs,
                        lens: lens,
                        play: { play(songs, from: $0) },
                        dismiss: dismiss,
                        onNearEnd: {
                            guard expands(lens), discovery.canExpand, !discovery.isExpanding else { return }
                            Task { await discovery.expand() }
                        }
                    )
                case .loading:
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color.placeholderFill)
                        .frame(height: 380)
                        .padding(.horizontal, PlayMetrics.margin)
                        .accessibilityLabel(Text("Loading"))
                case .empty, .noAccess:
                    state(phase)
                        .frame(maxWidth: 560, alignment: .leading)
                        .padding(.horizontal, PlayMetrics.margin)
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 28)
            .animation(PlayMotion.panel, value: lens)
        }
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
    }

    /// No access, or nothing new, in place of the songs, with the next thing to do.
    @ViewBuilder
    private func state(_ phase: Phase) -> some View {
        if phase == .noAccess {
            PlayAccessCard()
        } else {
            PlayStateCard(
                symbol: isOffline ? "wifi.exclamationmark" : lens.symbol,
                title: isOffline ? String(localized: "Couldn't Reach Apple Music") : String(localized: "Nothing New Here Yet"),
                message: emptyMessage
            ) {
                emptyAction
            }
        }
    }

    /// The way on from an empty lens: another lens that needs less, or another try.
    @ViewBuilder
    private var emptyAction: some View {
        switch lens {
        case .forYou where isOffline, .likeYourArtists where isOffline:
            Button("Try Again") { Task { await discovery.expand() } }
                .buttonStyle(.glassProminent)
        case .forYou, .yourArtists, .likeYourArtists:
            Button("Try Popular") { lens = .popular }
                .buttonStyle(.glassProminent)
        case .newReleases:
            // Nothing may have come back because Apple Music couldn't be reached.
            ViewThatFits {
                HStack(spacing: 10) { newReleasesActions }
                VStack(alignment: .leading, spacing: 10) { newReleasesActions }
            }
        case .popular, .mood:
            tryAgain.buttonStyle(.glassProminent)
        }
    }

    @ViewBuilder
    private var newReleasesActions: some View {
        Button("Try Your Artists") { lens = .yourArtists }
            .buttonStyle(.glassProminent)
        tryAgain.buttonStyle(.glass)
    }

    private var tryAgain: some View {
        Button("Try Again") {
            loaded[lens.id] = nil
            Task { await load(lens) }
        }
    }

    // MARK: - Songs by lens

    private func songs(for lens: SongLens) -> [Suggestion] {
        var songs: [Suggestion] = switch lens {
        case .forYou: discovery.songs
        case .yourArtists: discovery.fromYourArtists
        case .likeYourArtists: discovery.songs.filter { if case .like = $0.reason { true } else { false } }
        case .newReleases, .popular, .mood: loaded[lens.id] ?? []
        }
        for place in returned[lens.id] ?? [] where !songs.contains(place.suggestion) {
            songs.insert(place.suggestion, at: min(place.index, songs.count))
        }
        #if DEBUG
        if FinderDebugState.current == .long { songs = FinderDebugState.longSuggestions + songs }
        #endif
        return songs
    }

    /// A walking lens is empty because Apple Music couldn't be reached, not for want of songs.
    private var isOffline: Bool {
        expands(lens) && discovery.expandFailed
    }

    /// The lenses that walk further out as they're scrolled.
    private func expands(_ lens: SongLens) -> Bool {
        lens == .forYou || lens == .likeYourArtists
    }

    private func isLoading(_ lens: SongLens) -> Bool {
        switch lens {
        case .forYou, .likeYourArtists, .yourArtists: !discovery.hasSeeded || (discovery.songs.isEmpty && discovery.isExpanding)
        default: loaded[lens.id] == nil
        }
    }

    /// A lens where every song has the same reason doesn't need to say it on each.
    private var showsReasons: Bool {
        switch lens {
        case .forYou, .likeYourArtists, .yourArtists, .newReleases: true
        case .popular, .mood: false
        }
    }

    private var emptyMessage: String {
        switch lens {
        case .forYou where isOffline, .likeYourArtists where isOffline:
            String(localized: "Apple Music couldn't be reached. Check your connection, then try again.")
        case .forYou, .likeYourArtists, .yourArtists:
            String(localized: "Suggestions come from the artists you play most. Play a few more songs, and they'll start.")
        case .newReleases:
            String(localized: "None of your artists have put anything out lately that you haven't played.")
        case .popular, .mood:
            String(localized: "You've heard everything here already, or Apple Music couldn't be reached.")
        }
    }

    private func load(_ lens: SongLens) async {
        // An empty answer may have been Apple Music out of reach: it's asked again each time
        // the lens is chosen, rather than kept for the visit.
        guard loaded[lens.id]?.isEmpty != false else { return }
        switch lens {
        case .forYou, .yourArtists, .likeYourArtists:
            return
        default:
            break
        }
        loaded[lens.id] = nil
        let songs = await SongLensLoader.songs(for: lens, discovery: discovery, isDemo: player.isDemo)
        // Another lens was chosen part way: what came back is cut short, not the answer.
        guard !Task.isCancelled else { return }
        loaded[lens.id] = fresh(songs, lens: lens, reason: { song in
            switch lens {
            case .newReleases: .newRelease(song.artistName)
            case .mood(let mood): .mood(mood)
            default: .popular
            }
        })
    }

    /// Never played, the version the explicit setting allows, each once, no artist twice in a row.
    private func fresh(_ songs: [Song], lens: SongLens, reason: (Song) -> SuggestionReason) -> [Suggestion] {
        var seen = Set<String>()
        let unheard = PlayPreferences.versions(of: songs).filter { song in
            let identity = HistoryImport.key(title: song.title, artistName: song.artistName)
            return feed.facts[identity] == nil && !player.signals.excludes(identity, now: .now) && seen.insert(identity).inserted
        }
        return FreshShuffle.order(
            unheard.map { Suggestion(song: $0, reason: reason($0)) },
            artist: { StatsCalculator.folded($0.song.artistName) },
            seed: FreshShuffle.dailySeed(for: .now, salt: "finder.\(lens.id)")
        )
    }

    // MARK: - Not Interested, and Undo

    /// A song taken out, and where it was in its lens, to put it back there.
    struct Returned: Equatable {
        let suggestion: Suggestion
        let index: Int
    }

    /// Not Interested in these: out of every lens and every suggestion, and suggested less.
    /// Undo (the Edit menu, ⌘Z, or shaking an iPhone) brings them back where they were.
    private func dismiss(_ suggestions: [Suggestion]) {
        let lensID = lens.id
        let current = songs(for: lens)
        let places = suggestions.compactMap { suggestion in
            current.firstIndex(of: suggestion).map { Returned(suggestion: suggestion, index: $0) }
        }
        withAnimation(PlayMotion.row) {
            for suggestion in suggestions {
                discovery.dismiss(suggestion)
                for key in loaded.keys { loaded[key]?.removeAll { $0.id == suggestion.id } }
                for key in returned.keys { returned[key]?.removeAll { $0.suggestion.id == suggestion.id } }
            }
        }
        if suggestions.count > 1 {
            player.confirm(String(AttributedString(localized: "Tracks Will Suggest ^[\(suggestions.count) Song](inflect: true) Less").characters))
        }
        undoManager?.registerUndo(withTarget: discovery) { [self] _ in
            MainActor.assumeIsolated { restore(places, in: lensID) }
        }
        undoManager?.setActionName(String(localized: "Not Interested"))
    }

    private func restore(_ places: [Returned], in lensID: String) {
        withAnimation(PlayMotion.row) {
            for place in places.sorted(by: { $0.index < $1.index }) {
                player.setSuggestLess(place.suggestion.identity, false)
                returned[lensID, default: []].append(place)
            }
        }
        // Redo takes them out again.
        undoManager?.registerUndo(withTarget: discovery) { [self] _ in
            MainActor.assumeIsolated { dismiss(places.map(\.suggestion)) }
        }
        undoManager?.setActionName(String(localized: "Not Interested"))
    }

    private func play(_ songs: [Suggestion], from suggestion: Suggestion? = nil, shuffled: Bool = false) {
        let all = songs.map(\.song)
        guard !all.isEmpty else { return }
        let start = suggestion.flatMap { all.firstIndex(of: $0.song) } ?? 0
        let context = PlayContext.songs(lens.title)
        guard let suggestion else {
            player.play(.songs(all, startingAt: start), from: context, shuffled: shuffled)
            return
        }
        // One song chosen: with your own music, it has to be there to start from.
        Task {
            await SuggestionPlayback.play(suggestion.song, source: model.musicSource, music: music, player: player) {
                player.play(.songs(all, startingAt: start), from: context, shuffled: shuffled)
            }
        }
    }
}

/// Where the lenses Discovery doesn't keep get their songs.
@MainActor
enum SongLensLoader {
    static func songs(for lens: SongLens, discovery: Discovery, isDemo: Bool) async -> [Song] {
        #if DEBUG
        if isDemo {
            let offset = switch lens {
            case .newReleases: 900
            case .popular: 1_000
            case .mood(let mood): 1_100 + (Mood.allCases.firstIndex(of: mood) ?? 0) * 40
            default: 0
            }
            return DemoCatalog.songs(count: 30, offset: offset, artists: nil)
        }
        #endif
        guard !isDemo, MusicAuthorization.currentStatus == .authorized else { return [] }
        switch lens {
        case .newReleases:
            await discovery.loadReleases()
            let albums = discovery.releases.filter { !$0.isUpcoming }.prefix(14).map(\.album)
            return await tracks(of: Array(albums))
        case .popular:
            return await popular()
        case .mood(let mood):
            let playlists = await MoodCatalog.items(for: mood).playlists.compactMap { item -> Playlist? in
                if case .playlist(let playlist) = item.content { playlist } else { nil }
            }
            return await MoodCatalog.songs(in: playlists, allowsExplicit: PlayPreferences.allowsExplicit)
        default:
            return []
        }
    }

    @concurrent
    private nonisolated static func tracks(of albums: [Album]) async -> [Song] {
        await withTaskGroup(of: (Int, [Song]).self) { group in
            for (index, album) in albums.enumerated() {
                group.addTask {
                    let tracks = (try? await album.with([.tracks]).tracks).map(Array.init) ?? []
                    return (index, tracks.compactMap { if case .song(let song) = $0 { song } else { nil } })
                }
            }
            var byIndex: [Int: [Song]] = [:]
            for await (index, songs) in group { byIndex[index] = songs }
            return byIndex.keys.sorted().flatMap { byIndex[$0] ?? [] }
        }
    }

    /// Apple Music's most played songs, two pages deep.
    @concurrent
    private nonisolated static func popular() async -> [Song] {
        var request = MusicCatalogChartsRequest(kinds: [.mostPlayed], types: [Song.self])
        request.limit = 50
        guard let chart = try? await request.response().songCharts.first else { return [] }
        var songs = Array(chart.items)
        if chart.items.hasNextBatch, let more = try? await chart.items.nextBatch() {
            songs += Array(more)
        }
        return songs
    }
}
