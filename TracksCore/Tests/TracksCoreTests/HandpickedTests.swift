import Foundation
import Testing
@testable import TracksCore

@Suite("Handpicked")
struct HandpickedTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Two sittings a day for thirty days: one of Rock Bands A and B, one of Pop Singers C and D,
    /// three songs each. Every song played the same number of times, so only likeness tells them
    /// apart.
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

    func song(_ title: String, _ artist: String, genre: String? = nil) -> MixSong {
        MixSong(
            songIdentity: HistoryImport.key(title: title, artistName: artist), songID: title, title: title,
            artistName: artist, albumTitle: nil, artworkURL: nil, plays: 0, lastHeard: .distantPast, genre: genre
        )
    }

    @Test("the songs picked play in the station")
    func picksPlay() {
        let picks = [song("Band A 0", "Band A"), song("Someone New", "Band E", genre: "Rock")]
        let mix = LiveMix.handpicked(picks, from: history(), now: now, seed: 1)
        let identities = Set(mix.candidates.map(\.song.songIdentity))
        #expect(identities.isSuperset(of: picks.map(\.songIdentity)))
    }

    @Test("songs of yours that share nothing with the picks never come up")
    func keepsToThePicks() {
        let mix = LiveMix.handpicked([song("Band A 0", "Band A")], from: history(), now: now, seed: 2)
        let artists = Set(mix.candidates.map(\.song.artistName))
        #expect(artists.contains("Band B"))
        #expect(artists.isDisjoint(with: ["Singer C", "Singer D"]))
    }

    @Test("the songs most like the picks come up most")
    func followsThePicks() {
        let history = history()
        var byBandA = 0
        var total = 0
        for value in 1...40 as ClosedRange<UInt64> {
            var mix = LiveMix.handpicked([song("Band B 0", "Band B")], from: history, now: now, seed: value)
            let picks = (0..<3).compactMap { _ in mix.next() }
            total += picks.count
            byBandA += picks.count { $0.artistName == "Band A" }
        }
        // Band A is played alongside Band B and shares its genre: most of what isn't Band B.
        #expect(byBandA * 3 > total)
    }

    @Test("new finds join as new, saying why, and ones asked to be suggested less stay out")
    func newFinds() {
        let find = song("Find", "Band E", genre: "Rock")
        var signals = ListeningSignals()
        let unwanted = song("Unwanted", "Band F", genre: "Rock")
        signals.setSuggestLess(unwanted.songIdentity, true)
        let mix = LiveMix.handpicked(
            [song("Band A 0", "Band A")], from: history(), signals: signals, newFinds: [find, unwanted],
            newFindReasons: [find.songIdentity: .newFindLike("Band A")], now: now, seed: 3
        )
        let found = mix.candidates.first { $0.song.songIdentity == find.songIdentity }
        #expect(found?.isNew == true)
        #expect(found?.reason == .newFindLike("Band A"))
        #expect(mix.candidates.contains { $0.song.songIdentity == unwanted.songIdentity } == false)
    }

    @Test("with few songs of yours like the picks, new finds take more of the station")
    func fewCloseSongsMeansMoreNew() {
        let mix = LiveMix.handpicked([song("Band A 0", "Band A")], from: history(), now: now, seed: 4)
        #expect(mix.newShare == 0.65)
    }

    @Test("it never runs dry: once everything's been heard, it goes round again")
    func neverRunsDry() {
        var mix = LiveMix.handpicked([song("Band A 0", "Band A")], from: history(), now: now, seed: 5)
        let heard = (0..<(mix.candidates.count * 2)).compactMap { _ in mix.next() }
        #expect(heard.count == mix.candidates.count * 2)
    }

    @Test("songs to pick from: the last heard first, and the most played first")
    func choices() {
        let history = history()
        let recent = HandpickedChoices.recentlyPlayed(in: history, limit: 3, now: now)
        // The last sitting of all is the pop one on the last day, Singer D's songs last.
        #expect(recent.first?.title == "Singer D 2")
        #expect(Set(recent.map(\.songIdentity)).count == recent.count)
        let most = HandpickedChoices.mostPlayed(in: history, limit: 12, now: now)
        #expect(most.count == 12)
        #expect(HandpickedChoices.mostPlayed(in: history, limit: 5, now: now).count == 5)
    }

    // MARK: - Your own music

    func track(_ title: String, _ artist: String, genre: String? = nil, server: Bool = false) -> LocalTrack {
        let origin: LocalTrack.Origin = server ? .server(serverID: "octo", songID: "\(artist)-\(title)") : .file(path: "\(artist)/\(title).flac")
        return LocalTrack(origin: origin, title: title, artist: artist, genre: genre)
    }

    @Test("from your own music: picks, your songs like them, and a server's finds without genres")
    func yourMusic() {
        let pick = track("Band A 0", "Band A", genre: "Rock")
        let tracks = [pick, track("Band B 1", "Band B", genre: "Rock"), track("Singer C 1", "Singer C", genre: "Pop")]
        let find = track("Found", "Band G", server: true)
        let mix = LiveMix.handpicked([pick], from: tracks, finds: [find], history: history(), now: now, seed: 6)
        let titles = Set(mix.candidates.map(\.song.title))
        #expect(titles.isSuperset(of: ["Band A 0", "Band B 1", "Found"]))
        #expect(titles.contains("Singer C 1") == false)
    }
}
