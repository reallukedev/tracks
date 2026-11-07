import SwiftUI
import TracksCore

/// A mood with your own music: go with its flow, a live mix of your songs that suit it and new
/// ones your server finds like them, or look through them, yours and new woven together. Asks
/// nothing of Apple Music.
struct YourMusicMoodView: View {
    let mood: Mood
    @Environment(AppModel.self) private var model
    @Environment(YourMusic.self) private var music
    @Environment(PlayerModel.self) private var player
    @Environment(PlayFeed.self) private var feed
    @AppStorage(SuggestionMode.storageKey) private var suggestionMode = SuggestionMode.everything
    /// Your songs that suit the mood, the ones you play most first.
    @State private var yours: [LocalTrack] = []
    @State private var hasLoaded = false
    @State private var showsAll = false

    var body: some View {
        let finds = newFinds
        let songs = ServerMix.blend(owned: yours, new: finds)
        let isFinding = suggestionMode == .everything && !music.servers.onlineServers.isEmpty && music.discover.moodFinds[mood] == nil
        ScrollView {
            LazyVStack(alignment: .leading, spacing: mood.style.pace.sectionSpacing) {
                hero(canPlay: !songs.isEmpty, hasFinds: !finds.isEmpty)
                list(songs, isFinding: isFinding || !hasLoaded)
                if hasLoaded, songs.isEmpty, !isFinding {
                    ContentUnavailableView(
                        "Nothing for \(mood.title) Yet",
                        systemImage: mood.symbol,
                        description: Text(emptyNote)
                    )
                }
            }
            .padding(.bottom, 24)
            .animation(.snappy, value: songs.count)
        }
        .tint(mood.style.ink)
        .heroTitle(mood.title)
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
    }

    /// New songs your server found for the mood, unless suggestions keep to your own music.
    private var newFinds: [LocalTrack] {
        guard suggestionMode == .everything else { return [] }
        return (music.discover.moodFinds[mood]?.songs ?? []).filter { !music.isInYourMusic($0) }
    }

    private var emptyNote: LocalizedStringKey {
        music.servers.onlineServers.isEmpty
            ? "None of your music suits it yet. Tracks goes by each song's genre."
            : "None of your music suits it yet, and your server found nothing like it. Tracks goes by each song's genre, and your server by songs like the ones you play."
    }

    // MARK: Hero

