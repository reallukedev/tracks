import Foundation
import Testing
@testable import TracksCore

@Suite("Autoplay")
struct AutoplayTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Two sittings a day for thirty days: one of Rock Bands A and B, one of Pop Singers C and D.
    /// Every song played the same number of times, so only likeness tells them apart.
    func history() -> ListeningHistory {
        var plays: [CaptureStat] = []
        var metadata: [String: SongMetadata] = [:]
        let sittings: [(artists: [String], genre: String, hour: Double)] = [
            (["Band A", "Band B"], "Rock", 9),
            (["Singer C", "Singer D"], "Pop", 20),
        ]
        for day in 1...30 {
            for sitting in sittings {
                for (position, artist) in sitting.artists.enumerated() {
                    for track in 0..<3 {
                        let title = "\(artist) \(track)"
                        let at = now.addingTimeInterval(-Double(day) * 86_400 + sitting.hour * 3_600 + Double(position * 3 + track) * 240)
                        plays.append(CaptureStat(songKey: title, songID: title, title: title, artistName: artist, capturedAt: at))
                        metadata[HistoryImport.key(title: title, artistName: artist)] = SongMetadata(genre: sitting.genre, releaseYear: nil)
                    }
                }
            }
        }
        return ListeningHistory(plays).with(artistArtwork: [:], songMetadata: metadata)
    }

    func seed(_ title: String, _ artist: String) -> AutoplaySeed {
        AutoplaySeed(songIdentity: HistoryImport.key(title: title, artistName: artist), artistName: artist)
    }

    @Test("after a rock song, autoplay mostly plays rock and the band played with it")
    func followsTheSeeds() {
        let history = history()
        var rock = 0
        var total = 0
        for value in 1...40 as ClosedRange<UInt64> {
            var mix = LiveMix.autoplay(after: [seed("Band A 0", "Band A")], from: history, now: now, seed: value)
            let picks = (0..<4).compactMap { _ in mix.next() }
            total += picks.count
            rock += picks.count { $0.artistName.hasPrefix("Band") }
        }
        #expect(rock * 10 > total * 8)
    }

    @Test("the seeds themselves aren't played again")
    func leavesOutSeeds() {
        let seeds = [seed("Band A 0", "Band A"), seed("Band A 1", "Band A")]
        let mix = LiveMix.autoplay(after: seeds, from: history(), now: now, seed: 1)
        let identities = Set(mix.candidates.map(\.song.songIdentity))
        #expect(identities.isDisjoint(with: seeds.map(\.songIdentity)))
    }

    @Test("everything else can still come up, so it never runs dry")
    func neverRunsDry() {
        var mix = LiveMix.autoplay(after: [seed("Band A 0", "Band A")], from: history(), now: now, seed: 3)
        let everything = (0..<11).compactMap { _ in mix.next() }
        #expect(Set(everything.map(\.id)).count == 11)
        #expect(everything.contains { $0.artistName.hasPrefix("Singer") })
    }

    @Test("artists played in the same sitting count as alike")
    func sittings() {
        let alongside = AutoplayAffinity.alongside(["band a"], in: history())
        #expect(alongside["band b"] == 1)
        #expect(alongside["singer c"] == nil)
    }

    @Test("new finds from the seeds' genre join, and skipped ones stay out")
    func newFinds() {
        let find = MixSong(
            songIdentity: "find", songID: "find", title: "Find", artistName: "Band E", albumTitle: nil,
            artworkURL: nil, plays: 0, lastHeard: .distantPast, genre: "Rock"
        )
        let skipped = MixSong(
            songIdentity: "skipped", songID: "skipped", title: "Skipped", artistName: "Band F", albumTitle: nil,
            artworkURL: nil, plays: 0, lastHeard: .distantPast, genre: "Rock"
        )
        var signals = ListeningSignals()
        signals.setSuggestLess("skipped", true)
        let mix = LiveMix.autoplay(after: [seed("Band A 0", "Band A")], from: history(), signals: signals, newFinds: [find, skipped], now: now, seed: 1)
        let new = mix.candidates.filter(\.isNew).map(\.song.songIdentity)
        #expect(new == ["find"])
    }

    @Test("with nothing in the history, new finds carry it")
    func emptyHistory() {
        let finds = (0..<5).map {
            MixSong(songIdentity: "n\($0)", songID: "n\($0)", title: "N\($0)", artistName: "A\($0)", albumTitle: nil, artworkURL: nil, plays: 0, lastHeard: .distantPast)
        }
        var mix = LiveMix.autoplay(after: [seed("Gone", "Nobody")], from: ListeningHistory([]), newFinds: finds, now: now, seed: 1)
        #expect((0..<5).compactMap { _ in mix.next() }.count == 5)
    }

    @Test("your own music: songs like the seeds, and never-played ones as new finds")
    func localTracks() {
        let tracks = (0..<6).map { index in
            LocalTrack(
                origin: .file(path: "t\(index).flac"),
                title: "Band A \(index)",
                artist: index < 3 ? "Band A" : "Stranger",
                genre: index < 3 ? "Rock" : "Classical"
            )
        }
        let mix = LiveMix.autoplay(after: [seed("Band A 0", "Band A")], from: tracks, history: history(), now: now, seed: 1)
        #expect(mix.candidates.contains { $0.song.title == "Band A 0" } == false)
        let rock = mix.candidates.filter { $0.genre == "Rock" }.map(\.weight).min() ?? 0
        let classical = mix.candidates.filter { $0.genre == "Classical" }.map(\.weight).max() ?? 1
        #expect(rock > classical)
    }
}
