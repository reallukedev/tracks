import Testing
import Foundation
@testable import TracksCore

/// On macOS metadata matching is the only way to identify a capture. A wrong match writes
/// the wrong track into the user's library, so when in doubt the matcher refuses.
@Suite("Catalog matching")
struct CatalogMatcherTests {
    let query = CatalogQuery(title: "Bohemian Rhapsody", artistName: "Queen", duration: 354)

    func candidate(
        id: String = "1",
        title: String = "Bohemian Rhapsody",
        artist: String = "Queen",
        duration: TimeInterval? = 354
    ) -> CatalogCandidate {
        CatalogCandidate(id: id, title: title, artistName: artist, duration: duration)
    }

    @Test("an exact match is accepted")
    func exact() {
        #expect(CatalogMatcher.matches(query: query, candidate: candidate()))
    }

    @Test("case and diacritics are ignored")
    func caseAndDiacritics() {
        let query = CatalogQuery(title: "Café", artistName: "Sigur Rós", duration: nil)
        let candidate = CatalogCandidate(
            id: "1", title: "CAFE", artistName: "sigur ros", duration: nil
        )
        #expect(CatalogMatcher.matches(query: query, candidate: candidate))
    }

    /// Music.app and the catalog often disagree about these suffixes.
    @Test("a trailing parenthetical qualifier does not block a match")
    func parentheticalSuffix() {
        #expect(CatalogMatcher.matches(
            query: query,
            candidate: candidate(title: "Bohemian Rhapsody (Remastered 2011)")
        ))
    }

    @Test("a different artist is rejected")
    func wrongArtist() {
        #expect(!CatalogMatcher.matches(query: query, candidate: candidate(artist: "Panic! At The Disco")))
    }

    @Test("a live version of the right length is rejected on title")
    func wrongTitle() {
        #expect(!CatalogMatcher.matches(query: query, candidate: candidate(title: "Killer Queen")))
    }

    @Test("small duration disagreements are tolerated", arguments: [351.0, 354.0, 357.0])
    func durationTolerance(duration: TimeInterval) {
        #expect(CatalogMatcher.matches(query: query, candidate: candidate(duration: duration)))
    }

    /// A live cut often differs only in length.
    @Test("a large duration disagreement is rejected", arguments: [300.0, 420.0])
    func durationMismatch(duration: TimeInterval) {
        #expect(!CatalogMatcher.matches(query: query, candidate: candidate(duration: duration)))
    }

    @Test("a missing duration on either side falls back to title and artist")
    func missingDuration() {
        let noDuration = CatalogQuery(title: "Bohemian Rhapsody", artistName: "Queen", duration: nil)
        #expect(CatalogMatcher.matches(query: noDuration, candidate: candidate()))
        #expect(CatalogMatcher.matches(query: query, candidate: candidate(duration: nil)))
    }

    @Test("the best match is returned when exactly one candidate qualifies")
    func singleMatch() {
        let result = CatalogMatcher.bestMatch(
            query: query,
            candidates: [candidate(id: "wrong", title: "Killer Queen"), candidate(id: "right")]
        )
        #expect(result?.id == "right")
    }

    /// Different lengths mean different recordings. Same-length candidates aren't ambiguous;
    /// see `ReleaseVariantTests`.
    @Test("candidates of different lengths are treated as no match")
    func ambiguous() {
        let result = CatalogMatcher.bestMatch(
            query: CatalogQuery(title: "Bohemian Rhapsody", artistName: "Queen"),
            candidates: [candidate(id: "a", duration: 354), candidate(id: "b", duration: 500)]
        )
        #expect(result == nil)
    }

    @Test("duplicate results for one song still match")
    func duplicateSameID() {
        let result = CatalogMatcher.bestMatch(
            query: query,
            candidates: [candidate(id: "same"), candidate(id: "same")]
        )
        #expect(result?.id == "same")
    }

    @Test("nothing qualifying returns nil")
    func noMatch() {
        let result = CatalogMatcher.bestMatch(
            query: query,
            candidates: [candidate(id: "x", title: "Something Else")]
        )
        #expect(result == nil)
    }
}

@Suite("Store URL parsing")
struct StoreURLParserTests {
    /// macOS 27's playerInfo has no Store URL key, but share links use the same `i=`.
    @Test("the i parameter is the catalog song id")
    func itmssURL() {
        let id = StoreURLParser.catalogSongID(
            from: "itmss://itunes.com/album?p=1440857781&i=1440857786"
        )
        #expect(id == "1440857786")
    }

