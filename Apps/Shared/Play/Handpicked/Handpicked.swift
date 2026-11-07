import SwiftUI
import MusicKit
import TracksCore

/// Handpicked: a one-time station made from songs you choose, as Music makes a station from a
/// song. Pick a few songs you love, from your playlists, what you play, or a search, and it
/// plays them, your songs most like them, and new songs like them, steered by what you skip.
enum Handpicked {
    static var title: String { String(localized: "Handpicked") }
    static var tagline: String { String(localized: "Songs you choose, and more like them.") }
    static let symbol = "wand.and.stars"

    /// Indigo: a colour of its own among the moods.
    static let color = Color(red: 0.33, green: 0.3, blue: 0.86)
    static var palette: [Color] { HueField.shades(of: color) }

    static var context: PlayContext { PlayContext(kind: .endless, title: title) }

    /// Picks that make a station. More than this say little more, and each costs a lookup.
    static let limit = 15
}

/// A song picked for a Handpicked station.
struct Handpick: Hashable, Identifiable {
    /// The song as the history knows it.
    let identity: String
    /// Apple Music's id for it, or your music's.
    let songID: String
    let title: String
    let artistName: String
    let albumTitle: String?
    let cover: CoverArt
    /// Apple Music's genre, or the file's, where known: what "like it" goes by.
    let genre: String?

    var id: String { identity }

    init(song: Song) {
        identity = HistoryImport.key(title: song.title, artistName: song.artistName)
        songID = song.id.rawValue
        title = song.title
        artistName = song.artistName
        albumTitle = song.albumTitle
        cover = song.artwork.map(CoverArt.artwork) ?? .url(nil, seed: song.albumTitle ?? song.title)
        genre = song.genreNames.first { $0 != "Music" }
    }

    init(_ song: MixSong) {
        identity = song.songIdentity
        songID = song.songID
        title = song.title
        artistName = song.artistName
        albumTitle = song.albumTitle
        cover = .url(song.artworkURL, seed: song.albumTitle ?? song.title)
        genre = song.genre
    }

    @MainActor
    init(_ track: LocalTrack, music: YourMusic) {
        identity = track.identity
        songID = track.id
        title = track.title
        artistName = track.artist
        albumTitle = track.album
        cover = .url(music.artworkURL(track.artwork)?.absoluteString, seed: track.album ?? track.title)
        genre = track.genre
    }

    /// The pick as a live mix takes it.
    var mixSong: MixSong {
        let artwork: String? = switch cover {
        case .artwork(let artwork): artwork.url(width: 600, height: 600)?.absoluteString
        case .url(let url, _): url
        }
        return MixSong(
            songIdentity: identity, songID: songID, title: title, artistName: artistName, albumTitle: albumTitle,
            artworkURL: artwork, plays: 0, lastHeard: .distantPast, genre: genre
        )
    }
}

/// The songs picked for one station, while the sheet that picks them is open. Each station
/// is made once, from fresh picks, so nothing is kept after it starts.
@MainActor
@Observable
final class HandpickedSelection {
    private(set) var picks: [Handpick] = []

    var isFull: Bool { picks.count >= Handpicked.limit }

    func contains(_ identity: String) -> Bool {
        picks.contains { $0.identity == identity }
    }

    /// Adds the song, or takes it out if it's there. False when it couldn't be added, as
    /// there are as many picks as a station takes.
    @discardableResult
    func toggle(_ pick: Handpick) -> Bool {
        if let index = picks.firstIndex(where: { $0.identity == pick.identity }) {
            picks.remove(at: index)
            return true
        }
        guard !isFull else { return false }
        picks.append(pick)
        return true
    }
}

// MARK: - Playing

/// Starting a Handpicked station from its sheet: the picks, your songs most like them, and
/// new songs like them from Apple Music, or from your servers with your own music.
@MainActor
enum HandpickedPlayback {
    /// Starts with one of the picks at random, so the station doesn't always open the same way.
    static func start(model: AppModel, picks: [Handpick]) async {
        let source = model.musicSource
        let player = model.player
        guard let opener = picks.randomElement() else { return }
        let (history, signals, isDemo) = (model.library.history, player.signals, player.isDemo)
        if source == .yourMusic {
            let music = model.yourMusic
            let tracks = picks.compactMap { music.index.track(id: $0.songID) }
            guard let start = music.index.track(id: opener.songID) ?? tracks.first else {
                player.problem = .failed(String(localized: "The songs picked for Handpicked aren't in your music anymore."))
                return
            }
            let finds = SuggestionMode.current == .onlyYours ? [] : await music.discover.similar(to: tracks).filter(music.isPlayable)
            let playable = music.playableTracks
            let mix = await OffMainActor.run {
                LiveMix.handpicked(tracks, from: playable, finds: finds, history: history, signals: signals, seed: .random(in: 0...UInt64.max))
            }
            await player.startLive(mix, from: Handpicked.context, startingWith: start.mixSong())
            return
        }
        let found = isDemo ? demoFinds() : await HandpickedCatalog.similar(to: picks)
        let songs = picks.map(\.mixSong)
        let mix = await OffMainActor.run {
            LiveMix.handpicked(songs, from: history, signals: signals, newFinds: found.songs, newFindReasons: found.reasons, seed: .random(in: 0...UInt64.max))
                .playable(isDemo: isDemo)
        }
        await player.startLive(mix, from: Handpicked.context, startingWith: opener.mixSong)
    }

