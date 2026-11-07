import Testing
import Foundation
@testable import TracksCore

@Suite("Artist pictures")
struct ArtistArtworkTests {
    private func stat(
        _ title: String,
        by artist: String,
        id: String = "",
        cover: String? = nil,
        minutesAgo: Double
    ) -> CaptureStat {
        CaptureStat(
            songKey: title,
            songID: id,
            title: title,
            artistName: artist,
            artworkURL: cover,
            capturedAt: Date(timeIntervalSinceNow: -minutesAgo * 60)
        )
    }

    @Test("the artist's picture replaces the album cover once it's known")
    func pictureWinsOverCover() {
        let captures = [stat("Hustle", by: "Rod Wave", cover: "https://example.test/album.jpg", minutesAgo: 5)]
        let without = StatsCalculator.tallyArtists(0..<1, in: ListeningHistory(captures))
        #expect(without.first?.artworkURL == "https://example.test/album.jpg")

        let history = ListeningHistory(captures, artistArtwork: ["rod wave": "https://example.test/rod.jpg"])
        let with = StatsCalculator.tallyArtists(0..<1, in: history)
        #expect(with.first?.artworkURL == "https://example.test/rod.jpg")
    }

    @Test("most played artists are looked up first, through their latest catalog song")
    func pendingOrder() {
        let history = ListeningHistory([
            stat("One", by: "Seldom", id: "100", minutesAgo: 50),
            stat("Two", by: "Often", id: "200", minutesAgo: 40),
            stat("Three", by: "Often", id: "201", minutesAgo: 30),
            stat("Four", by: "Often", minutesAgo: 20),
        ])
        let requests = ArtistArtworkLookup.pending(in: history, lookedUp: [], limit: 10)
        #expect(requests.map(\.artistName) == ["Often", "Seldom"])
        // The unresolved song is skipped; the newest one with an id is used.
        #expect(requests.first?.songID == "201")
    }

    @Test("artists already looked up aren't asked about again")
    func pendingSkipsKnown() {
        let history = ListeningHistory([
            stat("Known", by: "Known Artist", id: "100", minutesAgo: 30),
            stat("New", by: "New Artist", id: "300", minutesAgo: 10),
        ])
        let requests = ArtistArtworkLookup.pending(in: history, lookedUp: ["known artist"], limit: 10)
        #expect(requests.map(\.artistName) == ["New Artist"])
    }

    /// Songs from Recently Played that are in the library come with an "i.…" id.
    @Test("an artist with only library ids is found by searching for their song")
    func libraryOnlyArtistIsSearched() throws {
        let history = ListeningHistory([
            stat("Walkin", by: "Denzel Curry", id: "i.9oJNVL3uNqWdzme", minutesAgo: 10),
        ])
        let request = try #require(ArtistArtworkLookup.pending(in: history, lookedUp: [], limit: 10).first)
        #expect(!request.hasCatalogID)
        #expect(request.title == "Walkin")
    }

    @Test("a catalog id is used over a newer song that would need a search")
    func catalogIDPreferred() throws {
        let history = ListeningHistory([
            stat("Ultimate", by: "Denzel Curry", id: "1440832420", minutesAgo: 30),
            stat("Walkin", by: "Denzel Curry", id: "i.9oJNVL3uNqWdzme", minutesAgo: 10),
        ])
        let request = try #require(ArtistArtworkLookup.pending(in: history, lookedUp: [], limit: 10).first)
        #expect(request.songID == "1440832420")
    }

    @Test(
        "the credited artist is picked from a song with several",
        arguments: [
            // Exact match, wherever Apple lists them.
            ("Token", ["JID", "Token"], 1),
            // A joint credit goes to whoever is named first in it.
            ("Rome Streetz & Conductor Williams", ["Conductor Williams", "Rome Streetz"], 1),
            // No match falls back to the first.
            ("Someone Else", ["A", "B"], 0),
            ("Anyone", [], nil),
        ] as [(String, [String], Int?)]
    )
    func creditedArtist(credited: String, names: [String], expected: Int?) {
        #expect(ArtistArtworkLookup.creditedArtist(named: credited, among: names) == expected)
    }

    /// A cache of its own in a file nobody else reads, and a defaults suite of its own for
    /// where the pictures used to be kept.
    private struct ScratchCache {
        let file = FileManager.default.temporaryDirectory.appending(path: "ArtistArtwork-\(UUID().uuidString).json")
        let legacy = ScratchDefaults()
        var cache: ArtistArtworkCache { ArtistArtworkCache(url: file, legacySuiteName: legacy.suiteName) }

        func remove() { try? FileManager.default.removeItem(at: file) }
    }

    @Test("a lookup with no picture is remembered, so it isn't repeated")
    func cacheRemembersMisses() {
        let scratch = ScratchCache()
        defer { scratch.remove() }
        let cache = scratch.cache

        cache.record(found: ["rod wave": "https://example.test/rod.jpg"], asked: ["rod wave", "nobody"])
        #expect(cache.urls == ["rod wave": "https://example.test/rod.jpg"])
        #expect(cache.lookedUp == ["rod wave", "nobody"])

        cache.record(found: ["yeat": "https://example.test/yeat.jpg"], asked: ["yeat"])
        #expect(cache.urls.count == 2)
    }

    /// Repairing artwork has to undo a "no picture" that only happened because the lookup ran
    /// before the artist's songs had catalog ids.
    @Test("forgetting misses queues them again and keeps the pictures that were found")
    func forgetMissingKeepsFoundPictures() {
        let scratch = ScratchCache()
        defer { scratch.remove() }
        let cache = scratch.cache

        cache.record(
            found: ["rod wave": "https://example.test/rod.jpg"],
            asked: ["rod wave", "nobody", "also nobody"]
        )
        #expect(cache.forgetMissing() == 2)

        #expect(cache.lookedUp == ["rod wave"])
        #expect(cache.urls == ["rod wave": "https://example.test/rod.jpg"])
        // Nothing left to forget the second time.
        #expect(cache.forgetMissing() == 0)
    }

    /// One entry per artist ever played grew without end in the App Group's defaults, which
    /// every widget and the menu bar load whole to read a setting.
    @Test("the pictures are kept out of the shared defaults")
    func keptOutOfSharedDefaults() {
        let scratch = ScratchCache()
        defer { scratch.remove() }

        scratch.cache.record(found: ["rod wave": "https://example.test/rod.jpg"], asked: ["rod wave", "nobody"])

        #expect(scratch.legacy.defaults.object(forKey: ArtistArtworkCache.legacyDefaultsKey) == nil)
        #expect(scratch.cache.urls == ["rod wave": "https://example.test/rod.jpg"])
        #expect(scratch.cache.lookedUp == ["rod wave", "nobody"])
    }

    @Test("pictures found before the move are moved, not looked up again")
    func movesTheOldCache() {
        let scratch = ScratchCache()
        defer { scratch.remove() }
        scratch.legacy.defaults.set(
            ["rod wave": "https://example.test/rod.jpg", "nobody": ""],
            forKey: ArtistArtworkCache.legacyDefaultsKey
        )

        #expect(scratch.cache.urls == ["rod wave": "https://example.test/rod.jpg"])
        #expect(scratch.cache.lookedUp == ["rod wave", "nobody"])
        #expect(scratch.legacy.defaults.object(forKey: ArtistArtworkCache.legacyDefaultsKey) == nil)
    }
}
