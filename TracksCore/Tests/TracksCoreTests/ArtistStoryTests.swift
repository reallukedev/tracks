import Testing
import Foundation
@testable import TracksCore

@Suite("Artist story")
struct ArtistStoryTests {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func play(_ title: String, by artist: String, at hours: Double) -> CaptureStat {
        CaptureStat(
            songKey: "\(title)|\(artist)",
            title: title,
            artistName: artist,
            capturedAt: start.addingTimeInterval(hours * 3_600)
        )
    }

    func story(of artist: String, in captures: [CaptureStat]) -> ArtistStory? {
        ArtistStories.story(of: StatsCalculator.folded(artist), in: ListeningHistory(captures))
    }

    @Test("an artist never kept has no story")
    func neverHeard() {
        #expect(story(of: "Nobody", in: [play("Song", by: "Somebody", at: 0)]) == nil)
    }

    @Test("an empty identity has no story, even where plays have no artist")
    func emptyIdentity() {
        let history = ListeningHistory([play("Song", by: "", at: 0)])
        #expect(ArtistStories.story(of: "", in: history) == nil)
    }

    @Test("counts every play, and knows the first and last")
    func playsAndDates() throws {
        let result = try #require(story(of: "Mara Solis", in: [
            play("B", by: "Mara Solis", at: 9),
            play("A", by: "Mara Solis", at: 1),
            play("Other", by: "Someone", at: 4),
            play("A", by: "mara solis", at: 5),
        ]))
        #expect(result.plays == 3)
        #expect(result.firstHeard == start.addingTimeInterval(3_600))
        #expect(result.lastHeard == start.addingTimeInterval(9 * 3_600))
    }

    @Test("your top songs by them come most played first")
    func topSongs() throws {
        let result = try #require(story(of: "Mara Solis", in: [
            play("Once", by: "Mara Solis", at: 0),
            play("Twice", by: "Mara Solis", at: 1),
            play("Twice", by: "Mara Solis", at: 2),
            play("Elsewhere", by: "Someone", at: 3),
        ]))
        #expect(result.topSongs.map(\.title) == ["Twice", "Once"])
        #expect(result.topSongs.first?.plays == 2)
    }

    @Test("ranks by plays, all time, ties sharing the better place")
    func rank() throws {
        let captures = [
            play("A", by: "First", at: 0), play("B", by: "First", at: 1), play("C", by: "First", at: 2),
            play("A", by: "Tied", at: 3), play("B", by: "Tied", at: 4),
            play("A", by: "Also Tied", at: 5), play("B", by: "Also Tied", at: 6),
            play("A", by: "Last", at: 7),
        ]
        #expect(try #require(story(of: "First", in: captures)).rank == 1)
        #expect(try #require(story(of: "Tied", in: captures)).rank == 2)
        #expect(try #require(story(of: "Also Tied", in: captures)).rank == 2)
        #expect(try #require(story(of: "Last", in: captures)).rank == 4)
    }

    @Test("a place past the limit isn't given")
    func rankLimit() throws {
        var captures: [CaptureStat] = []
        for artist in 0..<ArtistStories.rankLimit {
            captures += [play("A", by: "Artist \(artist)", at: 0), play("B", by: "Artist \(artist)", at: 1)]
        }
        captures.append(play("A", by: "Rarely", at: 2))
        let result = try #require(story(of: "Rarely", in: captures))
        #expect(result.rank == nil)
        #expect(result.plays == 1)
    }

    @Test("plays by artist leave out plays with no artist")
    func playsByArtist() {
        let counts = ArtistStories.plays(in: ListeningHistory([
            play("A", by: "Mara Solis", at: 0),
            play("B", by: "Mara Solis", at: 1),
            play("C", by: "", at: 2),
        ]))
        #expect(counts == [StatsCalculator.folded("Mara Solis"): 2])
    }
}
