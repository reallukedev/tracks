import SwiftUI
import TracksCore

/// Plays songs from a chart where the app plays songs: in Tracks’ own player, or handed to
/// Apple Music when Settings sends them there.
struct ChartPlayback: DynamicProperty {
    @Environment(\.playSongs) private var playSongs
    @Environment(PlaybackController.self) private var playback
    @Environment(PlayerModel.self) private var player
    @Environment(AppModel.self) private var model

    /// The songs that can be played: Tracks’ player knows sample songs by name, Apple Music
    /// needs a song the catalog identified.
    func playable(_ songs: [MixSong]) -> [MixSong] {
        if playSongs != nil {
            return songs.filter { player.canPlay(songID: $0.songID) }
        }
        return model.isShowingSampleData ? [] : songs.filter { !$0.songID.isEmpty }
    }

    func play(_ songs: [MixSong], shuffled: Bool = false, title: String) {
        let items = playable(songs).map {
            PlaybackItem(songID: $0.songID, title: $0.title, artistName: $0.artistName)
        }
        guard !items.isEmpty else { return }
        let ordered = shuffled ? items.shuffled() : items
        if let playSongs {
            playSongs(ordered, title: title)
        } else {
            Task { await playback.play(ordered) }
        }
    }

    /// Play Next and Play Last, which only Tracks’ player has.
    var canQueue: Bool { playSongs != nil }

    func enqueue(_ song: MixSong, next: Bool) {
        player.enqueue(.history([HistorySong(song)]), next: next, title: song.title)
    }
}

/// A chart entry's menu: a song's own menu, with Play first; an artist's or album's stats.
struct ChartEntryMenu: View {
    let entry: ChartEntry
    /// Your Stats, where a click doesn't already open them.
    var openStats: (() -> Void)?

    init(entry: ChartEntry, openStats: (() -> Void)? = nil) {
        self.entry = entry
        self.openStats = openStats
    }

    var body: some View {
        if let song = entry.song {
            ChartSongMenu(song: song, openStats: openStats)
        } else if let openStats {
            Button("Your Stats", systemImage: "chart.bar.xaxis", action: openStats)
        }
    }
}

/// A charted song's menu: played the way charts play, with Go to Album, each of its artists, and your stats.
struct ChartSongMenu: View {
    let song: MixSong
    /// Your Stats, where a click doesn't already open them.
    var openStats: (() -> Void)?
    private var playback = ChartPlayback()
    @Environment(PlayerModel.self) private var player
    @Environment(\.openPlayRoute) private var openPlayRoute

    init(song: MixSong, openStats: (() -> Void)? = nil) {
        self.song = song
        self.openStats = openStats
    }

    var body: some View {
        SongMenuItems(actions(for: song))
    }

    private func actions(for song: MixSong) -> SongActions {
        let canPlay = !playback.playable([song]).isEmpty
        var actions = SongActions.history(song, player: player, go: openPlayRoute.ifPushes)
        actions.play = canPlay ? { playback.play([song], title: song.title) } : nil
        if !canPlay || !playback.canQueue {
            actions.playNext = nil
            actions.playLast = nil
        }
        if let openStats { actions.stats = openStats }
        return actions
    }
}
