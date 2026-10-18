import SwiftUI
import MusicKit
import TracksCore

extension Mood {
    var title: String {
        switch self {
        case .feelGood: String(localized: "Feel Good")
        case .energy: String(localized: "Energy")
        case .workout: String(localized: "Workout")
        case .focus: String(localized: "Focus")
        case .chill: String(localized: "Chill")
        case .love: String(localized: "Love")
        case .drive: String(localized: "Drive")
        case .heartbreak: String(localized: "Heartbreak")
        case .party: String(localized: "Party")
        case .sleep: String(localized: "Sleep")
        }
    }

    /// One line on what the mood is for, under its name.
    var tagline: String {
        switch self {
        case .feelGood: String(localized: "Bright, easy songs to lift the day.")
        case .energy: String(localized: "Loud, fast and full of it.")
        case .workout: String(localized: "Hard-hitting songs to keep you moving.")
        case .focus: String(localized: "Calm, steady music to think to.")
        case .chill: String(localized: "Laid-back songs to slow down to.")
        case .love: String(localized: "For the one you can't stop thinking about.")
        case .drive: String(localized: "Windows down, and the long way home.")
        case .heartbreak: String(localized: "For when it hurts, and for getting over it.")
        case .party: String(localized: "Big songs for a full room.")
        case .sleep: String(localized: "Soft, quiet music to drift off to.")
        }
    }

    var symbol: String {
        switch self {
        case .feelGood: "sun.max.fill"
        case .energy: "bolt.fill"
        case .workout: "figure.run"
        case .focus: "scope"
        case .chill: "leaf.fill"
        case .love: "heart.fill"
        case .drive: "car.fill"
        case .heartbreak: "heart.slash.fill"
        case .party: "party.popper.fill"
        case .sleep: "moon.stars.fill"
        }
    }

    /// The mood's deepest colour, for type and tints over white.
    var color: Color { palette[0] }

    /// The mood's own colour, one no other mood shares, rich enough for white type.
    var base: Color {
        switch self {
        case .feelGood: Color(red: 0.93, green: 0.47, blue: 0.04)
        case .energy: Color(red: 0.92, green: 0.27, blue: 0.1)
        case .workout: Color(red: 0.84, green: 0.1, blue: 0.27)
        case .focus: Color(red: 0.16, green: 0.38, blue: 0.84)
        case .chill: Color(red: 0.05, green: 0.56, blue: 0.5)
        case .love: Color(red: 0.9, green: 0.2, blue: 0.46)
        case .drive: Color(red: 0.03, green: 0.47, blue: 0.72)
        case .heartbreak: Color(red: 0.45, green: 0.28, blue: 0.68)
        case .party: Color(red: 0.8, green: 0.14, blue: 0.62)
        case .sleep: Color(red: 0.15, green: 0.18, blue: 0.44)
        }
    }

    /// The mood's colour deep to light, for what needs a shade of it.
    var palette: [Color] { HueField.shades(of: base) }
}

/// A mood's field: its colour, lit a little from the top as Apple's tiles are.
struct MoodField: View {
    let mood: Mood

    var body: some View {
        HueField(color: mood.base)
    }
}

/// One colour, lit a little from the top as Apple's own tiles are: a mood's field, and
/// Handpicked's, each genre's and each party's.
struct HueField: View {
    let color: Color

    var body: some View {
        Rectangle().fill(color.gradient)
    }

    /// A colour deep to light: darker for type over white, lighter for a highlight.
    static func shades(of color: Color) -> [Color] {
        [color.mix(with: .black, by: 0.3), color, color.mix(with: .white, by: 0.25)]
    }
}

/// The colour behind a page's header, as a mood's, Handpicked's and each genre's have: its
/// field with its symbol large and faint in the corner, up under the bar and into any pull
/// past the top, melting into the page below the header's last button over a long, eased
/// fade, as a collection's header does, rather than stopping at a line.
struct HeroField: View {
    let color: Color
    let symbol: String

