import Foundation
import Testing
@testable import TracksCore

@Suite("Live mixes steering after skips")
struct RadioSteeringTests {
    /// 60 songs: three genres, twenty artists, two decades, none new.
    let candidates: [LiveMix.Candidate] = (0..<60).map { index in
        let genre = ["Hip-Hop/Rap", "Country", "Alternative"][index % 3]
        return LiveMix.Candidate(
            song: RadioSteeringTests.song("S\(index)", artist: "Artist \(index % 20)"),
            weight: 1,
            genre: genre,
            releaseYear: index < 30 ? 1985 : 2015
        )
    }

    static func song(_ title: String, artist: String) -> MixSong {
        MixSong(
            songIdentity: HistoryImport.key(title: title, artistName: artist),
            songID: title,
            title: title,
            artistName: artist,
            albumTitle: nil,
            artworkURL: nil,
            plays: 0,
            lastHeard: .distantPast
        )
    }

    func genre(of song: MixSong) -> String? {
        candidates.first { $0.song.songIdentity == song.songIdentity }?.genre
    }

    func year(of song: MixSong) -> Int? {
        candidates.first { $0.song.songIdentity == song.songIdentity }?.releaseYear
    }

    func identity(ofGenre genre: String, _ index: Int = 0) -> String {
        candidates.filter { $0.genre == genre }[index].song.songIdentity
    }

    @Test("two skips in a row in one genre keep it out of the next few picks", arguments: 1...30 as ClosedRange<UInt64>)
    func runInOneGenre(seed: UInt64) throws {
        var mix = LiveMix(candidates: candidates, seed: seed)
        mix.noteSkipped(identity(ofGenre: "Country", 0))
        mix.noteSkipped(identity(ofGenre: "Country", 1))
        #expect(mix.steering == .awayFromGenre("Country"))
        for _ in 0..<LiveMix.avoidFor {
            let next = mix.next()
            let pick = try #require(next)
            #expect(genre(of: pick) != "Country")
        }
    }

    @Test("a genre skipped in a run comes back once the run is behind it")
    func genreComesBack() {
        var mix = LiveMix(candidates: candidates, seed: 7)
        mix.noteSkipped(identity(ofGenre: "Country", 0))
        mix.noteSkipped(identity(ofGenre: "Country", 1))
        let later = (0..<40).compactMap { _ in mix.next() }.dropFirst(LiveMix.avoidFor)
        #expect(later.contains { genre(of: $0) == "Country" })
    }

    @Test("two skips from one decade, in different genres, steer away from the decade", arguments: 1...20 as ClosedRange<UInt64>)
    func runInOneDecade(seed: UInt64) throws {
        var mix = LiveMix(candidates: candidates, seed: seed)
        // S0 is Hip-Hop, S1 Country: both 1985.
        mix.noteSkipped(candidates[0].song.songIdentity)
        mix.noteSkipped(candidates[1].song.songIdentity)
        #expect(mix.steering == .awayFromDecade(1980))
        for _ in 0..<LiveMix.avoidFor {
            let next = mix.next()
            let pick = try #require(next)
            #expect(year(of: pick) == 2015)
        }
    }

    @Test("skips with nothing in common try genres the run didn't have")
    func tryingSomethingElse() throws {
        let mixed = (0..<40).map { index in
            LiveMix.Candidate(
                song: Self.song("M\(index)", artist: "Band \(index)"),
                weight: 1,
                genre: ["Pop", "Jazz", "Metal", "Folk"][index % 4],
                releaseYear: 1960 + index * 10
            )
        }
        var mix = LiveMix(candidates: mixed, seed: 3)
        mix.noteSkipped(mixed[0].song.songIdentity)
        mix.noteSkipped(mixed[1].song.songIdentity)
        #expect(mix.steering == nil, "Two different genres and decades aren't a run of anything")
        mix.noteSkipped(mixed[2].song.songIdentity)
        #expect(mix.steering == .tryingSomethingElse)
        let next = mix.next()
        let pick = try #require(next)
        #expect(mixed.first { $0.song == pick }?.genre == "Folk")
    }

    @Test("the song let play after a run is the one it homes in on")
    func homesIn() {
        var mix = LiveMix(candidates: candidates, seed: 11)
        mix.noteSkipped(identity(ofGenre: "Country", 0))
        mix.noteSkipped(identity(ofGenre: "Country", 1))
        mix.noteFinished(identity(ofGenre: "Alternative", 0))
        #expect(mix.steering == .towardGenre("Alternative"))

        let draws = (1...60 as ClosedRange<UInt64>).reduce(0) { count, seed in
            var fresh = LiveMix(candidates: candidates, seed: seed)
            fresh.noteSkipped(identity(ofGenre: "Country", 0))
            fresh.noteSkipped(identity(ofGenre: "Country", 1))
            fresh.noteFinished(identity(ofGenre: "Alternative", 0))
            return count + (0..<6).compactMap { _ in fresh.next() }.count { genre(of: $0) == "Alternative" }
        }
        // Even would be half of what isn't Country; homing in makes it well over half.
        #expect(draws > 60 * 6 * 55 / 100)
    }

