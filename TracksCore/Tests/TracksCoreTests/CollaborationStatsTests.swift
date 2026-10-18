import Testing
import Foundation
@testable import TracksCore

@Suite("Collaborations in the statistics")
struct CollaborationStatsTests {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func play(_ title: String, by artist: String, album: String? = nil, at hours: Double) -> CaptureStat {
        CaptureStat(
            songKey: "\(title)|\(artist)",
            title: title,
            artistName: artist,
            albumTitle: album,
            capturedAt: start.addingTimeInterval(hours * 3_600)
        )
    }

    /// Umbra alone twice, with Mara Solis twice, and featuring Yuki Tanabe once in the title.
    var plays: [CaptureStat] {
        [
            play("Tides", by: "Umbra", album: "Eclipse", at: 0),
            play("Tides", by: "Umbra", album: "Eclipse", at: 1),
            play("Undertow", by: "Umbra & Mara Solis", album: "Eclipse", at: 2),
            play("Undertow", by: "Umbra & Mara Solis", album: "Eclipse", at: 3),
            play("Night Drive (feat. Umbra)", by: "Yuki Tanabe", album: "Lanterns", at: 4),
        ]
    }

    @Test("a play counts in full for every artist on it, and each is one artist in the charts")
    func charts() {
        let history = ListeningHistory(plays)
        let artists = StatsCalculator.tallyArtists(history.captures.indices, in: history)
        let counts = Dictionary(uniqueKeysWithValues: artists.map { ($0.name, $0.count) })
        #expect(counts == ["Umbra": 5, "Mara Solis": 2, "Yuki Tanabe": 1])
        #expect(artists.first { $0.name == "Umbra" }?.songCount == 3)

        let summary = StatsCalculator.summary(range: .allTime, captures: plays, sessions: [], now: start.addingTimeInterval(5 * 3_600))
        #expect(summary.uniqueArtistCount == 3)
        // A collaboration can introduce two artists at once.
        #expect(summary.newArtistCount == 3)
        // Five plays credit eight times over, so the mix's shares are of the eight.
        let mix = summary.artistMix(limit: 1)
        #expect(mix.whole == 8)
        #expect(mix.otherCount == 3)
    }

    @Test("an artist's page splits their own songs from the ones they're featured on")
    func profile() throws {
        let history = ListeningHistory(plays)
        let umbra = try #require(StatsCalculator.artistProfile(id: "umbra", history: history, now: start))
        #expect(umbra.artist.count == 5)
        #expect(umbra.songs.map(\.title) == ["Undertow", "Tides"])
        #expect(umbra.features.map(\.title) == ["Night Drive (feat. Umbra)"])
        #expect(umbra.collaborators.map(\.name) == ["Mara Solis", "Yuki Tanabe"])
        #expect(umbra.collaborators.first?.count == 2)
        // A feature isn't on their albums.
        #expect(umbra.albums.map(\.title) == ["Eclipse"])

        let mara = try #require(StatsCalculator.artistProfile(id: "mara solis", history: history, now: start))
        #expect(mara.songs.map(\.title) == ["Undertow"])
        #expect(mara.features.isEmpty)
        // Umbra's album, which Mara Solis is only on once.
        #expect(mara.albums.isEmpty)
        #expect(mara.collaborators.map(\.name) == ["Umbra"])
    }

    @Test("a song shared with someone stays on its lead artist's album")
    func albums() {
        let history = ListeningHistory(plays)
        let albums = StatsCalculator.tallyAlbums(history.captures.indices, in: history)
        #expect(albums.first { $0.title == "Eclipse" }?.count == 4)
        #expect(CaptureStat.albumIdentity(title: "Eclipse", artistName: "Umbra & Mara Solis") == history.captures[0].albumIdentity)
    }

