import SwiftUI
import MusicKit
import TracksCore

/// A genre's page, built for the genre: its name set as its music sounds, its colours, your
/// covers in it laid out its own way, then your songs in it through the decades, your
/// essentials and what's rising, new songs and artists from its Apple Music charts, its albums
/// and playlists, and where it started for you. With your own music, what you have of it.
struct GenreView: View {
    let genre: MusicGenre
    @Environment(AppModel.self) private var model
    @Environment(PlayerModel.self) private var player
    @Environment(PlayFeed.self) private var feed
    @Environment(YourMusic.self) private var music
    @Environment(\.openURL) private var openURL
    @State private var charts = GenreCatalog.Found.empty
    @State private var reach = CatalogReach.loading
    /// Nil until your songs in it are worked out.
    @State private var room: ListeningRoom?
    @State private var artists: [FavoriteArtist] = []
    @State private var newArtists: [Artist] = []
    @State private var local: LocalGenres.Group?
    @State private var localAlbums: [LocalAlbum] = []
    @State private var hasLoaded = false
    @State private var isStarting = false
    @State private var decade: Int?
    @State private var showsAllDecade = false
    @State private var showsAllYours = false
    @State private var showsAllNew = false
    @State private var showsAllRising = false

    var body: some View {
        let style = genre.style
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero(style)
                VStack(alignment: .leading, spacing: style.pace.sectionSpacing) {
                    if model.musicSource == .yourMusic {
                        localSongs(style)
                        localAlbumsShelf
                    } else {
                        decades(style)
                        essentials(style)
                        rising(style)
                        newToYou(style)
                        artistsToDiscover
                        if !artists.isEmpty {
                            Shelf(title: String(localized: "Your \(genre.title) Artists"), items: artists) { FavoriteArtistTile(artist: $0) }
                        }
                        if !charts.albums.isEmpty {
                            Shelf(title: String(localized: "Top Albums"), items: charts.albums) { FeedTile(item: $0) }
                        }
                        if !charts.playlists.isEmpty {
                            Shelf(title: String(localized: "Playlists"), items: charts.playlists) { FeedTile(item: $0) }
                        }
                        whereItStarted(style)
                    }
                }
                .padding(.top, 12)
            }
            .padding(.bottom, 32)
        }
        .tint(style.ink)
        .heroTitle(genre.title)
        #if DEBUG
        .launchScroll()
        #endif
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
    }

    // MARK: Hero

    private func hero(_ style: RoomStyle) -> some View {
        RoomHero(
            style: style,
            title: genre.title,
            tagline: genre.tagline,
            facts: facts,
            covers: heroCovers(style),
            isLoading: !hasLoaded
        ) {
            RoomPlayButtons(
                style: style,
                playTitle: playTitle,
                playSymbol: isOn && player.isPlaying ? "pause.fill" : "play.fill",
                canPlay: canPlay && !isStarting,
                shuffle: canShuffle ? { shuffleYours() } as () -> Void : nil,
                play: playOrPause
            )
            .frame(maxWidth: Self.controlsWidth, alignment: .leading)
        }
    }

    /// How much of it is yours, and since when.
    private var facts: String? {
        if model.musicSource == .yourMusic {
            guard let count = local?.tracks.count, count > 0 else { return nil }
            return String(AttributedString(localized: "^[\(count) song](inflect: true) in your music").characters)
        }
        guard let room, !room.isEmpty else { return nil }
        let count = String(AttributedString(localized: "^[\(room.songs.count) song](inflect: true) of yours").characters)
        guard let first = room.first else { return count }
        return "\(count) · " + String(localized: "Since \(first.firstHeard.formatted(.dateTime.month(.wide).year()))")
    }

    private func heroCovers(_ style: RoomStyle) -> [CoverArt] {
        let count = CoverMosaic.count(for: style.covers)
        if model.musicSource == .yourMusic {
            return localAlbums.prefix(count).map { album in
                .url(music.artworkURL(album.artwork)?.absoluteString, seed: album.title)
            }
        }
        if let room, !room.isEmpty { return room.covers(count) }
        if !charts.albums.isEmpty { return charts.albums.prefix(count).map(\.cover) }
        return charts.songs.prefix(count).map { $0.artwork.map(CoverArt.artwork) ?? .url(nil, seed: $0.albumTitle ?? $0.title) }
    }

    /// The station's on, playing or paused.
    private var isOn: Bool {
        player.hasQueue && player.context == genre.context
    }

    private var playTitle: LocalizedStringKey {
        if isStarting { return "Starting…" }
        guard isOn else { return "Play Station" }
        return player.isPlaying ? "Pause" : "Resume"
    }

    private var canPlay: Bool {
        guard hasLoaded else { return true }
        if model.musicSource == .yourMusic { return !(local?.tracks.isEmpty ?? true) }
        return !charts.songs.isEmpty || !(room?.isEmpty ?? true)
    }

    private var canShuffle: Bool {
        model.musicSource == .yourMusic ? !(local?.tracks.isEmpty ?? true) : !(room?.isEmpty ?? true)
    }

    #if os(macOS)
    private static let controlsWidth: CGFloat = 520
    private static let risingRows = 6
    #else
    private static let controlsWidth: CGFloat = .infinity
    private static let risingRows = 5
    #endif

    // MARK: Your listening

    /// Your songs in it by the decade they came out: its eras, as you've heard them.
    @ViewBuilder
    private func decades(_ style: RoomStyle) -> some View {
        if let decades = room?.decades(), !decades.isEmpty {
            let chosen = decades.first { $0.start == decade } ?? decades.max { $0.songs.count < $1.songs.count } ?? decades[0]
            let songs = chosen.songs
            let shown = Array(songs.prefix(showsAllDecade ? 25 : style.pace.rows))
            VStack(alignment: .leading, spacing: 0) {
                RoomSectionHeader(
                    title: String(localized: "Through the Decades"),
                    note: String(localized: "Your \(genre.title) songs by when they came out.")
                ) {
                    RoomSectionAction(title: "Play", symbol: "play.fill", ink: style.ink) {
                        play(songs, title: chosen.title, shuffled: true)
                    }
                }
                DecadePicker(decades: decades, chosen: chosen.start, style: style) { start in
                    decade = start
                    showsAllDecade = false
                }
                .padding(.vertical, 4)
                RoomColumns(items: shown) { song in
                    historyRow(song, detail: song.releaseYear.map { String($0) }) {
                        play(songs, startingAt: song, title: chosen.title)
                    }
                }
                if songs.count > style.pace.rows {
                    RoomShowMore(isShowingAll: $showsAllDecade, ink: style.ink)
                }
            }
            .padding(.horizontal, PlayMetrics.margin)
        }
    }

    @ViewBuilder
    private func essentials(_ style: RoomStyle) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            RoomSectionHeader(title: String(localized: "Your Essentials"))
            if let room {
                if room.isEmpty {
                    RoomNote(
                        text: String(localized: "You haven't played any \(genre.title) yet. The songs you play in it will gather here."),
                        symbol: genre.symbol
                    )
                } else {
                    let shown = Array(room.songs.prefix(showsAllYours ? 25 : style.pace.rows))
                    RoomColumns(items: shown) { song in
                        historyRow(song, detail: PlayCountText.short(song.plays)) {
                            play(room.songs, startingAt: song, title: String(localized: "Your \(genre.title) Essentials"))
                        }
                    }
                    if room.songs.count > style.pace.rows {
                        RoomShowMore(isShowingAll: $showsAllYours, ink: style.ink)
                    }
                }
            } else {
                LoadingRows(count: style.pace.rows)
            }
        }
        .padding(.horizontal, PlayMetrics.margin)
    }

    @ViewBuilder
    private func rising(_ style: RoomStyle) -> some View {
        if let songs = room?.rising(), !songs.isEmpty {
            let shown = Array(songs.prefix(showsAllRising ? songs.count : Self.risingRows))
            VStack(alignment: .leading, spacing: 0) {
                RoomSectionHeader(
                    title: String(localized: "Rising"),
                    note: String(localized: "Played more in the last 30 days than the 30 before.")
                )
                RoomColumns(items: shown) { song in
                    historyRow(song, detail: String(localized: "\(song.recentPlays) this month")) {
                        play(songs, startingAt: song, title: String(localized: "Rising in \(genre.title)"))
                    }
                }
                if songs.count > Self.risingRows {
                    RoomShowMore(isShowingAll: $showsAllRising, ink: style.ink)
                }
            }
            .padding(.horizontal, PlayMetrics.margin)
        }
    }

    /// The first song of it you played, at the foot of the page.
    @ViewBuilder
    private func whereItStarted(_ style: RoomStyle) -> some View {
        if let first = room?.first, (room?.songs.count ?? 0) >= ListeningRoom.fewest {
            VStack(alignment: .leading, spacing: 0) {
                RoomSectionHeader(
                    title: String(localized: "Where It Started"),
                    note: String(localized: "The first \(genre.title) song you played, \(first.firstHeard.formatted(date: .long, time: .omitted)).")
                )
                historyRow(first, detail: PlayCountText.short(first.plays)) {
                    play([first], title: genre.title)
                }
            }
            .padding(.horizontal, PlayMetrics.margin)
        }
    }

    private func historyRow(_ song: ListeningRoom.Song, detail: String?, play: @escaping () -> Void) -> some View {
        let canPlay = player.canPlay(songID: song.song.songID)
        return Button(action: play) {
            RoomSongRow(
                title: song.song.title,
                artist: song.song.artistName,
                cover: song.cover,
                detail: detail,
                isCurrent: player.current?.songIdentity == song.song.songIdentity,
                isPlayable: canPlay
            )
        }
        .buttonStyle(.plain)
        .disabled(!canPlay)
        .contextMenu { HistorySongMenu(song: song.song) }
    }

    // MARK: Apple Music

    @ViewBuilder
    private func newToYou(_ style: RoomStyle) -> some View {
        let fresh = freshCharts
        VStack(alignment: .leading, spacing: 0) {
            RoomSectionHeader(
                title: String(localized: "New to You"),
                note: reach == .found && !fresh.isEmpty ? String(localized: "From what's most played in \(genre.title) on Apple Music.") : nil
            )
            switch reach {
            case .loading:
                LoadingRows(count: style.pace.rows)
            case .notAuthorized:
                RoomNote(
                    text: String(localized: "Connect Apple Music for new songs, albums and playlists in \(genre.title)."),
                    symbol: "music.note",
                    action: model.musicAuthorization == .denied
                        ? RoomNoteAction(title: "Open Settings", run: openMusicSettings)
                        : RoomNoteAction(title: "Connect Apple Music", run: connectAppleMusic)
                )
            case .unreachable:
                RoomNote(
                    text: String(localized: "Couldn't reach Apple Music. New songs in \(genre.title) will be here when it's back."),
                    symbol: "wifi.slash",
                    action: RoomNoteAction(title: "Try Again", run: retryCatalog)
                )
            case .found:
                if fresh.isEmpty {
                    RoomNote(text: String(localized: "You've heard everything in \(genre.title)'s charts. New ones show up as they change."))
                } else {
                    let shown = Array(fresh.prefix(showsAllNew ? 25 : style.pace.rows))
                    RoomColumns(items: shown) { suggestion in
                        SuggestionRow(suggestion: suggestion, showsReason: false) {
                            let all = charts.songs
                            player.play(.songs(all, startingAt: all.firstIndex(of: suggestion.song) ?? 0), from: .songs(String(localized: "Top \(genre.title)")))
                        }
                        .contextMenu { SongMenu(song: suggestion.song) }
                    }
                    if fresh.count > style.pace.rows {
                        RoomShowMore(isShowingAll: $showsAllNew, ink: style.ink)
                    }
                }
            }
        }
        .padding(.horizontal, PlayMetrics.margin)
    }

    /// The genre's chart songs you've never played.
    private var freshCharts: [Suggestion] {
        charts.songs
            .filter { feed.facts[HistoryImport.key(title: $0.title, artistName: $0.artistName)] == nil }
            .map { Suggestion(song: $0, reason: .popular) }
    }

    @ViewBuilder
    private var artistsToDiscover: some View {
        if !newArtists.isEmpty {
            Shelf(title: String(localized: "Artists to Discover"), items: newArtists) { artist in
                NavigationLink(value: PlayRoute.artist(artist)) {
                    ArtistCircleTile(name: artist.name, picture: artist.artwork.map(CoverArt.artwork), detail: nil)
                }
                .buttonStyle(.pressable)
            }
        }
    }

    // MARK: Your own music

    @ViewBuilder
    private func localSongs(_ style: RoomStyle) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            RoomSectionHeader(title: String(localized: "Songs"))
            if let tracks = local?.tracks, !tracks.isEmpty {
                let shown = Array(tracks.prefix(showsAllYours ? 50 : style.pace.rows + 2))
                RoomColumns(items: shown) { track in
                    Button {
                        player.play(.local(tracks, startingAt: tracks.firstIndex(of: track) ?? 0), from: .songs(genre.title))
                    } label: {
                        LocalTrackRow(track: track, isCurrent: player.current?.local?.id == track.id)
                            .padding(.vertical, 6)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { LocalTrackMenu(track: track) }
                }
                if tracks.count > style.pace.rows + 2 {
                    RoomShowMore(isShowingAll: $showsAllYours, ink: style.ink)
                }
            } else if hasLoaded {
                RoomNote(
                    text: String(localized: "None of your music is tagged \(genre.title). Tracks goes by each song's genre."),
                    symbol: genre.symbol
                )
            } else {
                LoadingRows(count: style.pace.rows)
            }
        }
        .padding(.horizontal, PlayMetrics.margin)
    }

    @ViewBuilder
    private var localAlbumsShelf: some View {
        if !localAlbums.isEmpty {
            Shelf(title: String(localized: "Albums"), items: localAlbums) { album in
                LocalAlbumTile(album: album)
            }
        }
    }

    /// Albums of yours with a song in the genre, the most played song's first.
    private static func albums(of tracks: [LocalTrack], in music: YourMusic) -> [LocalAlbum] {
        var albumOf: [String: LocalAlbum] = [:]
        for album in music.index.albums {
            for track in album.tracks { albumOf[track.id] = album }
        }
        var seen = Set<String>()
        return Array(tracks.compactMap { albumOf[$0.id] }.filter { seen.insert($0.id).inserted }.prefix(20))
    }

    // MARK: Playing

    private func playOrPause() {
        if isOn {
            player.togglePlayPause()
            return
        }
        isStarting = true
        Task {
            await GenrePlayback.start(genre, model: model, charts: reach == .found ? charts.songs : nil)
            isStarting = false
        }
    }

    private func shuffleYours() {
        if model.musicSource == .yourMusic, let tracks = local?.tracks {
            player.play(.local(tracks), from: .songs(genre.title), shuffled: true)
        } else if let room {
            play(room.songs, title: String(localized: "Your \(genre.title) Songs"), shuffled: true)
        }
    }

    private func play(_ songs: [ListeningRoom.Song], startingAt first: ListeningRoom.Song? = nil, title: String, shuffled: Bool = false) {
        let playable = songs.filter { player.canPlay(songID: $0.song.songID) }
        let start = first.flatMap { playable.firstIndex(of: $0) } ?? 0
        player.play(.history(playable.map { HistorySong($0.song) }, startingAt: start), from: .songs(title), shuffled: shuffled)
    }

    private func connectAppleMusic() {
        Task {
            await model.requestMusicAccess()
            await loadCharts()
        }
    }

    private func openMusicSettings() {
        if let url = SystemSettingsLink.musicAccess { openURL(url) }
    }

    private func retryCatalog() {
        reach = .loading
        Task { await loadCharts() }
    }

    // MARK: Loading

    private func load() async {
        // Once per visit, but charts left unfinished, or that couldn't reach Apple Music, are
        // asked for again on the way back.
        if !hasLoaded {
            let history = model.library.history
            if model.musicSource == .yourMusic {
                local = LocalGenres.group(music.playableTracks, history: history, facts: feed.facts).first { $0.genre == genre }
                localAlbums = Self.albums(of: local?.tracks ?? [], in: music)
                hasLoaded = true
                return
            }
            let (signals, genre) = (player.signals, genre)
            let (room, profile) = await OffMainActor.run {
                (ListeningRoom.genre(genre, in: history, signals: signals), MusicGenre.profiles(in: history, signals: signals).first { $0.genre == genre })
            }
            self.room = room
            artists = profile?.artists ?? []
            hasLoaded = true
        }
        guard model.musicSource != .yourMusic, reach != .found else { return }
        await loadCharts()
    }

    private func loadCharts() async {
        guard player.isDemo || model.musicAuthorization == .authorized else {
            reach = .notAuthorized
            return
        }
        let loaded = await GenreCatalog.load(genre, isDemo: player.isDemo)
        // Left part way: what came back is cut short, not Apple Music being out of reach.
        guard !Task.isCancelled else { return }
        charts = loaded
        let isEmpty = charts.songs.isEmpty && charts.albums.isEmpty && charts.playlists.isEmpty
        reach = isEmpty && !player.isDemo ? .unreachable : .found
        let found = await MoodCatalog.artists(of: freshCharts.map(\.song), leavingOut: feed.heardArtists, isDemo: player.isDemo)
        guard !Task.isCancelled else { return }
        newArtists = found
    }
}

