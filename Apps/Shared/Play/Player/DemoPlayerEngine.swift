import Foundation
import SwiftUI
import TracksCore

/// A player that only pretends, for sample data: the songs are made up, so nothing may reach
/// Apple Music. Time runs and songs change, so the screens can be seen as they'd really look.
@MainActor
final class DemoPlayerEngine: PlayerEngine {
    var onChange: (() -> Void)?

    private(set) var status: PlayerStatus = .stopped
    private(set) var isShuffled = false
    private(set) var repeatMode: PlayerRepeat = .off

    private var queue: [PlayerTrack] = []
    /// Your own music's songs, by id, so the pretend player can show their format.
    private var localTracks: [String: LocalTrack] = [:]
    private var index = 0
    private var isStation = false
    /// Played before the last resume, plus the time since it.
    private var elapsedBeforeResume: TimeInterval = 0
    private var resumedAt: Date?
    private var ticker: Task<Void, Never>?
    /// Only ever goes up, so no two queue entries share an id.
    private var nextEntryNumber = 0

    /// Sample songs a station draws from, taken from the sample history.
    private let songsForStations: () -> [HistorySong]

    init(songsForStations: @escaping () -> [HistorySong]) {
        self.songsForStations = songsForStations
    }

    var current: PlayerTrack? { queue.indices.contains(index) ? queue[index] : nil }
    var playsByName: Bool { true }
    var upNext: [PlayerTrack] { isStation || queue.isEmpty ? [] : Array(queue[(index + 1)...]) }

    var playbackTime: TimeInterval {
        elapsedBeforeResume + (resumedAt.map { Date.now.timeIntervalSince($0) } ?? 0)
    }

    func play(_ request: PlayRequest, context: PlayContext, shuffled: Bool) async throws {
        var songs: [HistorySong]
        var start = 0
        switch request {
        case .history(let history, let first):
            songs = history
            start = first
        case .demoStation:
            songs = Array(songsForStations().shuffled().prefix(30))
        case .local(let tracks, let first):
            songs = tracks.map(HistorySong.init)
            start = first
            localTracks = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        default:
            // Apple Music items never appear with sample data.
            throw PlayerProblem.nothingToPlay
        }
        guard !songs.isEmpty else { throw PlayerProblem.nothingToPlay }
        if shuffled {
            songs = FreshShuffle.order(songs, artist: { StatsCalculator.folded($0.artistName) }, seed: .random(in: 0...UInt64.max))
            start = 0
        }
        isStation = context.isStation
        if isStation { repeatMode = .off }
        let isLive = request.isLiveBroadcast
        queue = songs.map { makeTrack($0, isLive: isLive) }
        index = min(max(0, start), queue.count - 1)
        restartClock(playing: true)
    }

    func enqueue(_ request: PlayRequest, next: Bool) async throws {
        let songs: [HistorySong]
        switch request {
        case .history(let history, _): songs = history
        case .local(let tracks, _): songs = tracks.map(HistorySong.init)
        default: throw PlayerProblem.nothingToPlay
        }
        guard !isStation else { throw PlayerProblem.nothingToPlay }
        let tracks = songs.map { makeTrack($0, isLive: false) }
        if queue.isEmpty {
            queue = tracks
            index = 0
            restartClock(playing: true)
            return
        }
        queue.insert(contentsOf: tracks, at: next ? index + 1 : queue.count)
        onChange?()
    }

    func pause() {
        guard status == .playing else { return }
        elapsedBeforeResume = playbackTime
        resumedAt = nil
        status = .paused
        ticker?.cancel()
        onChange?()
    }

    func resume() async throws {
        guard current != nil, status != .playing else { return }
        resumedAt = .now
        status = .playing
        startTicker()
        onChange?()
    }

    func skipToNext() async throws {
        advance(by: 1)
    }

    func skipToPrevious() async throws {
        if playbackTime > 3 || index == 0 {
            seek(to: 0)
        } else {
            advance(by: -1)
        }
    }

    func seek(to time: TimeInterval) {
        elapsedBeforeResume = max(0, time)
        resumedAt = status == .playing ? .now : nil
        onChange?()
    }