    @Test("Apple Music's list of a song's artists settles who it credits, everywhere")
    func catalogCredits() throws {
        let duo = [play("Paper Boats", by: "Fern & Fable", at: 0), play("Paper Boats", by: "Fern & Fable", at: 1)]
        let byName = ListeningHistory(duo)
        #expect(byName.captures[0].creditIdentities == ["fern", "fable"])

        let identity = HistoryImport.key(title: "Paper Boats", artistName: "Fern & Fable")
        let metadata = [identity: SongMetadata(genre: "Folk", releaseYear: 2020, artists: ["Fern & Fable"])]
        for history in [byName.with(artistArtwork: [:], songMetadata: metadata), ListeningHistory(duo, songMetadata: metadata)] {
            #expect(history.captures.allSatisfy { $0.creditIdentities == ["fern & fable"] })
            let artists = StatsCalculator.tallyArtists(history.captures.indices, in: history)
            #expect(artists.map(\.name) == ["Fern & Fable"])
            #expect(history.newArtists.flatMap { $0 } == ["fern & fable"])
        }
    }

    @Test("songs whose credit may name several are asked about again for their artists, once")
    func lookups() {
        let history = ListeningHistory([
            play("Tides", by: "Umbra", at: 0),
            play("Undertow", by: "Umbra & Mara Solis", at: 1),
        ])
        let tides = HistoryImport.key(title: "Tides", artistName: "Umbra")
        let undertow = HistoryImport.key(title: "Undertow", artistName: "Umbra & Mara Solis")
        let before = SongMetadata(genre: "Pop", releaseYear: 2001)
        let pending = SongMetadataLookup.pending(in: history, known: [tides: before, undertow: before], limit: 10, searchLimit: 10)
        #expect(pending.map(\.songIdentity) == [undertow])

        // Asked and not found: the genre stays, and it isn't asked again.
        let recorded = SongMetadataCache(url: nil).record(found: [:], asked: [undertow], into: [tides: before, undertow: before])
        #expect(recorded[undertow]?.genre == "Pop")
        #expect(SongMetadataLookup.pending(in: history, known: recorded, limit: 10, searchLimit: 10).isEmpty)
    }

    @Test("the sample library has collaborations, and its bands stay whole")
    func sample() throws {
        let now = Date(timeIntervalSinceReferenceDate: 810_000_000)
        let captures = DemoLibrary.plays(endingAt: now).map {
            CaptureStat(songKey: $0.title, title: $0.title, artistName: $0.artistName, albumTitle: $0.albumTitle, capturedAt: $0.capturedAt)
        }
        let history = ListeningHistory(captures, songMetadata: DemoLibrary.songMetadata())
        let names = Set(StatsCalculator.tallyArtists(history.captures.indices, in: history).map(\.name))
        #expect(names.isSuperset(of: ["Wren & Ivy", "Fern & Fable", "Anastasia Montgomery-Whitfield"]))
        #expect(!names.contains("Wren") && !names.contains("Ivy"))
        let mara = try #require(StatsCalculator.artistProfile(id: "mara solis", history: history, now: now))
        #expect(!mara.features.isEmpty)
        #expect(mara.collaborators.contains { $0.name == "Nova Harbor" })
        // Only the albums she leads, not The Velvet Hours' one she shares a song on.
        #expect(!mara.albums.isEmpty)
        #expect(mara.albums.allSatisfy { $0.id.hasSuffix("\u{1F}mara solis") })
        let duo = try #require(StatsCalculator.artistProfile(id: "wren & ivy", history: history, now: now))
        #expect(!duo.albums.isEmpty)
    }

    @Test("an artist's own stories and favorites count their collaborations")
    func playTab() throws {
        let history = ListeningHistory(plays)
        let story = try #require(ArtistStories.story(of: "mara solis", in: history))
        #expect(story.plays == 2)
        #expect(story.topSongs.map(\.title) == ["Undertow"])
        let favorites = PlayFacts.favoriteArtists(in: history, since: start)
        #expect(favorites.map(\.name) == ["Umbra", "Mara Solis", "Yuki Tanabe"])
    }
}