    var body: some View {
        HueField(color: color)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: symbol)
                    .font(.system(size: 220, weight: .bold))
                    .foregroundStyle(.white.opacity(0.1))
                    .rotationEffect(.degrees(-12))
                    .offset(x: 60, y: 10)
                    .accessibilityHidden(true)
            }
            .clipped()
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(
                        stops: Self.easedStops.map { .init(color: .black.opacity(1 - $0.opacity), location: $0.location) },
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: Self.fadeReach)
                }
            }
            .padding(.top, -400)
            .accessibilityHidden(true)
    }

    /// Below the header's last button, where the page shows through at last.
    static let fade: CGFloat = 40
    /// How far up the fade reaches: from behind the last button down, clear of the words
    /// above it.
    static let fadeReach: CGFloat = 150

    /// Smoothstep, so the fade has no start or end to see.
    private static let easedStops: [(opacity: Double, location: Double)] = (0...10).map { step in
        let t = Double(step) / 10
        return (opacity: t * t * (3 - 2 * t), location: t)
    }
}

extension View {
    /// The page's name in the bar once its header's big name has scrolled away under it, as
    /// Music's pages do. Put on the scroll view. The Mac's window title says it already.
    func heroTitle(_ title: String) -> some View {
        modifier(HeroTitle(title: title))
    }
}

private struct HeroTitle: ViewModifier {
    let title: String
    @State private var isShown = false
    @State private var isUnderBar = false

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > Self.threshold
            } action: { _, shown in
                withAnimation(.easeOut(duration: 0.2)) { isShown = shown }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .opacity(isShown ? 1 : 0)
                        .accessibilityHidden(!isShown)
                }
            }
        #else
        // The name in the bar once the big one has gone under it. Empty rather than removed
        // before then: a Mac window without a title drops the bar's material.
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > Self.threshold
            } action: { _, shown in
                isShown = shown
            }
            .navigationTitle(isShown ? title : "")
            // The field meets the top edge clean until the page scrolls under the bar.
            .toolbarBackgroundVisibility(isUnderBar ? .automatic : .hidden, for: .windowToolbar)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 8
            } action: { _, under in
                isUnderBar = under
            }
        #endif
    }

    /// About where the big name has gone under the bar.
    private static let threshold: CGFloat = 110
}

// MARK: - On Play

/// Find Your Mood, on Play: Handpicked, then every mood, in a row to scroll through.
struct MoodShelf: View {
    @ScaledMetric(relativeTo: .headline) private var height: CGFloat = Self.height

    var body: some View {
        let height = min(height, 130)
        Shelf(title: String(localized: "Find Your Mood"), items: MoodShelfItem.all) { EmptyView() } tile: { item in
            switch item {
            // Your own mood first: a station from songs you choose.
            case .handpicked: HandpickedTile(height: height)
            case .mood(let mood): MoodTile(mood: mood, height: height)
            }
        }
    }

    #if os(macOS)
    static let height: CGFloat = 96
    #else
    static let height: CGFloat = 86
    #endif
}

/// A tile on Find Your Mood.
enum MoodShelfItem: Identifiable {
    case handpicked
    case mood(Mood)

    var id: String {
        switch self {
        case .handpicked: "handpicked"
        case .mood(let mood): mood.rawValue
        }
    }

    static let all: [MoodShelfItem] = [.handpicked] + Mood.allCases.map(MoodShelfItem.mood)
}

/// A mood on the shelf: its page's field, its symbol large and faint in the corner, and its
/// name in its page's type, so the tile and the page read as one thing.
struct MoodTile: View {
    let mood: Mood
    let height: CGFloat
    /// Fills its grid cell's width, rather than the shelf's fixed shape.
    var fillsWidth = false