extension ListeningRoom.Decade {
    /// "1990s", as the decade is said.
    var title: String { String(localized: "\(String(start))s") }
}

/// The decades a genre's songs of yours came out in, as a row of capsules to choose one, the
/// chosen one in the genre's colour.
struct DecadePicker: View {
    let decades: [ListeningRoom.Decade]
    let chosen: Int
    let style: RoomStyle
    let choose: (Int) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Deep in light, lifted in dark, so the chosen one stands off either page.
        let chosenFill = colorScheme == .dark ? style.base.mix(with: .white, by: 0.18) : style.base.mix(with: .black, by: 0.2)
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(decades) { decade in
                    let isChosen = decade.start == chosen
                    Button {
                        choose(decade.start)
                    } label: {
                        Text(decade.title)
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(isChosen ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                            .padding(.horizontal, 14)
                            .frame(minHeight: Self.height)
                            .background(isChosen ? AnyShapeStyle(chosenFill) : AnyShapeStyle(.fill.tertiary), in: .capsule)
                            .padding(.vertical, Self.reach)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isChosen ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .sensoryFeedback(.selection, trigger: chosen)
    }

    #if os(macOS)
    private static let height: CGFloat = 28
    private static let reach: CGFloat = 0
    #else
    private static let height: CGFloat = 36
    /// Above and below, so a finger's target is 44 points tall.
    private static let reach: CGFloat = 4
    #endif
}