    @Test("https share links parse the same way")
    func httpsURL() {
        let id = StoreURLParser.catalogSongID(
            from: "https://music.apple.com/us/album/bohemian-rhapsody/1440857781?i=1440857786"
        )
        #expect(id == "1440857786")
    }

    @Test("a url with no song parameter yields nothing")
    func noSongParameter() {
        #expect(StoreURLParser.catalogSongID(from: "itmss://itunes.com/album?p=1440857781") == nil)
    }

    @Test("non-numeric and malformed values are rejected", arguments: [
        "itmss://itunes.com/album?p=1&i=notanumber",
        "itmss://itunes.com/album?p=1&i=",
        "not a url at all",
    ])
    func rejected(urlString: String) {
        #expect(StoreURLParser.catalogSongID(from: urlString) == nil)
    }
}

/// Radio on macOS has no duration (`playerInfo` omits `Total Time` for a station), so the
/// album has to break ties instead.
@Suite("Album disambiguation")
struct AlbumDisambiguationTests {
    let query = CatalogQuery(
        title: "Bohemian Rhapsody",
        artistName: "Queen",
        duration: nil,
        albumTitle: "A Night at the Opera"
    )

    func candidate(id: String, album: String?) -> CatalogCandidate {
        CatalogCandidate(
            id: id,
            title: "Bohemian Rhapsody",
            artistName: "Queen",
            albumTitle: album,
            duration: nil
        )
    }

    /// A real search returned three results with the same title and artist.
    @Test("album picks the right one when title and artist tie")
    func breaksTie() {
        let result = CatalogMatcher.bestMatch(query: query, candidates: [
            candidate(id: "live", album: "Live at Wembley"),
            candidate(id: "studio", album: "A Night at the Opera"),
            candidate(id: "greatest", album: "Greatest Hits"),
        ])
        #expect(result?.id == "studio")
    }

    /// Music appends release-type suffixes the catalog often omits.
    @Test("a Single or EP suffix does not block the album match", arguments: [
        "Nostalgia - Single", "Nostalgia - EP", "Nostalgia",
    ])
    func releaseSuffixes(album: String) {
        let query = CatalogQuery(
            title: "Nostalgia", artistName: "Lossapardo", duration: nil, albumTitle: album
        )
        let result = CatalogMatcher.bestMatch(query: query, candidates: [
            CatalogCandidate(id: "a", title: "Nostalgia", artistName: "Lossapardo", albumTitle: "Nostalgia", duration: nil),
            CatalogCandidate(id: "b", title: "Nostalgia", artistName: "Lossapardo", albumTitle: "Other Record", duration: nil),
        ])
        #expect(result?.id == "a")
    }

    /// Album only breaks ties. Music and the catalog often name albums differently.
    @Test("a single candidate matches even when the album disagrees")
    func loneCandidateSurvives() {
        let result = CatalogMatcher.bestMatch(
            query: query,
            candidates: [candidate(id: "only", album: "Some Compilation")]
        )
        #expect(result?.id == "only")
    }

    @Test("still ambiguous after the album check means no match")
    func stillAmbiguous() {
        let result = CatalogMatcher.bestMatch(query: query, candidates: [
            candidate(id: "a", album: "A Night at the Opera"),
            candidate(id: "b", album: "A Night at the Opera"),
        ])
        #expect(result == nil)
    }
}

/// Real catalog results for songs heard on a station, which the matcher used to reject.
@Suite("Same recording, different releases")
struct ReleaseVariantTests {

    func butterflies(id: String, album: String, duration: TimeInterval = 163) -> CatalogCandidate {
        CatalogCandidate(
            id: id,
            title: "BUTTERFLIES",
            artistName: "Isaiah Falls & Joyce Wrice",
            albumTitle: album,
            duration: duration
        )
    }

    /// Observed: one song, four ids, all 163 seconds (a single, an album, an EP and the album
    /// again). Apple's playlist API treats them as one song.
    @Test("identical recordings across releases resolve to one match")
    func sameRecordingAcrossReleases() {
        let query = CatalogQuery(title: "BUTTERFLIES", artistName: "Isaiah Falls & Joyce Wrice")
        let result = CatalogMatcher.bestMatch(query: query, candidates: [
            butterflies(id: "a", album: "LUCKY ME - Single"),
            butterflies(id: "b", album: "LVRS PARADISE (SIDE A)"),
            butterflies(id: "c", album: "LUCKY YOU - EP"),
        ])
        #expect(result?.id == "a")
    }