    private func hero(canPlay: Bool, hasFinds: Bool) -> some View {
        let style = mood.style
        return RoomHero(
            style: style,
            title: mood.title,
            tagline: mood.tagline,
            facts: yours.isEmpty ? nil : String(AttributedString(localized: "^[\(yours.count) song](inflect: true) in your music").characters),
            covers: heroCovers(style),
            isLoading: !hasLoaded
        ) {
            VStack(alignment: .leading, spacing: 12) {
                RoomPlayButtons(
                    style: style,
                    playTitle: isOn ? (player.isPlaying ? "Pause" : "Resume") : "Play",
                    playSymbol: isOn && player.isPlaying ? "pause.fill" : "play.fill",
                    canPlay: canPlay,
                    shuffle: yours.isEmpty ? nil : { player.play(.local(yours), from: .songs(mood.title), shuffled: true) },
                    play: { isOn ? player.togglePlayPause() : play(startingWith: nil) }
                ) {
                    if let session = mood.session {
                        RoomRoundMenu(title: session.title, symbol: session.symbol, isOn: player.sleepTimer != nil) {
                            if player.sleepTimer != nil {
                                Button("Turn Off Timer", systemImage: "xmark") { player.setSleepTimer(nil) }
                                Divider()
                            }
                            ForEach(session.minutes, id: \.self) { minutes in
                                Button(session.itemTitle(minutes)) {
                                    player.setSleepTimer(.at(.now.addingTimeInterval(TimeInterval(minutes * 60))))
                                    if !isOn { play(startingWith: nil) }
                                }
                            }
                        }
                    }
                }
                // What Play does, under it: with new finds, it mixes them in.
                Text(hasFinds
                    ? "Your songs that suit it and new ones like them, picked as it plays."
                    : "Your songs that suit it, picked as it plays.")
                    .font(.footnote)
                    .opacity(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
        }
    }

    /// The mood's flow is on, playing or paused.
    private var isOn: Bool {
        player.hasQueue && player.context == PlayContext(kind: .endless, title: mood.title)
    }

    /// Your songs' covers, one per album, in the mood's arrangement.
    private func heroCovers(_ style: RoomStyle) -> [CoverArt] {
        var seen = Set<String>()
        var covers: [CoverArt] = []
        for track in yours where covers.count < CoverMosaic.count(for: style.covers) {
            if seen.insert(track.album ?? track.id).inserted {
                covers.append(.url(music.artworkURL(track.artwork)?.absoluteString, seed: track.album ?? track.title))
            }
        }
        return covers
    }

    // MARK: Songs

    @ViewBuilder
    private func list(_ songs: [LocalTrack], isFinding: Bool) -> some View {
        if !songs.isEmpty || isFinding {
            let shown = showsAll ? songs : Array(songs.prefix(10))
            VStack(alignment: .leading, spacing: 4) {
                ShelfHeader(title: String(localized: "Songs for \(mood.title)")) { EmptyView() }
                ForEach(shown) { track in
                    HStack(spacing: 4) {
                        Button {
                            play(startingWith: track)
                        } label: {
                            LocalTrackRow(track: track, isCurrent: player.current?.local?.id == track.id)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        if track.isFromServer, !music.isInYourMusic(track) {
                            AddFoundSongButton(track: track)
                        }
                    }
                    .contextMenu { LocalTrackMenu(track: track) }
                    if track.id != shown.last?.id { Divider().padding(.leading, 60) }
                }
                if isFinding {
                    // New songs for it are still being found: they join as they come.
                    LoadingRows(count: songs.isEmpty ? 6 : 2)
                }
                if songs.count > 10 {
                    Button {
                        withAnimation(.snappy) { showsAll.toggle() }
                    } label: {
                        Text(showsAll ? "Show Less" : "Show More")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, PlayMetrics.margin)
        }
    }

    // MARK: Playing and loading

    /// Goes with the flow: a live mix of your songs that suit it and the new ones found, from
    /// a tapped song if there is one.
    private func play(startingWith first: LocalTrack?) {
        let (tracks, finds, history, signals, mood) = (music.playableTracks, newFinds, model.library.history, player.signals, mood)
        Task {
            let mix = await OffMainActor.run {
                LiveMix.mood(mood, from: tracks, finds: finds, history: history, signals: signals, seed: .random(in: 0...UInt64.max))
            }
            await player.startLive(mix, from: PlayContext(kind: .endless, title: mood.title), startingWith: first?.mixSong())
        }
    }

    private func load() async {
        // Once per visit: coming back from an album shouldn't look again.
        guard !hasLoaded else { return }
        let (tracks, history, signals, mood) = (music.playableTracks, model.library.history, player.signals, mood)
        let mix = await OffMainActor.run { LiveMix.mood(mood, from: tracks, history: history, signals: signals, seed: 1) }
        // The ones you play most first; the rest in a fresh order each day, artists spread
        // out, rather than by name.
        let candidates = mix.candidates.compactMap { candidate in music.index.track(id: candidate.song.songID).map { (track: $0, plays: candidate.song.plays) } }
        let mostPlayed = candidates.filter { $0.plays > 0 }.sorted { $0.plays > $1.plays }.map(\.track)
        let unplayed = FreshShuffle.order(
            candidates.filter { $0.plays == 0 }.map(\.track),
            artist: \.artistKey,
            seed: FreshShuffle.dailySeed(for: .now, salt: "mood-\(mood.rawValue)")
        )
        yours = mostPlayed + unplayed
        hasLoaded = true
        guard suggestionMode == .everything else { return }
        // Songs that suit it to find more like: yours you play most, then ones you've played
        // elsewhere, from your history.
        let played = await OffMainActor.run { MoodMix.songs(for: mood, in: history, signals: signals) }
        let seeds = yours.prefix(3).map { (title: $0.title, artist: $0.artist) }
            + played.prefix(3).map { (title: $0.title, artist: $0.artistName) }
        await music.discover.loadFinds(for: mood, seeds: seeds, heard: { [player] in feed.facts[$0] != nil || player.signals.excludes($0) })
    }
}
