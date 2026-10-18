import Foundation
import MusicKit
import TracksCore

/// Tracks Radio's songs: everything in the history, and for its new finds the songs Tracks
/// suggests, as tuned in its settings, and fitted to the hour and the road.
@MainActor
enum TracksRadioSource {
    /// Made once, as the app starts: it also keeps the tuner's genres ready and starts noticing
    /// drives where that's already allowed.
    static func make(library: Library, discovery: Discovery, yourMusic: YourMusic, player: PlayerModel) -> () async -> LiveMix {
        followGenres(library: library, player: player)
        player.drive.onChange = { [weak player] in
            // Only the radio that notices driving plays differently for the road.
            guard PlayPreferences.radioNoticesDriving else { return }
            Task { await player?.retuneTracksRadio() }
        }
        if PlayPreferences.noticesDriving { player.drive.resumeIfAllowed() }

        return { [weak library, weak discovery, weak yourMusic, weak player] in
            guard let library, let discovery, let yourMusic, let player else { return LiveMix(candidates: [], seed: 0) }
            // The radio starting is when Motion & Fitness is first asked for.
            if PlayPreferences.radioNoticesDriving { player.drive.start() }
            let (history, signals, isDemo, tuning) = (library.history, player.signals, player.isDemo, PlayPreferences.radioTuning)
            let (moment, drives) = (moment(drive: player.drive), player.drive.log)
            // From your own music: every song, and as new finds, the songs you've never played
            // and the ones your servers picked for you that you don't have yet. All of them,
            // not only what plays now: the player picks from what it can reach as it goes, so a
            // radio started offline has everything back once the network is.
            if MusicSource.current == .yourMusic {
                // Only Music I Have keeps it to what's in your music.
                let finds = SuggestionMode.current == .onlyYours ? [] : yourMusic.serverFinds
                let tracks = yourMusic.index.tracks + finds
                return await OffMainActor.run {
                    LiveMix.tracksRadio(
                        from: tracks, history: history, signals: signals, tuning: tuning,
                        moment: moment, drives: drives, seed: .random(in: 0...UInt64.max)
                    )
                }
            }
            let newFinds = discovery.newFinds.map(MixSong.init(catalog:))
            let reasons = discovery.newFindReasons
            return await OffMainActor.run {
                LiveMix.tracksRadio(
                    from: history, signals: signals, newFinds: newFinds, newFindReasons: reasons, tuning: tuning,
                    moment: moment, drives: drives, seed: .random(in: 0...UInt64.max)
                )
                .playable(isDemo: isDemo)
            }
        }
    }

    /// The moment Tracks Radio plays for now, as its settings allow: the hour and the feel set
    /// for it when it follows the time of day, and the road when it notices driving and you are.
    static func moment(drive: DriveDetector, at date: Date = .now) -> RadioMoment {
        RadioMoment(
            at: date,
            followsTime: PlayPreferences.radioFollowsTime,
            day: PlayPreferences.radioDay,
            isDriving: PlayPreferences.radioNoticesDriving && drive.isDriving
        )
    }

    /// What has landed on Tracks Radio at each part of the day and on drives, kept on this
    /// device so the next listen starts from it. Genre families, decades and counts only.
    static var habits: RadioHabits {
        RadioHabits(stored: UserDefaults.standard.string(forKey: habitsKey) ?? "")
    }

    static func keep(_ habits: RadioHabits) {
        UserDefaults.standard.set(habits.stored, forKey: habitsKey)
    }

    static let habitsKey = "tracksRadioHabits"

    /// Keeps the genres the tuner offers ready from launch, and fresh as the history changes,
    /// so the tuner opens with them in place.
    private static func followGenres(library: Library, player: PlayerModel) {
        Task { [weak player] in
            let inputs = Observations { GenreInputs(revision: library.revision, isLoaded: library.isLoaded) }
            for await input in inputs where input.isLoaded {
                let history = library.history
                let genres = await OffMainActor.run { RadioTuning.genreChoices(in: history) }
                guard let player else { return }
                if player.radioGenres != genres { player.radioGenres = genres }
            }
        }
    }

    private struct GenreInputs: Equatable, Sendable {
        let revision: Int
        let isLoaded: Bool
    }
}

extension MixSong {
    /// A song from Apple Music as a live mix's new find: never played, so no count.
    nonisolated init(catalog song: Song) {
        self.init(
            songIdentity: HistoryImport.key(title: song.title, artistName: song.artistName),
            songID: song.id.rawValue,
            title: song.title,
            artistName: song.artistName,
            albumTitle: song.albumTitle,
            artworkURL: song.artwork?.url(width: 600, height: 600)?.absoluteString,
            plays: 0,
            lastHeard: .distantPast,
            genre: song.genreNames.first { $0 != "Music" }
        )
    }
}

extension LiveMix {
    /// Only songs the player can find: ones with a catalog id, or all of them with sample data.
    nonisolated func playable(isDemo: Bool) -> LiveMix {
        guard !isDemo else { return self }
        var mix = LiveMix(candidates: candidates.filter { !$0.song.songID.isEmpty }, newShare: newShare, moment: moment, seed: .random(in: 0...UInt64.max))
        mix.taste = taste
        return mix
    }
}