    @Test("two new finds skipped in a row make new finds rarer")
    func fewerNewFinds() {
        let yours = (0..<20).map { LiveMix.Candidate(song: Self.song("Y\($0)", artist: "Y\($0)"), weight: 1) }
        let new = (0..<20).map { LiveMix.Candidate(song: Self.song("N\($0)", artist: "N\($0)"), weight: 1, isNew: true) }
        var mix = LiveMix(candidates: yours + new, newShare: 0.4, seed: 2)
        mix.noteSkipped(new[0].song.songIdentity)
        let afterOne = mix.newShare
        mix.noteSkipped(new[1].song.songIdentity)
        #expect(mix.steering == .fewerNewFinds)
        #expect(mix.newShare < afterOne * 0.7)
    }

    @Test("loving a song steers toward its artist")
    func loved() {
        var mix = LiveMix(candidates: candidates, seed: 5)
        mix.noteLoved(candidates[4].song.songIdentity)
        #expect(mix.steering == .towardArtist("Artist 4"))
    }

    @Test("retuning keeps what the listen has learned")
    func retuneKeepsSteering() {
        var mix = LiveMix(candidates: candidates, seed: 1)
        mix.noteSkipped(identity(ofGenre: "Country", 0))
        mix.noteSkipped(identity(ofGenre: "Country", 1))
        var retuned = LiveMix(candidates: candidates, seed: 2)
        retuned.continueListen(from: mix)
        #expect(retuned.steering == .awayFromGenre("Country"))
        #expect(retuned.next().map { genre(of: $0) } != "Country")
    }

    @Test("retuning keeps how far skipped new finds have made them rarer, on top of the new tuning")
    func retuneKeepsNewShare() {
        let finds = (0..<10).map { LiveMix.Candidate(song: Self.song("New \($0)", artist: "Newcomer \($0)"), weight: 1, isNew: true) }
        var mix = LiveMix(candidates: candidates + finds, newShare: 0.3, seed: 1)
        mix.noteSkipped(finds[0].song.songIdentity)
        #expect(mix.newShare < 0.3)

        var same = LiveMix(candidates: candidates + finds, newShare: 0.3, seed: 2)
        same.continueListen(from: mix)
        #expect(abs(same.newShare - mix.newShare) < 0.0001)

        var bolder = LiveMix(candidates: candidates + finds, newShare: 0.5, seed: 2)
        bolder.continueListen(from: mix)
        #expect(bolder.newShare > same.newShare)
        #expect(bolder.newShare < 0.5)
    }

    @Test("a listen with nothing learned yet takes the new tuning's share as it is")
    func retuneWithNothingLearned() {
        let mix = LiveMix(candidates: candidates, newShare: 0.2, seed: 1)
        var retuned = LiveMix(candidates: candidates, newShare: 0.45, seed: 2)
        retuned.continueListen(from: mix)
        #expect(retuned.newShare == 0.45)
    }

    @Test("picking only songs that can play goes round those again once they've all been picked")
    func playableGoesRound() throws {
        var mix = LiveMix(candidates: candidates, seed: 3)
        let playable = Set(candidates.prefix(4).map(\.song.songIdentity))
        var heard: [String] = []
        for _ in 0..<12 {
            let next = mix.next(playable: { playable.contains($0.songIdentity) })
            let pick = try #require(next)
            heard.append(pick.songIdentity)
        }
        #expect(Set(heard) == playable)
        #expect(zip(heard, heard.dropFirst()).allSatisfy { $0 != $1 })
    }

    @Test("picking only songs that can play gives nothing when none can")
    func nothingPlayable() {
        var mix = LiveMix(candidates: candidates, seed: 3)
        #expect(mix.next(playable: { _ in false }) == nil)
    }

    @Test("genre spellings fold into one family", arguments: [
        ("Hip-Hop/Rap", "hip-hop"), ("Hip-Hop", "hip-hop"), ("R&B/Soul", "r&b"), ("Singer/Songwriter", "singer"),
    ])
    func genreFamilies(genre: String, key: String) {
        #expect(LiveMix.genreKey(genre) == key)
    }

    @Test("Apple's catch-all genre isn't a family")
    func catchAll() {
        #expect(LiveMix.genreKey("Music") == nil)
    }
}
