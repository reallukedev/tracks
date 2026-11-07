import Testing
import Foundation
@testable import TracksCore

@Suite("Smart playlists")
struct SmartRulesTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let day: TimeInterval = 24 * 60 * 60

    func track(
        _ title: String,
        artist: String = "Mara Solis",
        album: String = "Coastlines",
        genre: String? = "Indie Pop",
        year: Int? = 2019,
        addedDaysAgo: Double = 10,
        lossless: Bool = false,
        hiRes: Bool = false,
        server: Bool = false
    ) -> LocalTrack {
        LocalTrack(
            origin: server ? .server(serverID: "home", songID: title) : .file(path: "\(artist)/\(title).flac"),
            title: title,
            artist: artist,
            album: album,
            year: year,
            genre: genre,
            duration: 200,
            format: lossless ? AudioFormat(codec: "FLAC", sampleRate: hiRes ? 96_000 : 44_100, bitDepth: hiRes ? 24 : 16) : AudioFormat(codec: "MP3", bitRate: 320),
            addedAt: now.addingTimeInterval(-addedDaysAgo * day)
        )
    }

    func facts(_ plays: Int, lastHeardDaysAgo: Double) -> SongFacts {
        let last = now.addingTimeInterval(-lastHeardDaysAgo * day)
        return SongFacts(plays: plays, radioPlays: 0, firstHeard: last, lastHeard: last)
    }

    @Test("words match without regard to case or accents", arguments: [
        (SmartRules.Comparison.contains, "SOLIS", true),
        (.is, "mara solís", true),
        (.is, "Mara", false),
        (.isNot, "Nova Harbor", true),
        (.doesNotContain, "mara", false),
        (.beginsWith, "mar", true),
        (.beginsWith, "solis", false),
    ])
    func words(comparison: SmartRules.Comparison, text: String, expected: Bool) {
        let condition = SmartRules.Condition(field: .artist, comparison: comparison, text: text)
        #expect(condition.matches(track("One"), facts: nil, now: now) == expected)
    }

    @Test("an artist matches a song by its album's artist too")
    func albumArtist() {
        var song = track("One", artist: "Mara Solis feat. Nova Harbor")
        song.albumArtist = "Mara Solis"
        let condition = SmartRules.Condition(field: .artist, comparison: .is, text: "Mara Solis")
        #expect(condition.matches(song, facts: nil, now: now))
    }

    @Test("plays count from the history, and a song never played has none")
    func plays() {
        let atLeastThree = SmartRules.Condition(field: .plays, comparison: .atLeast, number: 3)
        let never = SmartRules.Condition(field: .plays, comparison: .is, number: 0)
        #expect(atLeastThree.matches(track("One"), facts: facts(5, lastHeardDaysAgo: 1), now: now))
        #expect(!atLeastThree.matches(track("One"), facts: facts(2, lastHeardDaysAgo: 1), now: now))
        #expect(never.matches(track("One"), facts: nil, now: now))
    }

    @Test("last played in the last days, and a song never played is never in them")
    func lastPlayed() {
        let recent = SmartRules.Condition(field: .lastPlayed, comparison: .inTheLast, number: 7)
        let notRecent = SmartRules.Condition(field: .lastPlayed, comparison: .notInTheLast, number: 7)
        #expect(recent.matches(track("One"), facts: facts(1, lastHeardDaysAgo: 3), now: now))
        #expect(!recent.matches(track("One"), facts: facts(1, lastHeardDaysAgo: 30), now: now))
        #expect(!recent.matches(track("One"), facts: nil, now: now))
        #expect(notRecent.matches(track("One"), facts: nil, now: now))
    }

    @Test("date added counts back from now")
    func dateAdded() {
        let condition = SmartRules.Condition(field: .dateAdded, comparison: .inTheLast, number: 14)
        #expect(condition.matches(track("One", addedDaysAgo: 3), facts: nil, now: now))
        #expect(!condition.matches(track("One", addedDaysAgo: 40), facts: nil, now: now))
    }

    @Test("a song with no year isn't any year, and is every year it isn't")
    func noYear() {
        #expect(!SmartRules.Condition(field: .year, comparison: .atLeast, number: 2000).matches(track("One", year: nil), facts: nil, now: now))
        #expect(SmartRules.Condition(field: .year, comparison: .isNot, number: 2000).matches(track("One", year: nil), facts: nil, now: now))
    }

    @Test("quality: lossless, hi-res lossless, or not lossless")
    func quality() {
        let lossless = SmartRules.Condition(field: .quality, comparison: .isLossless)
        let hiRes = SmartRules.Condition(field: .quality, comparison: .isHiRes)
        let lossy = SmartRules.Condition(field: .quality, comparison: .isNotLossless)
        #expect(lossless.matches(track("One", lossless: true), facts: nil, now: now))
        #expect(!hiRes.matches(track("One", lossless: true), facts: nil, now: now))
        #expect(hiRes.matches(track("One", lossless: true, hiRes: true), facts: nil, now: now))
        #expect(lossy.matches(track("One"), facts: nil, now: now))
    }

    @Test("all needs every condition, any needs one, and unfinished ones are left out")
    func matching() {
        let pop = SmartRules.Condition(field: .genre, text: "pop")
        let rock = SmartRules.Condition(field: .genre, text: "rock")
        let blank = SmartRules.Condition(field: .artist, text: " ")
        let song = track("One")
        #expect(!SmartRules(match: .all, conditions: [pop, rock]).matches(song, facts: nil, now: now))
        #expect(SmartRules(match: .any, conditions: [pop, rock]).matches(song, facts: nil, now: now))
        #expect(SmartRules(match: .all, conditions: [pop, blank]).matches(song, facts: nil, now: now))
        #expect(SmartRules(conditions: [blank]).matches(song, facts: nil, now: now))
    }

    @Test("songs come once each, in order, up to the limit")
    func songs() {
        let one = track("One")
        let copy = track("One", server: true)
        let two = track("Two")
        let three = track("Three")
        let rules = SmartRules(order: .mostPlayed, limit: 2)
        let facts = [
            one.identity: facts(3, lastHeardDaysAgo: 1),
            three.identity: facts(9, lastHeardDaysAgo: 1),
        ]
        #expect(rules.songs(from: [one, copy, two, three], facts: facts, now: now, seed: 1).map(\.title) == ["Three", "One"])
    }

    @Test("a random order stays put for the same seed")
    func random() {
        let tracks = (1...12).map { track("Song \($0)", artist: "Artist \($0 % 4)") }
        let rules = SmartRules(order: .random)
        let first = rules.songs(from: tracks, facts: [:], now: now, seed: 42)
        #expect(first == rules.songs(from: tracks, facts: [:], now: now, seed: 42))
        #expect(Set(first) == Set(tracks))
    }

    @Test("rules survive being saved")
    func codable() throws {
        let rules = SmartRules(source: .yourMusic, match: .any, conditions: [SmartRules.Condition(field: .artist, text: "Mara")], order: .recentlyAdded, limit: 25)
        let decoded = try JSONDecoder().decode(SmartRules.self, from: JSONEncoder().encode(rules))
        #expect(decoded == rules)
    }
}

