import SwiftUI
import TracksCore

/// Your listening history searched, laid out as the other scopes are: the best match, the
/// songs, then the artists and albums. Each opens its page of stats. Before you type, what you
/// searched lately, ways to remember a song by, and who and what you play most.
///
/// For a song whose name escapes you, it also reads what you remember about it: when you heard
/// it, on which station, its era, or what played around it (``HistoryRecall``).
struct HistorySearchResults: View {
    let query: String
    /// Puts a search in the field: a recent one or a suggestion.
    let search: (String) -> Void

    @Environment(AppModel.self) private var model
    @Environment(PlayerModel.self) private var player
    @Environment(\.openPlayRoute) private var openRoute
    @AppStorage("recentHistorySearches") private var recentStorage = ""
    @State private var results = SearchResults.empty
    /// What a remembered search found, when what's typed was read that way.
    @State private var recalled: Recalled?
    /// What was understood when it found nothing, to say so.
    @State private var understood: HistoryRecall?
    /// The nearest remembered search that finds something, when the one typed finds nothing.
    @State private var closest: Recalled?
    /// The query `results` answer, so No Results waits for the current one.
    @State private var answeredQuery: String?
    @State private var topArtists: [ArtistTally] = []
    @State private var topAlbums: [AlbumTally] = []
    @State private var suggestions: [String] = []
    /// Built once per change to the history, so each letter typed only filters it.
    @State private var index: SearchIndex?
    /// Bumped as each new index lands, so results on screen are searched again.
    @State private var indexGeneration = 0
    @State private var showsAllSongs = false