    var body: some View {
        let style = mood.style
        // Party opens its own page, for finding a party's playlist.
        NavigationLink(value: mood == .party ? PlayRoute.party : PlayRoute.mood(mood)) {
            ZStack(alignment: .bottomLeading) {
                RoomTileField(style: style)
                Image(systemName: mood.symbol)
                    .font(.system(size: height * 0.72, weight: .bold))
                    .foregroundStyle(.white.opacity(0.2))
                    .rotationEffect(.degrees(-12))
                    .offset(x: height * 0.2, y: height * 0.14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .accessibilityHidden(true)
                Text(mood.title)
                    .font(style.title.font(size: Self.nameSize))
                    .tracking(style.title.tracking * 0.5)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(12)
            }
            .frame(width: fillsWidth ? nil : height * 1.75, height: height)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .clipShape(.rect(cornerRadius: 16, style: .continuous))
            .contentShape(.rect(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(mood.title)
    }

    #if os(macOS)
    static let nameSize: CGFloat = 19
    #else
    static let nameSize: CGFloat = 20
    #endif
}

// MARK: - The mood's page

/// How much of a mood's flow is yours.
enum MoodFlow: String, CaseIterable, Identifiable {
    /// Only songs from your history.
    case yours
    /// Yours and new finds, the new ones for about a quarter.
    case both
    /// Only songs you've never played.
    case new

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .yours: "Your Songs"
        case .both: "Both"
        case .new: "New Music"
        }
    }

    /// What Play mixes, for the menu under it.
    var summary: LocalizedStringKey {
        switch self {
        case .yours: "Only Your Songs"
        case .both: "Your Songs and New Ones"
        case .new: "Only New Music"
        }
    }
}

/// What Apple Music has given a page so far.
enum CatalogReach: Equatable {
    case loading
    case found
    /// Tracks hasn't been given access to Apple Music.
    case notAuthorized
    /// Asked, and nothing came back: offline, most likely.
    case unreachable
}

/// A mood's page, built for the mood: its colours, type and covers, a section only it has,
/// your songs that suit it, new songs and artists for it, and Apple Music's playlists and
/// stations. Play goes with its flow, a live mix of your songs and new ones picked as it plays.
struct MoodView: View {
    let mood: Mood
    @Environment(AppModel.self) private var model
    @Environment(PlayerModel.self) private var player
    @Environment(PlayFeed.self) private var feed
    @Environment(\.openURL) private var openURL
    /// Nil until your songs that suit it are worked out.
    @State private var room: ListeningRoom?
    @State private var newSongs: [Suggestion] = []
    @State private var newArtists: [Artist] = []
    @State private var stations: [FeedItem] = []
    @State private var playlists: [FeedItem] = []
    @State private var reach = CatalogReach.loading
    @State private var flow = MoodFlow.both
    @AppStorage(SuggestionMode.storageKey) private var suggestionMode = SuggestionMode.everything
    @State private var showsAllYours = false
    @State private var showsAllNew = false
    @State private var showsAllSignature = false

    var body: some View {
        let style = mood.style
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero(style)
                VStack(alignment: .leading, spacing: style.pace.sectionSpacing) {
                    signature(style)
                    yourSongs(style)
                    newToYou(style)
                    artistsToDiscover
                    if !playlists.isEmpty {
                        Shelf(title: String(localized: "Playlists"), items: playlists) { FeedTile(item: $0) }
                    }
                    if !stations.isEmpty {
                        Shelf(title: String(localized: "Stations"), items: stations) { FeedTile(item: $0) }
                    }
                }
                .padding(.top, 12)
            }
            .padding(.bottom, 32)
        }
        .tint(style.ink)
        .heroTitle(mood.title)
        #if DEBUG
        .launchScroll()
        #endif
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .task(id: "\(newSongs.count).\(model.yourMusic.availabilityGeneration).\(suggestionMode.rawValue).\(newSongs.unanswered(in: model.yourMusic, source: model.musicSource))") {
            await newSongs.lookUp(in: model.yourMusic, source: model.musicSource, mode: suggestionMode, first: 12)
        }
    }