    func setShuffled(_ isShuffled: Bool) {
        self.isShuffled = isShuffled
        guard isShuffled, index + 1 < queue.count else {
            onChange?()
            return
        }
        queue[(index + 1)...].shuffle()
        onChange?()
    }

    func setRepeat(_ mode: PlayerRepeat) {
        repeatMode = mode
        onChange?()
    }

    func jump(toUpNext offset: Int) async throws {
        guard queue.indices.contains(index + 1 + offset) else { return }
        index += 1 + offset
        restartClock(playing: true)
    }

    func removeUpNext(at offsets: IndexSet) {
        let places = IndexSet(offsets.map { $0 + index + 1 }.filter(queue.indices.contains))
        guard !places.isEmpty else { return }
        queue.remove(atOffsets: places)
        onChange?()
    }

    func moveUpNext(from offsets: IndexSet, to destination: Int) {
        let places = IndexSet(offsets.map { $0 + index + 1 }.filter(queue.indices.contains))
        guard !places.isEmpty else { return }
        queue.move(fromOffsets: places, toOffset: min(max(destination + index + 1, index + 1), queue.count))
        onChange?()
    }

    // MARK: - The pretend clock

    private func advance(by step: Int) {
        let next = index + step
        if repeatMode == .one, step > 0, status == .playing, playbackTime >= (current?.duration ?? 0) {
            restartClock(playing: true)
        } else if queue.indices.contains(next) {
            index = next
            restartClock(playing: status != .paused)
        } else if repeatMode == .all, !queue.isEmpty {
            index = 0
            restartClock(playing: true)
        } else {
            // The end of the queue: stop on the last song, as a real player does.
            elapsedBeforeResume = 0
            resumedAt = nil
            status = .paused
            ticker?.cancel()
            onChange?()
        }
    }

    private func restartClock(playing: Bool) {
        elapsedBeforeResume = 0
        resumedAt = playing ? .now : nil
        status = playing ? .playing : .paused
        if playing { startTicker() } else { ticker?.cancel() }
        onChange?()
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                if let duration = self.current?.duration ?? (self.isStation ? 200 : nil),
                   self.playbackTime >= duration {
                    self.advance(by: 1)
                }
            }
        }
    }

    /// Songs for a pretend station: the sample history's, newest first, each once.
    static func stationSongs(from history: ListeningHistory) -> [HistorySong] {
        var seen = Set<String>()
        return history.captures.reversed().compactMap { capture in
            guard seen.insert(capture.songIdentity).inserted else { return nil }
            return HistorySong(
                songID: capture.songID,
                title: capture.title,
                artistName: capture.artistName,
                albumTitle: capture.albumTitle,
                artworkURL: capture.artworkURL
            )
        }
    }

    private func makeTrack(_ song: HistorySong, isLive: Bool) -> PlayerTrack {
        nextEntryNumber += 1
        var track = Self.track(song, number: nextEntryNumber, isLive: isLive)
        track.local = localTracks[song.songID]
        return track
    }

    private static func track(_ song: HistorySong, number: Int, isLive: Bool) -> PlayerTrack {
        // Believable lengths that stay the same for a song.
        let seconds = 150 + Double(abs(GeneratedCover.hash(song.title)) % 120)
        return PlayerTrack(
            id: "demo.\(number).\(song.title)",
            title: song.title,
            artistName: song.artistName,
            albumTitle: song.albumTitle,
            cover: demoCover(number: number) ?? .url(song.artworkURL, seed: song.albumTitle ?? song.title),
            duration: SongLength.shown(seconds, isLiveBroadcast: isLive),
            isExplicit: false,
            song: nil
        )
    }

    /// `-TracksDemoCovers "https://…|https://…"`, in a Debug build: real covers for the sample
    /// songs, one after another, to see the player's backgrounds with real artwork.
    private static func demoCover(number: Int) -> CoverArt? {
        #if DEBUG
        guard let list = UserDefaults.standard.string(forKey: "TracksDemoCovers") else { return nil }
        let covers = list.split(separator: "|").map(String.init)
        guard !covers.isEmpty else { return nil }
        return .url(covers[(number - 1) % covers.count], seed: "demo")
        #else
        return nil
        #endif
    }
}
