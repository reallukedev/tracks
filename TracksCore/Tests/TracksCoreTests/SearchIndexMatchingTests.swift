import Testing
import Foundation
import TracksCore

@Suite("Searching the history: matching rules")
struct SearchIndexMatchingTests {
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    struct Entry {
        var title: String
        var artist: String
        var album: String
        var plays: Int
        var genre: String? = nil
    }

    static let catalog = [
        Entry(title: "Driftwood", artist: "Mara Solís", album: "Tides", plays: 5, genre: "Jazz"),
        Entry(title: "Open Ocean", artist: "Mara Solís", album: "Open Ocean", plays: 2, genre: "Pop"),
        Entry(title: "Satellite", artist: "Amara Vale", album: "Orbit", plays: 3, genre: "Electronic"),
    ]

    func index(_ entries: [Entry] = catalog) -> SearchIndex {
        var plays: [CaptureStat] = []
        var metadata: [String: SongMetadata] = [:]
        for entry in entries {
            for play in 0..<entry.plays {
                plays.append(CaptureStat(
                    songKey: entry.title, songID: entry.title, title: entry.title, artistName: entry.artist,
                    albumTitle: entry.album, capturedAt: start.addingTimeInterval(Double(play) * 300), kind: .onDemand
                ))
            }
            if let genre = entry.genre {
                metadata[HistoryImport.key(title: entry.title, artistName: entry.artist)] = SongMetadata(genre: genre, releaseYear: nil)
            }
        }
        return SearchIndex(history: ListeningHistory(plays).with(artistArtwork: [:], songMetadata: metadata))
    }

    @Test("nothing typed finds nothing", arguments: ["", "   ", "\n\t"])
    func blank(text: String) {
        let results = index().search(text)
        #expect(results == .empty)
        #expect(results.isEmpty)
    }

    @Test("typed words may each hit a different field of a song", arguments: ["driftwood tides", "mara driftwood", "mara sol"])
    func wordsAcrossFields(text: String) {
        #expect(index().search(text).songs.map(\.title).contains("Driftwood"))
    }

    @Test("word order doesn't matter")
    func wordOrder() {
        let index = index()
        #expect(index.search("solis mara") == index.search("mara solis"))
        #expect(!index.search("mara solis").isEmpty)
    }

    @Test("a word in no field rules the song out")
    func everyWordMustMatch() {
        #expect(index().search("mara driftwood zebra").songs.isEmpty)
    }

    @Test("songs are found by genre, artists and albums are not")
    func genre() {
        let results = index().search("jazz")
        #expect(results.songs.map(\.title) == ["Driftwood"])
        #expect(results.artists.isEmpty)
        #expect(results.albums.isEmpty)
    }

    @Test("albums match on title and artist together")
    func albums() {
        #expect(index().search("tides mara").albums.map(\.title) == ["Tides"])
    }

    @Test("artists match ignoring case and accents", arguments: ["MARA", "mará", "Solis"])
    func artists(text: String) {
        #expect(index().search(text).artists.map(\.name).contains("Mara Solís"))
    }

    /// Unlike the Top Result's ranking, there is no word-boundary rule here.
    @Test("a word matches inside a name")
    func substring() {
        #expect(Set(index().search("ara").artists.map(\.name)) == ["Mara Solís", "Amara Vale"])
    }

    @Test("each group is capped on its own, most played first")
    func limitPerGroup() {
        let entries = (1...30).map { Entry(title: "Wave \($0)", artist: "Wave Artist \($0)", album: "Wave Album \($0)", plays: $0) }
        let results = index(entries).search("wave", limit: 5)
        #expect(results.songs.map(\.title) == ["Wave 30", "Wave 29", "Wave 28", "Wave 27", "Wave 26"])
        #expect(results.artists.count == 5)
        #expect(results.albums.count == 5)
    }

    @Test("a limit past the matches gives all of them, no more")
    func limitBeyondMatches() {
        #expect(index().search("mara", limit: 50).songs.count == 3)
    }

    /// Every song here is played at the same moments, so nothing but insertion order differs.
    @Test("equal plays come back in the same order however the history was built")
    func tieOrder() {
        let entries = [
            Entry(title: "Echo A", artist: "Echo One", album: "Echoes", plays: 2),
            Entry(title: "Echo B", artist: "Echo Two", album: "Echoes Two", plays: 2),
            Entry(title: "Echo C", artist: "Echo Three", album: "Echoes Three", plays: 2),
        ]
        let forward = index(entries).search("echo")
        let reversed = index(entries.reversed()).search("echo")
        #expect(forward.songs.map(\.title) == reversed.songs.map(\.title))
        #expect(forward.artists.map(\.name) == reversed.artists.map(\.name))
    }

    @Test("top artists and albums honor the limit, most played first")
    func topLimits() {
        let index = index()
        #expect(index.topArtists(limit: 0).isEmpty)
        #expect(index.topAlbums(limit: 0).isEmpty)
        #expect(index.topArtists(limit: 10).map(\.name) == ["Mara Solís", "Amara Vale"])
        #expect(index.topAlbums(limit: 10).map(\.title) == ["Tides", "Orbit", "Open Ocean"])
    }
}

@Suite("Recent searches: storage edges")
struct RecentSearchesStorageTests {
    @Test("a search with a line break is stored as one entry")
    func newline() {
        let storage = RecentSearches.adding("a\nb", to: "")
        #expect(RecentSearches.list(storage) == ["a b"])
    }

    @Test("removing ignores case, like adding does")
    func removingIgnoresCase() {
        #expect(RecentSearches.list(RecentSearches.removing("Jazz", from: "jazz")).isEmpty)
    }

    @Test("removing a search that isn't there leaves them as they were")
    func removingAbsent() {
        let storage = RecentSearches.adding("jazz", to: RecentSearches.adding("mara", to: ""))
        #expect(RecentSearches.removing("blues", from: storage) == storage)
        #expect(RecentSearches.removing("blues", from: "") == "")
    }

    @Test("blank lines are not entries")
    func blankLines() {
        #expect(RecentSearches.list("a\n\nb") == ["a", "b"])
        #expect(RecentSearches.limit == 8)
    }
}