    // MARK: Hero

    private func hero(_ style: RoomStyle) -> some View {
        RoomHero(
            style: style,
            title: mood.title,
            tagline: mood.tagline,
            facts: room.flatMap(mood.facts(for:)),
            covers: heroCovers(style),
            isLoading: room == nil
        ) {
            VStack(alignment: .leading, spacing: 14) {
                RoomPlayButtons(
                    style: style,
                    playTitle: playTitle,
                    playSymbol: isOn && player.isPlaying ? "pause.fill" : "play.fill",
                    canPlay: canPlay,
                    shuffle: yours.isEmpty ? nil : { shuffleYours() } as () -> Void,
                    play: playOrPause
                ) {
                    if let session = mood.session {
                        RoomRoundMenu(title: session.title, symbol: session.symbol, isOn: player.sleepTimer != nil) {
                            sessionItems(session)
                        }
                    }
                }
                // Your own music has no new songs from Apple Music to mix in.
                if model.musicSource == .appleMusic {
                    flowMenu
                }
            }
            .frame(maxWidth: Self.controlsWidth, alignment: .leading)
        }
    }

    /// The covers of your songs that suit it; of new songs for it when you have none.
    private func heroCovers(_ style: RoomStyle) -> [CoverArt] {
        let count = CoverMosaic.count(for: style.covers)
        if let room, !room.isEmpty { return room.covers(count) }
        return newSongs.prefix(count).map { $0.song.artwork.map(CoverArt.artwork) ?? .url(nil, seed: $0.song.albumTitle ?? $0.song.title) }
    }

    @ViewBuilder
    private func sessionItems(_ session: MoodSession) -> some View {
        if player.sleepTimer != nil {
            Button("Turn Off Timer", systemImage: "xmark") { player.setSleepTimer(nil) }
            Divider()
        }
        ForEach(session.minutes, id: \.self) { minutes in
            Button(session.itemTitle(minutes)) { startSession(minutes: minutes) }
        }
    }