@Suite("Playlists you make")
struct TracksPlaylistTests {
    func track(_ title: String) -> LocalTrack {
        LocalTrack(origin: .file(path: "\(title).flac"), title: title, artist: "Mara Solis")
    }

    func playlist(_ titles: [String]) -> TracksPlaylist {
        var playlist = TracksPlaylist(name: "Road Trip")
        playlist.add(titles.map(track))
        return playlist
    }

    @Test("moving songs puts them where they were dropped", arguments: [
        (IndexSet(integer: 0), 3, ["B", "C", "A", "D"]),
        (IndexSet(integer: 3), 0, ["D", "A", "B", "C"]),
        (IndexSet([0, 1]), 4, ["C", "D", "A", "B"]),
        (IndexSet(integer: 2), 2, ["A", "B", "C", "D"]),
    ])
    func move(source: IndexSet, destination: Int, expected: [String]) {
        var playlist = playlist(["A", "B", "C", "D"])
        playlist.move(fromOffsets: source, toOffset: destination)
        #expect(playlist.entries.map(\.track.title) == expected)
    }

    @Test("the same song can be in twice, and each comes out on its own")
    func duplicates() throws {
        var playlist = playlist(["A", "A", "B"])
        let first = try #require(playlist.entries.first)
        playlist.remove([first.id])
        #expect(playlist.entries.map(\.track.title) == ["A", "B"])
    }
}