    private static func demoFinds() -> HandpickedCatalog.Found {
        #if DEBUG
        HandpickedCatalog.Found(songs: DemoCatalog.songs(count: 30, offset: 1_600, artists: nil).map(MixSong.init(catalog:)), reasons: [:])
        #else
        HandpickedCatalog.Found(songs: [], reasons: [:])
        #endif
    }
}

/// New songs like the picks, from Apple Music: the top songs of the artists Apple lists as
/// similar to the picks' artists, and a few of those artists' own.
enum HandpickedCatalog {
    struct Found: Sendable {
        var songs: [MixSong]
        /// Why each is there, by song identity: which pick's artist it's like.
        var reasons: [String: LiveMix.Reason]
    }

    /// Whatever's back within a few seconds: the station mustn't keep you waiting.
    static func similar(to picks: [Handpick]) async -> Found {
        guard MusicAuthorization.currentStatus == .authorized else { return Found(songs: [], reasons: [:]) }
        let allowsExplicit = PlayPreferences.allowsExplicit
        let lookup = Task { await lookUp(picks) }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(6))
            lookup.cancel()
        }
        defer { timeout.cancel() }
        let found = await lookup.value
        let wanted = Set(PlayPreferences.versions(of: found.map(\.song), allowsExplicit: allowsExplicit).map(\.id))
        var songs: [MixSong] = []
        var reasons: [String: LiveMix.Reason] = [:]
        var seen = Set<MusicItemID>()
        for item in found where wanted.contains(item.song.id) && seen.insert(item.song.id).inserted {
            let song = MixSong(catalog: item.song)
            songs.append(song)
            if let like = item.like { reasons[song.songIdentity] = .newFindLike(like) }
        }
        return Found(songs: songs, reasons: reasons)
    }

    /// A song found, and the pick's artist it's like, when it's by someone else.
    private struct Item: Sendable {
        let song: Song
        let like: String?
    }

    /// The picks' artists, the most picked first, up to five: each one's own top few, and the
    /// top songs of the artists like them.
    @concurrent
    nonisolated private static func lookUp(_ picks: [Handpick]) async -> [Item] {
        let artists = await artists(of: picks)
        return await withTaskGroup(of: [Item].self) { group in
            for artist in artists {
                group.addTask {
                    guard let detailed = try? await artist.with([.similarArtists, .topSongs]) else { return [] }
                    let own = (detailed.topSongs?.prefix(5) ?? []).map { Item(song: $0, like: nil) }
                    let similar = Array(detailed.similarArtists?.prefix(4) ?? [])
                    let theirs = await withTaskGroup(of: [Item].self) { inner in
                        for other in similar {
                            inner.addTask {
                                let top = (try? await other.with([.topSongs]).topSongs).map { Array($0.prefix(5)) } ?? []
                                return top.map { Item(song: $0, like: artist.name) }
                            }
                        }
                        var items: [Item] = []
                        for await found in inner { items += found }
                        return items
                    }
                    return own + theirs
                }
            }
            var all: [Item] = []
            for await items in group { all += items }
            return all
        }
    }

    /// The picks' artists in Apple Music's catalog, found through the picks themselves.
    @concurrent
    nonisolated private static func artists(of picks: [Handpick]) async -> [Artist] {
        // The most picked artists first: they say the most about what's wanted.
        var counts: [String: Int] = [:]
        for pick in picks { counts[StatsCalculator.folded(pick.artistName), default: 0] += 1 }
        var seenArtists = Set<String>()
        let leading = picks
            .sorted { counts[StatsCalculator.folded($0.artistName), default: 0] > counts[StatsCalculator.folded($1.artistName), default: 0] }
            .filter { seenArtists.insert(StatsCalculator.folded($0.artistName)).inserted }
            .prefix(5)
        let found = await withTaskGroup(of: (Int, Artist?).self) { group in
            for (index, pick) in leading.enumerated() {
                group.addTask {
                    let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(pick.songID))
                    if let song = try? await request.response().items.first,
                       let artist = try? await song.with([.artists]).artists?.first {
                        return (index, artist)
                    }
                    // A song from the library has another id: found by name instead.
                    var search = MusicCatalogSearchRequest(term: pick.artistName, types: [Artist.self])
                    search.limit = 1
                    return (index, try? await search.response().artists.first)
                }
            }
            var byIndex: [Int: Artist] = [:]
            for await (index, artist) in group { byIndex[index] = artist }
            return byIndex
        }
        var seen = Set<MusicItemID>()
        return found.keys.sorted().compactMap { found[$0] }.filter { seen.insert($0.id).inserted }
    }
}