    /// The choice of what Play mixes, as a menu under it: a setting, so it stays small.
    private var flowMenu: some View {
        Menu {
            Picker("Play", selection: $flow) {
                ForEach(MoodFlow.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            // The chevron rides on the text's last line, so a long label wraps rather than
            // pushing the page wider than the screen.
            Text("\(Text(flow.summary)) \(Image(systemName: "chevron.up.chevron.down"))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.88))
                .multilineTextAlignment(.leading)
                .frame(minHeight: Self.menuHeight)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(Text("Mix"))
        .accessibilityValue(Text(flow.summary))
    }

    #if os(macOS)
    private static let controlsWidth: CGFloat = 520
    private static let menuHeight: CGFloat = 22
    #else
    private static let controlsWidth: CGFloat = .infinity
    private static let menuHeight: CGFloat = 32
    #endif

    /// The mood's flow is on, playing or paused.
    private var isOn: Bool {
        player.hasQueue && player.context == PlayContext(kind: .endless, title: mood.title)
    }

    private var playTitle: LocalizedStringKey {
        guard isOn else { return "Play" }
        return player.isPlaying ? "Pause" : "Resume"
    }

    private var yours: [ListeningRoom.Song] { room?.songs ?? [] }

    private var canPlay: Bool {
        guard room != nil, reach != .loading else { return true }
        switch flow {
        case .yours: return !yours.isEmpty
        case .new: return !newSongs.isEmpty || !stations.isEmpty
        case .both: return !yours.isEmpty || !newSongs.isEmpty || !stations.isEmpty
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func signature(_ style: RoomStyle) -> some View {
        let signature = mood.signature
        if let room, case let songs = signature.songs(room), !songs.isEmpty {
            let shown = Array(songs.prefix(showsAllSignature ? songs.count : style.pace.rows))
            VStack(alignment: .leading, spacing: 0) {
                RoomSectionHeader(title: signature.title, note: signature.note) {
                    RoomSectionAction(title: "Play", symbol: "play.fill", ink: style.ink) {
                        play(songs, title: signature.title, shuffled: false)
                    }
                }
                RoomColumns(items: shown, ruleInset: signature.isSequence ? RoomSongRow.numberedTextInset : RoomSongRow.textInset) { song in
                    historyRow(song, number: signature.isSequence ? (songs.firstIndex(of: song) ?? 0) + 1 : nil, detail: signature.detail(song)) {
                        play(songs, startingAt: song, title: signature.title)
                    }
                }
                if songs.count > style.pace.rows {
                    RoomShowMore(isShowingAll: $showsAllSignature, ink: style.ink)
                }
            }
            .padding(.horizontal, PlayMetrics.margin)
        }
    }

    @ViewBuilder
    private func yourSongs(_ style: RoomStyle) -> some View {
        let title = String(localized: "Your \(mood.title) Songs")
        VStack(alignment: .leading, spacing: 0) {
            RoomSectionHeader(title: title)
            if let room {
                if room.isEmpty {
                    RoomNote(
                        text: String(localized: "None of your songs suit \(mood.title) yet. Tracks goes by each song's genre, so they'll gather here as you play."),
                        symbol: mood.symbol
                    )
                } else {
                    let songs = room.songs
                    let shown = Array(songs.prefix(showsAllYours ? 25 : style.pace.rows))
                    RoomColumns(items: shown) { song in
                        historyRow(song, detail: PlayCountText.short(song.plays)) {
                            play(startingWith: song.song, flow: .yours)
                        }
                    }
                    if songs.count > style.pace.rows {
                        RoomShowMore(isShowingAll: $showsAllYours, ink: style.ink)
                    }
                }
            } else {
                LoadingRows(count: style.pace.rows)
            }
        }
        .padding(.horizontal, PlayMetrics.margin)
    }

    private func historyRow(_ song: ListeningRoom.Song, number: Int? = nil, detail: String?, play: @escaping () -> Void) -> some View {
        let canPlay = player.canPlay(songID: song.song.songID)
        return Button(action: play) {
            RoomSongRow(
                title: song.song.title,
                artist: song.song.artistName,
                cover: song.cover,
                number: number,
                detail: detail,
                isCurrent: player.current?.songIdentity == song.song.songIdentity,
                isPlayable: canPlay
            )
        }
        .buttonStyle(.plain)
        .disabled(!canPlay)
        .contextMenu { HistorySongMenu(song: song.song) }
    }

    @ViewBuilder
    private func newToYou(_ style: RoomStyle) -> some View {
        let visible = newSongs.visible(in: model.yourMusic, source: model.musicSource, mode: suggestionMode)
        VStack(alignment: .leading, spacing: 0) {
            RoomSectionHeader(title: String(localized: "New to You")) {
                if !newSongs.isEmpty {
                    FindMoreLink(route: .songFinder(.mood(mood)))
                }
            }
            switch reach {
            case .loading:
                LoadingRows(count: style.pace.rows)
            case .notAuthorized:
                RoomNote(
                    text: String(localized: "Connect Apple Music for new songs, playlists and stations for \(mood.title)."),
                    symbol: "music.note",
                    action: model.musicAuthorization == .denied
                        ? RoomNoteAction(title: "Open Settings", run: openMusicSettings)
                        : RoomNoteAction(title: "Connect Apple Music", run: connectAppleMusic)
                )
            case .unreachable:
                RoomNote(
                    text: String(localized: "Couldn't reach Apple Music. New songs and playlists for \(mood.title) will be here when it's back."),
                    symbol: "wifi.slash",
                    action: RoomNoteAction(title: "Try Again", run: retryCatalog)
                )
            case .found:
                if newSongs.isEmpty {
                    RoomNote(text: String(localized: "Nothing new for \(mood.title) right now. You've heard everything Apple Music suggests for it."))
                } else {
                    let shown = Array(visible.prefix(showsAllNew ? 25 : style.pace.rows))
                    if shown.isEmpty, newSongs.unanswered(in: model.yourMusic, source: model.musicSource) > 0 {
                        LoadingRows(count: 3)
                    }
                    RoomColumns(items: shown) { suggestion in
                        SuggestionRow(suggestion: suggestion, showsReason: false) {
                            let all = newSongs.map(\.song)
                            player.play(.songs(all, startingAt: all.firstIndex(of: suggestion.song) ?? 0), from: .songs(mood.title))
                        }
                        .contextMenu { SuggestionMenu(suggestion: suggestion) }
                    }
                    if visible.count > style.pace.rows {
                        RoomShowMore(isShowingAll: $showsAllNew, ink: style.ink)
                    }
                }
            }
        }
        .padding(.horizontal, PlayMetrics.margin)
    }

    @ViewBuilder
    private var artistsToDiscover: some View {
        if !newArtists.isEmpty {
            Shelf(title: String(localized: "Artists to Discover"), items: newArtists) { artist in
                NavigationLink(value: PlayRoute.artist(artist)) {
                    ArtistCircleTile(
                        name: artist.name,
                        picture: artist.artwork.map(CoverArt.artwork),
                        detail: nil
                    )
                }
                .buttonStyle(.pressable)
            }
        }
    }

    // MARK: Playing

    private func playOrPause() {
        if isOn {
            player.togglePlayPause()
        } else {
            play(startingWith: nil)
        }
    }

    private func play(startingWith first: MixSong?, flow: MoodFlow? = nil) {
        let flow = flow ?? self.flow
        let found = reach == .found ? MoodCatalog.Found(stations: stations, playlists: playlists, newSongs: newSongs.map(\.song)) : nil
        Task {
            await MoodPlayback.start(mood, model: model, flow: flow, found: found, startingWith: first)
        }
    }

    /// Your songs that suit it, in a fresh order.
    private func shuffleYours() {
        play(yours, title: String(localized: "Your \(mood.title) Songs"), shuffled: true)
    }

    private func play(_ songs: [ListeningRoom.Song], startingAt first: ListeningRoom.Song? = nil, title: String, shuffled: Bool = false) {
        let playable = songs.filter { player.canPlay(songID: $0.song.songID) }
        let start = first.flatMap { playable.firstIndex(of: $0) } ?? 0
        player.play(.history(playable.map { HistorySong($0.song) }, startingAt: start), from: .songs(title), shuffled: shuffled)
    }

    /// Plays for a while, then stops: the player's sleep timer, set for the session.
    private func startSession(minutes: Int) {
        player.setSleepTimer(.at(.now.addingTimeInterval(TimeInterval(minutes * 60))))
        if !isOn { play(startingWith: nil) }
    }

    private func connectAppleMusic() {
        Task {
            await model.requestMusicAccess()
            await loadCatalog()
        }
    }

    private func openMusicSettings() {
        if let url = SystemSettingsLink.musicAccess { openURL(url) }
    }

    private func retryCatalog() {
        reach = .loading
        Task { await loadCatalog() }
    }

    // MARK: Loading

    private func load() async {
        // Once per visit: coming back from an artist or an album shouldn't search again. A
        // search left unfinished, or that couldn't reach Apple Music, is tried again.
        if room == nil {
            let (history, signals, drives, mood) = (model.library.history, player.signals, player.drive.log, mood)
            let room = await OffMainActor.run { ListeningRoom.mood(mood, in: history, signals: signals, drives: drives) }
            self.room = room
            if room.isEmpty { flow = .new }
        }
        guard reach != .found else { return }
        await loadCatalog()
    }

    private func loadCatalog() async {
        guard player.isDemo || model.musicAuthorization == .authorized else {
            reach = .notAuthorized
            return
        }
        let found = await MoodCatalog.find(mood, isDemo: player.isDemo)
        // Left part way: what came back is cut short, not Apple Music being out of reach.
        guard !Task.isCancelled else { return }
        stations = found.stations
        playlists = found.playlists
        newSongs = fresh(found.newSongs)
        reach = found.stations.isEmpty && found.playlists.isEmpty && found.newSongs.isEmpty && !player.isDemo ? .unreachable : .found
        let artists = await MoodCatalog.artists(of: newSongs.map(\.song), leavingOut: feed.heardArtists, isDemo: player.isDemo)
        guard !Task.isCancelled else { return }
        newArtists = artists
    }

    /// Songs never played, the version the explicit setting allows, no artist twice in a row.
    private func fresh(_ songs: [Song]) -> [Suggestion] {
        var seen = Set<String>()
        let unheard = PlayPreferences.versions(of: songs).filter { song in
            let identity = HistoryImport.key(title: song.title, artistName: song.artistName)
            return feed.facts[identity] == nil && !player.signals.excludes(identity, now: .now) && seen.insert(identity).inserted
        }
        return FreshShuffle.order(
            unheard.map { Suggestion(song: $0, reason: .mood(mood)) },
            artist: { StatsCalculator.folded($0.song.artistName) },
            seed: FreshShuffle.dailySeed(for: .now, salt: "mood.new.\(mood.rawValue)")
        )
    }
}

// MARK: - Apple Music for a mood

/// Apple Music's stations and playlists for a mood, found by searching for it, and the songs
/// on its playlists. Apple's own playlists come first.
enum MoodCatalog {
    struct Found {
        var stations: [FeedItem]
        var playlists: [FeedItem]
        /// The songs on its first few playlists.
        var newSongs: [Song]

        static let empty = Found(stations: [], playlists: [], newSongs: [])
    }

    /// Everything Apple Music has for the mood.
    static func find(_ mood: Mood, isDemo: Bool) async -> Found {
        #if DEBUG
        if isDemo {
            let offset = 1_100 + (Mood.allCases.firstIndex(of: mood) ?? 0) * 40
            return Found(stations: [], playlists: [], newSongs: DemoCatalog.songs(count: 24, offset: offset, artists: nil))
        }
        #endif
        guard !isDemo, MusicAuthorization.currentStatus == .authorized else { return .empty }
        let items = await items(for: mood)
        let playlists = items.playlists.compactMap { item -> Playlist? in
            if case .playlist(let playlist) = item.content { playlist } else { nil }
        }
        let songs = await songs(in: playlists, allowsExplicit: PlayPreferences.allowsExplicit)
        return Found(stations: items.stations, playlists: items.playlists, newSongs: songs)
    }

    @concurrent
    nonisolated static func items(for mood: Mood) async -> (stations: [FeedItem], playlists: [FeedItem]) {
        var request = MusicCatalogSearchRequest(term: mood.searchTerm, types: [MusicKit.Station.self, Playlist.self])
        request.limit = 15
        guard let response = try? await request.response() else { return ([], []) }
        let playlists = response.playlists.sorted { lhs, rhs in
            let (left, right) = (lhs.curatorName?.contains("Apple Music") == true, rhs.curatorName?.contains("Apple Music") == true)
            return left && !right
        }
        return (
            await MainActor.run { response.stations.prefix(4).map { FeedItem(station: $0) } },
            await MainActor.run { playlists.prefix(12).map { FeedItem(playlist: $0) } }
        )
    }

    /// The songs on a mood's first few playlists, as new finds.
    @concurrent
    nonisolated static func songs(in playlists: [Playlist], allowsExplicit: Bool) async -> [Song] {
        await withTaskGroup(of: (Int, [Song]).self) { group in
            for (index, playlist) in playlists.prefix(3).enumerated() {
                group.addTask {
                    guard let tracks = try? await playlist.with([.tracks]).tracks else { return (index, []) }
                    return (index, tracks.prefix(100).compactMap { track in
                        guard case .song(let song) = track else { return nil }
                        return song
                    })
                }
            }
            var byIndex: [Int: [Song]] = [:]
            for await (index, songs) in group { byIndex[index] = songs }
            return byIndex.keys.sorted()
                .flatMap { byIndex[$0] ?? [] }
                .filter { allowsExplicit || $0.contentRating != .explicit }
        }
    }

    /// The artists behind a mood's new songs that you've never played, each once.
    static func artists(of songs: [Song], leavingOut heard: Set<String>, isDemo: Bool) async -> [Artist] {
        #if DEBUG
        if isDemo { return DemoCatalog.artists(count: 8, offset: songs.count % 7) }
        #endif
        guard !isDemo else { return [] }
        var names = Set<String>()
        let wanted = songs.filter { song in
            let key = StatsCalculator.folded(song.artistName)
            return !heard.contains(key) && names.insert(key).inserted
        }
        return await lookUpArtists(of: Array(wanted.prefix(10)))
    }

    @concurrent
    nonisolated private static func lookUpArtists(of songs: [Song]) async -> [Artist] {
        await withTaskGroup(of: (Int, Artist?).self) { group in
            for (index, song) in songs.enumerated() {
                group.addTask {
                    let artist: Artist? = if let known = song.artists?.first { known } else { try? await song.with([.artists]).artists?.first }
                    return (index, artist)
                }
            }
            var byIndex: [Int: Artist] = [:]
            for await (index, artist) in group { byIndex[index] = artist }
            var seen = Set<MusicItemID>()
            return byIndex.keys.sorted().compactMap { byIndex[$0] }.filter { seen.insert($0.id).inserted }
        }
    }
}

/// Starting a mood, from its page, CarPlay or Siri. It plays live, each song picked as the one
/// before starts, from your songs that suit it and new finds from Apple Music's playlists for
/// it. Where there's neither, it plays Apple Music's station for the mood.
@MainActor
enum MoodPlayback {
    /// - Parameters:
    ///   - flow: how much of it is yours.
    ///   - found: what Apple Music has for the mood, where it's already loaded; looked up
    ///     otherwise.
    ///   - first: a song to start with, as when one is tapped on the mood's page.
    static func start(
        _ mood: Mood,
        model: AppModel,
        flow: MoodFlow = .both,
        found: MoodCatalog.Found? = nil,
        startingWith first: MixSong? = nil
    ) async {
        let player = model.player
        let isDemo = player.isDemo
        if model.musicSource == .yourMusic {
            let (tracks, history, signals) = (model.yourMusic.playableTracks, model.library.history, player.signals)
            let mix = await OffMainActor.run {
                LiveMix.mood(mood, from: tracks, history: history, signals: signals, seed: .random(in: 0...UInt64.max))
            }
            guard !mix.isEmpty else {
                player.problem = .failed(String(localized: "None of your music suits \(mood.title) yet. Tracks goes by each song's genre."))
                return
            }
            await player.startLive(mix, from: PlayContext(kind: .endless, title: mood.title), startingWith: first)
            return
        }
        let catalog = if let found { found } else { await MoodCatalog.find(mood, isDemo: isDemo) }
        let newFinds = flow == .yours ? [] : catalog.newSongs.map(MixSong.init(catalog:))
        let history = flow == .new ? ListeningHistory([]) : model.library.history
        let signals = player.signals
        let mix = await OffMainActor.run {
            LiveMix.mood(mood, from: history, signals: signals, newFinds: newFinds, seed: .random(in: 0...UInt64.max))
                .playable(isDemo: isDemo)
        }

        let context = PlayContext(kind: .endless, title: mood.title)
        if !mix.isEmpty {
            await player.startLive(mix, from: context, startingWith: first)
        } else if let (request, context) = catalog.stations.first?.stationRequest {
            await player.start(request, from: context)
        } else {
            player.problem = .failed(String(localized: "Nothing to play for \(mood.title) yet."))
        }
    }
}
