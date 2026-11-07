import Foundation
import MusicKit
import TracksCore

/// Autoplay's songs: from the history, songs like the last few the queue played, and from Apple
/// Music, as new finds, the top songs of the artists Apple lists as similar to theirs. From your
/// own music, your songs and the ones your servers found for you.
@MainActor
enum AutoplaySource {
    static func make(library: Library, yourMusic: YourMusic, player: PlayerModel) -> ([PlayerTrack]) async -> LiveMix {
        { [weak library, weak yourMusic, weak player] tracks in
            guard let library, let yourMusic, let player else { return LiveMix(candidates: [], seed: 0) }
            let seeds = tracks.map(AutoplaySeed.init)
            let (history, signals, isDemo) = (library.history, player.signals, player.isDemo)
            if MusicSource.current == .yourMusic {
                let finds = SuggestionMode.current == .onlyYours ? [] : yourMusic.serverFinds.filter(yourMusic.isPlayable)
                let tracks = yourMusic.playableTracks + finds
                return await OffMainActor.run {
                    LiveMix.autoplay(after: seeds, from: tracks, history: history, signals: signals, seed: .random(in: 0...UInt64.max))
                }
            }
            let songs = tracks.compactMap(\.song)
            let newFinds = isDemo || MusicAuthorization.currentStatus != .authorized ? [] : await similar(to: songs)
            return await OffMainActor.run {
                LiveMix.autoplay(after: seeds, from: history, signals: signals, newFinds: newFinds, seed: .random(in: 0...UInt64.max))
                    .playable(isDemo: isDemo)
            }
        }
    }

    /// The top songs of the artists Apple Music calls similar to the seeds' most recent two, and
    /// a few of those artists' own, as the explicit setting allows. Whatever's back within a few
    /// seconds: Autoplay mustn't keep the last song waiting.
    static func similar(to songs: [Song]) async -> [MixSong] {
        let allowsExplicit = PlayPreferences.allowsExplicit
        // Not a task group, which would wait out a lookup that doesn't stop when cancelled.
        let found = await TimeLimit.value(within: .seconds(4)) { await lookUpSimilar(to: songs) } ?? []
        return PlayPreferences.versions(of: found, allowsExplicit: allowsExplicit).map(MixSong.init(catalog:))
    }

    @concurrent
    nonisolated private static func lookUpSimilar(to songs: [Song]) async -> [Song] {
        var seen = Set<MusicItemID>()
        let artists: [Artist] = await withTaskGroup(of: Artist?.self) { group in
            for song in songs.suffix(4) {
                group.addTask { try? await song.with([.artists]).artists?.first }
            }
            var found: [Artist] = []
            for await artist in group {
                if let artist, seen.insert(artist.id).inserted { found.append(artist) }
            }
            return Array(found.prefix(2))
        }
        return await withTaskGroup(of: [Song].self) { group in
            for artist in artists {
                group.addTask {
                    guard let detailed = try? await artist.with([.similarArtists, .topSongs]) else { return [] }
                    let own = Array(detailed.topSongs?.prefix(4) ?? [])
                    let similar = Array(detailed.similarArtists?.prefix(5) ?? [])
                    let theirs = await withTaskGroup(of: [Song].self) { inner in
                        for other in similar {
                            inner.addTask { Array((try? await other.with([.topSongs]).topSongs)?.prefix(5) ?? []) }
                        }
                        var songs: [Song] = []
                        for await top in inner { songs += top }
                        return songs
                    }
                    return own + theirs
                }
            }
            var all: [Song] = []
            for await songs in group { all += songs }
            return all
        }
    }
}

extension AutoplaySeed {
    /// A song the queue played, with what the player knows of its genre and year.
    init(_ track: PlayerTrack) {
        let year = track.song?.releaseDate.map { Calendar.current.component(.year, from: $0) } ?? track.local?.year
        self.init(
            songIdentity: track.songIdentity,
            artistName: track.artistName,
            genre: track.song?.genreNames.first { $0 != "Music" } ?? track.local?.genre,
            releaseYear: year
        )
    }
}