    @Test("a known album still wins over the first result")
    func albumStillWins() {
        let query = CatalogQuery(
            title: "BUTTERFLIES",
            artistName: "Isaiah Falls & Joyce Wrice",
            albumTitle: "LUCKY YOU - EP"
        )
        let result = CatalogMatcher.bestMatch(query: query, candidates: [
            butterflies(id: "a", album: "LUCKY ME - Single"),
            butterflies(id: "c", album: "LUCKY YOU - EP"),
        ])
        #expect(result?.id == "c")
    }

    @Test("candidates of different lengths stay ambiguous")
    func differingDurationsRejected() {
        let query = CatalogQuery(title: "BUTTERFLIES", artistName: "Isaiah Falls & Joyce Wrice")
        let result = CatalogMatcher.bestMatch(query: query, candidates: [
            butterflies(id: "a", album: "LUCKY ME - Single", duration: 163),
            butterflies(id: "mix", album: "A DJ Mix", duration: 78),
        ])
        #expect(result == nil)
    }

    /// Without lengths there's no way to tell they're the same recording.
    @Test("candidates with unknown lengths stay ambiguous")
    func unknownDurationsRejected() {
        let query = CatalogQuery(title: "BUTTERFLIES", artistName: "Isaiah Falls & Joyce Wrice")
        let result = CatalogMatcher.bestMatch(query: query, candidates: [
            CatalogCandidate(id: "a", title: "BUTTERFLIES", artistName: "Isaiah Falls & Joyce Wrice"),
            CatalogCandidate(id: "b", title: "BUTTERFLIES", artistName: "Isaiah Falls & Joyce Wrice"),
        ])
        #expect(result == nil)
    }
}

/// A trailing parenthetical can be cosmetic ("Remastered 2011") or name a different
/// recording ("Live").
@Suite("Version qualifiers")
struct VersionQualifierTests {

    @Test("cosmetic qualifiers are ignored", arguments: [
        "Bohemian Rhapsody (Remastered 2011)",
        "Bohemian Rhapsody (feat. Someone)",
        "Bohemian Rhapsody (Deluxe)",
        "Bohemian Rhapsody (Bonus Track)",
    ])
    func cosmetic(title: String) {
        #expect(CatalogMatcher.normalize(title) == CatalogMatcher.normalize("Bohemian Rhapsody"))
    }

    @Test("version qualifiers are preserved", arguments: [
        "Bohemian Rhapsody (Live)",
        "Bohemian Rhapsody (Remix)",
        "BUTTERFLIES (Mixed)",
        "Song (Acoustic Version)",
        "Song (Radio Edit)",
    ])
    func versionChanging(title: String) {
        #expect(CatalogMatcher.normalize(title) != CatalogMatcher.normalize(
            title.replacingOccurrences(of: #"\s*\([^)]*\)$"#, with: "", options: .regularExpression)
        ))
    }

    @Test("a live version does not match the studio recording")
    func liveDoesNotMatchStudio() {
        let query = CatalogQuery(title: "Bohemian Rhapsody", artistName: "Queen", duration: 354)
        let live = CatalogCandidate(
            id: "live", title: "Bohemian Rhapsody (Live)", artistName: "Queen", duration: 354
        )
        #expect(!CatalogMatcher.matches(query: query, candidate: live))
    }
}

/// A real search returned two ordinary releases and one rework. Requiring every candidate
/// to agree meant no match.
@Suite("Variant among ordinary releases")
struct VariantAmongReleasesTests {
    let query = CatalogQuery(title: "Summer Rain", artistName: "Olive Jones")

    func candidate(id: String, album: String, duration: TimeInterval) -> CatalogCandidate {
        CatalogCandidate(
            id: id, title: "Summer Rain", artistName: "Olive Jones",
            albumTitle: album, duration: duration
        )
    }

    /// Two releases at 259s and one rework at 275s: the pair wins.
    @Test("the majority length wins over a lone variant")
    func majorityWins() {
        let result = CatalogMatcher.bestMatch(query: query, candidates: [
            candidate(id: "single", album: "Summer Rain - Single", duration: 259),
            candidate(id: "album", album: "For Mary", duration: 259),
            candidate(id: "rework", album: "Summer Rain (Rework) - Single", duration: 275),
        ])
        #expect(result?.id == "single")
    }

    @Test("an even split stays ambiguous")
    func tieRejected() {
        let result = CatalogMatcher.bestMatch(query: query, candidates: [
            candidate(id: "studio", album: "Summer Rain - Single", duration: 259),
            candidate(id: "other", album: "Something Else", duration: 275),
        ])
        #expect(result == nil)
    }

    @Test("rework is treated as a version qualifier")
    func reworkIsAVersion() {
        #expect(CatalogMatcher.normalize("Summer Rain (Rework)") != CatalogMatcher.normalize("Summer Rain"))
    }
}
