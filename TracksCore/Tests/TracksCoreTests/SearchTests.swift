import Testing
import Foundation
@testable import TracksCore

@Suite("Search's Top Result")
struct SearchTopResultTests {
    @Test("the best matching name wins: the whole name, then its start, then a later word", arguments: [
        // Typed in full: an artist's before an album's, an album's before a song's.
        ("Mara Solis", "Mara Solis", "Mara Solis", String?("Mara Solis"), SearchTopKind.artist),
        ("tides", "Tidesman", "Tides", "Tide Pool", .album),
        ("TIDÉS", "Tidesman", "Tides", nil, .album),
        ("satellite", "Satellite Kids", "Orbit", "Satellite", .song),
        // Being typed from the start: the artist, then the album, then the song.
        ("tide", "Tidesman", "Tides", "Tide Pool", .artist),
        ("midn", "Mara Solis", "Midnight Bakery", "Driftwood", .album),
        ("drift", "Amara Vale", "Driftwood", "Driftwood", .album),
        ("hori", "Mara Solis", "Midnight Bakery", "Horizon Line", .song),
        // A later word, from three letters, loses to any name being typed from its start.
        ("bake", "Mara Solis", "Midnight Bakery", "Driftwood", .album),
        ("sol", "Mara Solís", "Solstice", "Driftwood", .album),
    ])
    func bestMatch(query: String, artist: String, album: String, song: String?, expected: SearchTopKind) {
        #expect(SearchRanking.topKind(for: query, artist: artist, album: album, song: song) == expected)
    }

    @Test("an artist's name being typed, or typed with more after it, ignoring case and accents")
    func artistBeingTyped() {
        #expect(SearchRanking.topKind(for: "mara so", artist: "Mara Solís", album: nil, song: "Driftwood") == .artist)
        #expect(SearchRanking.topKind(for: "mara solis live", artist: "Mara Solís", album: nil, song: "Driftwood") == .artist)
        // A later word of the name, once there's enough of it to mean something.
        #expect(SearchRanking.topKind(for: "sol", artist: "Mara Solís", album: nil, song: "Driftwood") == .artist)
        #expect(SearchRanking.topKind(for: "so", artist: "Mara Solís", album: nil, song: "Driftwood") == .song)
        // Only on a word's boundary: "maras" isn't more of "Mara".
        #expect(SearchRanking.topKind(for: "maras", artist: "Mara", album: nil, song: "Driftwood") == .song)
    }

    @Test("with no name matching, the first song, and nothing without one or without a query")
    func fallsBack() {
        #expect(SearchRanking.topKind(for: "ocean", artist: "Mara Solis", album: "Tides", song: "Driftwood") == .song)
        #expect(SearchRanking.topKind(for: "ocean", artist: "Mara Solis", album: "Tides", song: nil) == nil)
        #expect(SearchRanking.topKind(for: "  ", artist: "Mara Solis", album: nil, song: "Driftwood") == nil)
        // A name that's empty never matches everything.
        #expect(SearchRanking.topKind(for: "x", artist: "", album: "", song: nil) == nil)
    }
}

@Suite("Recent searches")
struct RecentSearchesTests {
    @Test("newest first, each search once whatever its case, trimmed, eight at most")
    func adding() {
        var storage = ""
        for term in ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"] {
            storage = RecentSearches.adding(term, to: storage)
        }
        storage = RecentSearches.adding("  FIVE \n", to: storage)
        #expect(RecentSearches.list(storage) == ["FIVE", "nine", "eight", "seven", "six", "four", "three", "two"])
    }

    @Test("a blank search leaves them as they were, and one can be taken out")
    func blankAndRemoving() {
        let storage = RecentSearches.adding("jazz", to: RecentSearches.adding("mara", to: ""))
        #expect(RecentSearches.adding("   ", to: storage) == storage)
        #expect(RecentSearches.list(RecentSearches.removing("mara", from: storage)) == ["jazz"])
        #expect(RecentSearches.list(RecentSearches.removing("jazz", from: "jazz")).isEmpty)
    }
}

@Suite("Searching the history")
struct SearchIndexTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func history() -> ListeningHistory {
        var plays: [CaptureStat] = []
        func add(_ title: String, by artist: String, on album: String, times: Int) {
            for _ in 0..<times {
                plays.append(CaptureStat(
                    songKey: title, songID: title, title: title, artistName: artist, albumTitle: album,
                    capturedAt: start.addingTimeInterval(Double(plays.count) * 300), kind: .onDemand
                ))
            }
        }
        add("Driftwood", by: "Mara Solís", on: "Tides", times: 5)
        add("Open Ocean", by: "Mara Solís", on: "Open Ocean", times: 2)
        add("Satellite", by: "Amara Vale", on: "Orbit", times: 3)
        return ListeningHistory(plays)
    }

    @Test("every typed word matches, accents aside, most played first")
    func search() {
        let index = SearchIndex(history: history())
        let results = index.search("mara")
        #expect(results.artists.map(\.name) == ["Mara Solís", "Amara Vale"])
        #expect(results.songs.map(\.title) == ["Driftwood", "Satellite", "Open Ocean"])
        #expect(index.search("solis ocean").songs.map(\.title) == ["Open Ocean"])
        #expect(index.search("nobody").isEmpty)
    }

    @Test("before anything's typed: the most played artists and albums")
    func top() {
        let index = SearchIndex(history: history())
        #expect(index.topArtists(limit: 1).map(\.name) == ["Mara Solís"])
        #expect(index.topAlbums(limit: 2).map(\.title) == ["Tides", "Orbit"])
    }
}