    private static let songsShown = 8
    private static let playsShown = 25

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PlayMetrics.sectionSpacing) {
                if isBlank {
                    blank
                } else if let recalled {
                    recallSections(recalled)
                } else {
                    // What was found last stays while the next search runs, so typing never blinks.
                    resultSections
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.immediately)
        .overlay { overlay }
        // A play that just finished, or one deleted or synced in, shows up in results already
        // on screen.
        .task(id: model.library.revision) {
            let history = model.library.history
            let (next, phrases) = await OffMainActor.run {
                let index = SearchIndex(history: history)
                return (index, index.recallSuggestions())
            }
            guard !Task.isCancelled else { return }
            index = next
            indexGeneration += 1
            topArtists = next.topArtists(limit: 10)
            topAlbums = next.topAlbums(limit: 10)
            suggestions = phrases
        }
        .task(id: SearchKey(query: query, indexGeneration: indexGeneration)) {
            guard let index else { return }
            let query = query
            if !isBlank {
                // A short pause so typing doesn't search on every letter.
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
            }
            let found = await OffMainActor.run { Self.search(query, in: index) }
            guard !Task.isCancelled else { return }
            results = found.plain
            recalled = found.recalled
            understood = found.understood
            closest = found.closest
            answeredQuery = query
        }
        .onChange(of: query) { showsAllSongs = false }
    }

    /// The plain search, and what's remembered when the words say a time, a station, an era or
    /// a song played around. A song called exactly what was typed is found as itself, and a
    /// remembered search that finds nothing gives way to the plain one.
    nonisolated private static func search(_ query: String, in index: SearchIndex) -> Found {
        let plain = index.search(query)
        let recall = HistoryRecall.parse(query, stations: index.stations)
        guard recall.hasFilters, !plain.hasName(matching: query) else { return Found(plain: plain) }
        let found = index.recall(recall)
        guard found.isEmpty else {
            return Found(plain: plain, recalled: Recalled(recall: recall, results: found), understood: recall)
        }
        var looser = recall.loosened()
        while let next = looser {
            let near = index.recall(next)
            if !near.isEmpty {
                return Found(plain: plain, understood: recall, closest: Recalled(recall: next, results: near))
            }
            looser = next.loosened()
        }
        return Found(plain: plain, understood: recall)
    }

    // MARK: - Before searching

    @ViewBuilder
    private var blank: some View {
        if !recents.isEmpty {
            RecentSearchesSection(recents: recents, clear: { recentStorage = "" }, search: search) {
                recentStorage = RecentSearches.removing($0, from: recentStorage)
            }
        }
        if !suggestions.isEmpty {
            RecallSuggestionsSection(phrases: suggestions, search: search)
        }
        if !topArtists.isEmpty {
            Shelf(title: String(localized: "Your Top Artists"), items: topArtists) { artist in
                artistTile(artist)
            }
        }
        if !topAlbums.isEmpty {
            Shelf(title: String(localized: "Your Top Albums"), items: topAlbums) { album in
                albumTile(album)
            }
        }
    }

    // MARK: - Results

    private var topKind: SearchTopKind? {
        SearchRanking.topKind(
            for: query,
            artist: results.artists.first?.name,
            album: results.albums.first?.title,
            song: results.songs.first?.title
        )
    }

    @ViewBuilder
    private var resultSections: some View {
        let kind = topKind
        let top = kind.flatMap(card)
        // The top result's song isn't listed again under it.
        let songs = kind == .song ? Array(results.songs.dropFirst()) : results.songs
        let shownSongs = showsAllSongs ? songs : Array(songs.prefix(Self.songsShown))
        SearchLead(top: top, hasSongs: !shownSongs.isEmpty) {
            songsTitle(total: songs.count)
        } songs: {
            songRows(shownSongs, all: results.songs)
        }
        shelves(artists: kind == .artist ? Array(results.artists.dropFirst()) : results.artists,
                albums: kind == .album ? Array(results.albums.dropFirst()) : results.albums)
    }

    @ViewBuilder
    private func shelves(artists: [ArtistTally], albums: [AlbumTally]) -> some View {
        if !artists.isEmpty {
            Shelf(title: String(localized: "Artists"), items: Array(artists.prefix(10))) { artist in
                artistTile(artist)
            }
        }
        if !albums.isEmpty {
            Shelf(title: String(localized: "Albums"), items: Array(albums.prefix(10))) { album in
                albumTile(album)
            }
        }
    }

    private func songsTitle(total: Int, shown: Int = Self.songsShown) -> some View {
        HStack(alignment: .firstTextBaseline) {
            SearchSectionTitle("Songs")
            Spacer()
            if total > shown {
                Button(showsAllSongs ? "Show Less" : "See All") {
                    withAnimation(PlayMotion.panel) { showsAllSongs.toggle() }
                }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(.tint)
            }
        }
    }

    /// Songs that open their stats; their menus play them.
    private func songRows(_ shown: [SongTally], all: [SongTally]) -> some View {
        SearchSongGrid(items: shown) { song in
            Button {
                remember()
                push(.song(song.id))
            } label: {
                TrackRow(
                    title: song.title,
                    subtitle: [song.artistName, song.albumTitle].compactMap(\.self).joined(separator: " · "),
                    cover: .url(song.artworkURL, seed: song.albumTitle ?? song.title),
                    isCurrent: player.current?.songIdentity == song.id,
                    artist: song.artistName
                )
                .padding(.vertical, 5)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .contextMenu { songMenu(song, all: all) }
        }
    }

    /// A song's menu, with ways to find what played around it.
    @ViewBuilder
    private func songMenu(_ song: SongTally, all: [SongTally]) -> some View {
        HistorySongMenu(song: MixSong(tally: song)) { play(all, from: song) }
        Section {
            Button("Show What Played After", systemImage: "arrow.forward") {
                remember()
                model.beginSearch(in: .history, for: "after \(song.title)")
            }
            Button("Show What Played Before", systemImage: "arrow.backward") {
                remember()
                model.beginSearch(in: .history, for: "before \(song.title)")
            }
        }
    }

    private func artistTile(_ artist: ArtistTally) -> some View {
        Button {
            remember()
            push(.artist(artist.id))
        } label: {
            VStack(spacing: 8) {
                ArtistPicture(cover: artist.artworkURL.map { .url($0, seed: artist.name) }, name: artist.name, size: 120)
                Text(artist.name)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(width: 120)
            .contentShape(.rect)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(artist.name)
    }

    private func albumTile(_ album: AlbumTally) -> some View {
        Button {
            remember()
            push(.album(album.id))
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                CoverImage(cover: .url(album.artworkURL, seed: album.title), size: PlayMetrics.tile)
                VStack(alignment: .leading, spacing: 1) {
                    Text(album.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(album.artistName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: PlayMetrics.tile, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Remembered

    @ViewBuilder
    private func recallSections(_ recalled: Recalled) -> some View {
        let found = recalled.results
        let title = RecallTitle(recalled.recall, anchor: found.anchor?.title)
        switch found.layout {
        case .timeline:
            VStack(alignment: .leading, spacing: 10) {
                RecallHeader(title: title, play: playable(recalled.timelineSongs).isEmpty ? nil : {
                    remember()
                    play(recalled.timelineSongs, from: nil)
                })
                timeline(recalled)
            }
            .padding(.horizontal, PlayMetrics.margin)
        case .mostPlayed:
            // With nothing heard twice, no song is the most played.
            let hasRepeats = (found.songs.first?.count ?? 0) > 1
            let top = hasRepeats ? found.songs.first.map { mostPlayedCard($0, all: found.songs) } : nil
            let songs = hasRepeats ? Array(found.songs.dropFirst()) : found.songs
            let shownSongs = showsAllSongs ? songs : Array(songs.prefix(Self.songsShown))
            VStack(alignment: .leading, spacing: 14) {
                RecallHeader(title: title, play: playable(found.songs).isEmpty ? nil : {
                    remember()
                    play(found.songs, from: nil)
                })
                .padding(.horizontal, PlayMetrics.margin)
                SearchLead(top: top, topTitle: recalled.recall.relation == nil ? "Most Played" : "Most Often", hasSongs: !shownSongs.isEmpty) {
                    songsTitle(total: songs.count)
                } songs: {
                    songRows(shownSongs, all: found.songs)
                }
            }
            shelves(artists: found.artists, albums: found.albums)
        }
    }

    /// A day or a night, play by play, newest first, each with when it played.
    private func timeline(_ recalled: Recalled) -> some View {
        let plays = recalled.results.plays
        let shown = showsAllSongs ? plays : Array(plays.prefix(Self.playsShown))
        let groups = recalled.isWithinDay ? [] : Recalled.days(of: shown)
        return VStack(alignment: .leading, spacing: 0) {
            if recalled.isWithinDay {
                ForEach(shown) { play in
                    timelineRow(play, recalled: recalled)
                }
            } else {
                // Over days, each day under its date, as History has them.
                ForEach(groups, id: \.day) { group in
                    Text(group.day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, group.day == groups.first?.day ? 4 : 14)
                        .padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.plays) { play in
                        timelineRow(play, recalled: recalled)
                    }
                }
            }
            if plays.count > Self.playsShown {
                Button(showsAllSongs ? "Show Less" : "Show All \(plays.count)") {
                    withAnimation(PlayMotion.panel) { showsAllSongs.toggle() }
                }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(.tint)
                .padding(.top, 10)
            }
        }
    }

    private func timelineRow(_ play: RecallPlay, recalled: Recalled) -> some View {
        let capture = play.capture
        let song = recalled.song(capture.songIdentity)
        return Button {
            remember()
            push(.song(capture.songIdentity))
        } label: {
            TrackRow(
                title: capture.title,
                subtitle: [capture.artistName, capture.stationName].compactMap(\.self).joined(separator: " · "),
                cover: .url(song?.artworkURL ?? capture.artworkURL, seed: capture.albumTitle ?? capture.title),
                isCurrent: player.current?.songIdentity == capture.songIdentity,
                detail: capture.capturedAt.formatted(date: .omitted, time: .shortened)
            )
            .padding(.vertical, 5)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let song { songMenu(song, all: recalled.timelineSongs) }
        }
    }

    private func mostPlayedCard(_ song: SongTally, all: [SongTally]) -> SearchTopResult {
        SearchTopResult(
            title: song.title,
            kind: String(localized: "Song · \(song.artistName)"),
            cover: .url(song.artworkURL, seed: song.albumTitle ?? song.title),
            open: { remember(); push(.song(song.id)) },
            play: playable([song]).isEmpty ? nil : { remember(); play(all, from: song) }
        )
    }

    // MARK: - The top result

    private func card(for kind: SearchTopKind) -> SearchTopResult? {
        switch kind {
        case .artist:
            guard let artist = results.artists.first else { return nil }
            let theirs = results.songs.filter { $0.credits.contains { $0.identity == artist.id } }
            return SearchTopResult(
                title: artist.name,
                kind: String(localized: "Artist"),
                cover: artist.artworkURL.map { .url($0, seed: artist.name) },
                isArtist: true,
                open: { remember(); push(.artist(artist.id)) },
                play: playable(theirs).isEmpty ? nil : { remember(); play(theirs, from: nil) }
            )
        case .album:
            guard let album = results.albums.first else { return nil }
            return SearchTopResult(
                title: album.title,
                kind: String(localized: "Album · \(album.artistName)"),
                cover: .url(album.artworkURL, seed: album.title),
                open: { remember(); push(.album(album.id)) },
                play: nil
            )
        case .song:
            guard let song = results.songs.first else { return nil }
            return SearchTopResult(
                title: song.title,
                kind: String(localized: "Song · \(song.artistName)"),
                cover: .url(song.artworkURL, seed: song.albumTitle ?? song.title),
                open: { remember(); push(.song(song.id)) },
                play: playable([song]).isEmpty ? nil : { remember(); play(results.songs, from: song) }
            )
        }
    }

    // MARK: - Playing

    private func playable(_ songs: [SongTally]) -> [SongTally] {
        songs.filter { player.canPlay(songID: $0.songID) }
    }

    /// The songs that can play, from `song` on, in Tracks' player.
    private func play(_ songs: [SongTally], from song: SongTally?) {
        let queue = playable(songs)
        guard !queue.isEmpty else { return }
        let start = song.flatMap { song in queue.firstIndex { $0.id == song.id } } ?? 0
        let ordered = Array(queue[start...]) + Array(queue[..<start])
        player.play(.history(ordered.map { HistorySong(MixSong(tally: $0)) }), from: .songs(String(localized: "Search")))
    }

    private func push(_ route: Route) {
        openRoute(.stats(route))
    }

    // MARK: - States

    @ViewBuilder
    private var overlay: some View {
        if model.library.isLoaded, model.library.history.captures.isEmpty, recents.isEmpty || !isBlank {
            ContentUnavailableView(
                "Nothing Played Yet",
                systemImage: "clock.arrow.circlepath",
                description: Text("Songs you play show up here, to find by name or by when and where you heard them.")
            )
        } else if !isBlank, answeredQuery == query, results.isEmpty, recalled == nil {
            if understood != nil {
                // Apple Music can't know when you heard something, so the way on is a looser
                // search of the history.
                ContentUnavailableView {
                    Label("No Results", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Nothing you played fits “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                } actions: {
                    if let closest {
                        Button(Self.closestTitle(closest)) {
                            withAnimation(PlayMotion.panel) { recalled = closest }
                        }
                    }
                }
            } else {
                SearchNoResults(query: query)
            }
        }
    }

    /// "Show All of Tuesday Evening", or plainer when the closest search still has more to it.
    private static func closestTitle(_ closest: Recalled) -> String {
        let title = RecallTitle(closest.recall, anchor: closest.results.anchor?.title)
        guard title.detail == nil else { return String(localized: "Show Closest Matches") }
        return String(localized: "Show All of \(title.title)")
    }

    private var isBlank: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Recent searches

    private var recents: [String] {
        RecentSearches.list(recentStorage)
    }

    private func remember() {
        recentStorage = RecentSearches.adding(query, to: recentStorage)
    }
}

/// What one search found: the plain matches, and what was remembered.
nonisolated private struct Found: Sendable {
    let plain: SearchResults
    var recalled: Recalled?
    /// What was read from the words, when it was a remembered search.
    var understood: HistoryRecall?
    var closest: Recalled?
}

private struct SearchKey: Equatable {
    let query: String
    let indexGeneration: Int
}

/// What a remembered search read and found.
nonisolated private struct Recalled: Sendable {
    let recall: HistoryRecall
    let results: RecallResults
    private let songsByID: [String: SongTally]
    /// A timeline's songs in the order they played, each once, to play again.
    let timelineSongs: [SongTally]

    init(recall: HistoryRecall, results: RecallResults) {
        self.recall = recall
        self.results = results
        songsByID = Dictionary(results.songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        timelineSongs = results.plays.reversed().compactMap { [songsByID] play in
            guard seen.insert(play.capture.songIdentity).inserted else { return nil }
            return songsByID[play.capture.songIdentity]
        }
    }

    func song(_ identity: String) -> SongTally? {
        songsByID[identity]
    }

    /// Whether the timeline is one day or night, so its plays need only their times.
    var isWithinDay: Bool {
        (recall.interval?.duration ?? .infinity) <= 36 * 3600
    }

    /// Plays in order, grouped by the day they played on.
    static func days(of plays: [RecallPlay], calendar: Calendar = .current) -> [(day: Date, plays: [RecallPlay])] {
        var groups: [(day: Date, plays: [RecallPlay])] = []
        for play in plays {
            let day = calendar.startOfDay(for: play.capture.capturedAt)
            if groups.last?.day == day {
                groups[groups.count - 1].plays.append(play)
            } else {
                groups.append((day, [play]))
            }
        }
        return groups
    }
}
