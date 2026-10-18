import Testing
import Foundation
@testable import TracksCore

@Suite("Fresh shuffle")
struct FreshShuffleTests {
    struct Song: Equatable {
        let title: String
        let artist: String
    }

    func songs(_ artists: [String: Int]) -> [Song] {
        artists.sorted { $0.key < $1.key }.flatMap { artist, count in
            (0..<count).map { Song(title: "\(artist) \($0)", artist: artist) }
        }
    }

    /// Callers fold the artist's name, and asking inside the placing loop made a long
    /// shuffle quadratic in folds.
    @Test("the artist key is worked out once per song")
    func foldsOnce() {
        let input = songs(["A": 40, "B": 30, "C": 20, "D": 10])
        var calls = 0
        let output = FreshShuffle.order(input, artist: { calls += 1; return $0.artist }, recentlyHeard: { $0.artist == "D" }, seed: 3)
        #expect(output.count == input.count)
        #expect(calls == input.count)
    }

    @Test("keeps every song exactly once", arguments: [1, 7, 42, 2026] as [UInt64])
    func permutation(seed: UInt64) {
        let input = songs(["A": 5, "B": 4, "C": 3, "D": 1])
        let output = FreshShuffle.order(input, artist: \.artist, seed: seed)
        #expect(output.count == input.count)
        #expect(Set(output.map(\.title)) == Set(input.map(\.title)))
    }

    @Test("no artist twice within two places when there are enough artists", arguments: [1, 7, 42, 2026] as [UInt64])
    func spreadsArtists(seed: UInt64) {
        let input = songs(["A": 4, "B": 4, "C": 4, "D": 4, "E": 4])
        let output = FreshShuffle.order(input, artist: \.artist, seed: seed)
        for index in output.indices.dropFirst() {
            #expect(output[index].artist != output[index - 1].artist)
            if index >= 2 { #expect(output[index].artist != output[index - 2].artist) }
        }
    }

    @Test("an artist with more songs than the rest can separate is spread as far as it goes")
    func crowdedArtist() {
        let input = songs(["A": 6, "B": 3, "C": 3])
        let output = FreshShuffle.order(input, artist: \.artist, seed: 9)
        // Twelve places and six of A: A can't be kept two apart, but never lands three in a row.
        for index in output.indices.dropFirst(2) {
            let run = output[(index - 2)...index].map(\.artist)
            #expect(run != ["A", "A", "A"])
        }
    }

    @Test("the same seed gives the same order")
    func deterministic() {
        let input = songs(["A": 3, "B": 3, "C": 3])
        #expect(FreshShuffle.order(input, artist: \.artist, seed: 5) == FreshShuffle.order(input, artist: \.artist, seed: 5))
    }

    @Test("songs just heard go to the end")
    func recentLast() {
        let input = songs(["A": 3, "B": 3, "C": 3])
        let output = FreshShuffle.order(input, artist: \.artist, recentlyHeard: { $0.title.hasSuffix("0") }, seed: 3)
        #expect(output.suffix(3).allSatisfy { $0.title.hasSuffix("0") })
        #expect(output.prefix(6).allSatisfy { !$0.title.hasSuffix("0") })
    }

    @Test("one artist, or nothing, still works")
    func degenerate() {
        #expect(FreshShuffle.order([Song](), artist: \.artist, seed: 1).isEmpty)
        let single = songs(["A": 4])
        #expect(FreshShuffle.order(single, artist: \.artist, seed: 1).count == 4)
    }

    @Test("the daily seed holds for a day and changes the next")
    func dailySeed() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 8))!
        let night = calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 23))!
        let tomorrow = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 8))!
        #expect(FreshShuffle.dailySeed(for: morning, calendar: calendar) == FreshShuffle.dailySeed(for: night, calendar: calendar))
        #expect(FreshShuffle.dailySeed(for: morning, calendar: calendar) != FreshShuffle.dailySeed(for: tomorrow, calendar: calendar))
        #expect(FreshShuffle.dailySeed(for: morning, calendar: calendar, salt: "a") != FreshShuffle.dailySeed(for: morning, calendar: calendar, salt: "b"))
    }
}
