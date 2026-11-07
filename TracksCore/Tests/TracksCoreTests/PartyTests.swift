import Testing
import Foundation
@testable import TracksCore

@Suite("Finding a playlist for a party")
struct PartyPlaylistRankingTests {
    func playlist(_ name: String, id: String? = nil, apple: Bool = false) -> PartyPlaylistCandidate {
        PartyPlaylistCandidate(id: id ?? name, name: name, isAppleCurated: apple)
    }

    @Test("Apple Music's own playlists come first, then the ones more searches found")
    func appleFirstThenHits() {
        let ranked = PartyPlaylistRanking.rank(
            [
                [playlist("Saturday Night"), playlist("Dance Party", apple: true), playlist("Friday Bangers")],
                [playlist("Friday Bangers"), playlist("Club Nights", apple: true)],
            ],
            for: .danceFloor,
            allowsExplicit: true
        )
        // Both Apple ones lead; of the rest, the one both searches found beats the one only
        // the first did, even though that one came first.
        #expect(ranked.map(\.name) == ["Dance Party", "Club Nights", "Friday Bangers", "Saturday Night"])
    }

    @Test("a playlist found by several searches appears once")
    func noDuplicates() {
        let party = playlist("Party Hits", apple: true)
        let ranked = PartyPlaylistRanking.rank([[party, party], [party], [party]], for: .danceFloor, allowsExplicit: true)
        #expect(ranked == [party])
    }

    @Test("names that say more about the party rank above ones that say less, all else equal")
    func nameMatches() {
        let ranked = PartyPlaylistRanking.rank(
            [[playlist("Good Vibes"), playlist("Dinner Party Jazz"), playlist("Cocktails")]],
            for: .dinnerParty,
            allowsExplicit: true
        )
        #expect(ranked.first?.name == "Dinner Party Jazz")
        // The rest keep Apple Music's order.
        #expect(ranked.dropFirst().map(\.name) == ["Good Vibes", "Cocktails"])
    }

    @Test("with explicit songs on, a clean twin goes; a clean playlist with no twin stays")
    func cleanTwinWithExplicit() {
        let ranked = PartyPlaylistRanking.rank(
            [[playlist("Party Hits (Clean)"), playlist("Party Hits"), playlist("Clean Bangers")]],
            for: .houseParty,
            allowsExplicit: true
        )
        #expect(ranked.map(\.name).contains("Party Hits (Clean)") == false)
        #expect(Set(ranked.map(\.name)) == ["Party Hits", "Clean Bangers"])
    }

    @Test("with explicit songs off, the twin that isn't clean goes instead")
    func cleanTwinWithoutExplicit() {
        let ranked = PartyPlaylistRanking.rank(
            [[playlist("Party Hits"), playlist("Party Hits (Clean)")]],
            for: .houseParty,
            allowsExplicit: false
        )
        #expect(ranked.map(\.name) == ["Party Hits (Clean)"])
    }

    @Test("All Ages puts clean and family playlists first, and keeps the clean twin")
    func allAges() {
        let ranked = PartyPlaylistRanking.rank(
            [[playlist("Kids Dance Party"), playlist("Party Anthems", apple: true), playlist("Party Anthems (Clean)"), playlist("Family Road Trip")]],
            for: .allAges,
            allowsExplicit: true
        )
        #expect(ranked.map(\.name) == ["Kids Dance Party", "Party Anthems (Clean)", "Family Road Trip"])
    }

    @Test("nothing found ranks to nothing")
    func empty() {
        #expect(PartyPlaylistRanking.rank([[], []], for: .pregame, allowsExplicit: true).isEmpty)
    }

    @Test("your own party playlists: this party's first, the rest in the order given")
    func ownPlaylists() {
        let names = ["Road Trip", "Birthday Bangers", "BBQ Summer", "Focus", "Saturday Party"]
        let found = PartyPlaylistRanking.own(names, name: { $0 }, for: .backyard)
        #expect(found == ["BBQ Summer", "Saturday Party", "Birthday Bangers"])
    }
}

@Suite("Party names and songs")
struct PartyNamesTests {
    @Test("names that say party, and names that don't", arguments: [
        ("Friday Night Party", true),
        ("Pregame Hype", true),
        ("Turn Up", true),
        ("Cookout Classics", true),
        ("Morning Coffee", false),
        ("Deep Focus", false),
    ])
    func looksLikeParty(name: String, expected: Bool) {
        #expect(PartyNames.looksLikeParty(name) == expected)
    }

    @Test("a clean version and its original share a key")
    func twinKey() {
        #expect(PartyNames.twinKey("Hip-Hop Party (Clean Version)") == PartyNames.twinKey("Hip-Hop Party"))
        #expect(PartyNames.isClean("Hip-Hop Party (Clean)"))
        #expect(PartyNames.isClean("Cleaner Living") == false)
    }

    @Test("a song suits a party by its genre")
    func suitsByGenre() {
        #expect(PartyVibe.latinNight.suits(genre: "Latin Urbano", year: nil))
        #expect(PartyVibe.latinNight.suits(genre: "Metal", year: nil) == false)
        #expect(PartyVibe.dinnerParty.suits(genre: nil, year: 1990) == false)
    }

    @Test("Throwback wants a song ten years old or more, and a year to go by")
    func throwbackYears() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: now)
        #expect(PartyVibe.throwback.suits(genre: "Pop", year: year - 10, now: now, calendar: calendar))
        #expect(PartyVibe.throwback.suits(genre: "Pop", year: year - 2, now: now, calendar: calendar) == false)
        #expect(PartyVibe.throwback.suits(genre: "Pop", year: nil, now: now, calendar: calendar) == false)
    }

    @Test("every party has two to four searches")
    func searchTerms() {
        for vibe in PartyVibe.allCases {
            #expect((2...4).contains(vibe.searchTerms.count), "\(vibe)")
        }
    }
}

@Suite("Your Party Mix")
struct PartyMixTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func play(_ title: String, hoursAgo: Double) -> CaptureStat {
        CaptureStat(
            songKey: title,
            songID: "id.\(title)",
            title: title,
            artistName: "A",
            artworkURL: "https://example.com/\(title)",
            capturedAt: now.addingTimeInterval(-hoursAgo * 3_600)
        )
    }

    func history(genres: [String: (String, Int?)], plays: [CaptureStat]) -> ListeningHistory {
        let metadata = Dictionary(uniqueKeysWithValues: genres.map {
            (HistoryImport.key(title: $0.key, artistName: "A"), SongMetadata(genre: $0.value.0, releaseYear: $0.value.1))
        })
        return ListeningHistory(plays).with(artistArtwork: [:], songMetadata: metadata)
    }

    @Test("takes played songs whose genre suits the party, and nothing unlooked-up")
    func fromHistory() {
        let plays = ["Club", "Ballad", "Unknown", "Salsa"].map { play($0, hoursAgo: 5) }
        let history = history(genres: ["Club": ("Dance", nil), "Ballad": ("Singer/Songwriter", nil), "Salsa": ("Latin", nil)], plays: plays)
        #expect(PartyMix.songs(for: .danceFloor, in: history, now: now).map(\.title) == ["Club"])
        #expect(PartyMix.songs(for: .latinNight, in: history, now: now).map(\.title) == ["Salsa"])
    }

    @Test("keeps the most played when there are more than it takes")
    func mostPlayed() {
        let plays = (1...5).flatMap { index in (0..<index).map { _ in play("Song \(index)", hoursAgo: 10) } }
        let genres = Dictionary(uniqueKeysWithValues: (1...5).map { ("Song \($0)", ("Pop", Int?.none)) })
        let songs = PartyMix.songs(for: .houseParty, in: history(genres: genres, plays: plays), limit: 2, now: now)
        #expect(Set(songs.map(\.title)) == ["Song 5", "Song 4"])
    }

    @Test("your own music: one of each song, a file before a server's copy, unsuited songs left out")
    func fromYourMusic() throws {
        let file = LocalTrack(origin: .file(path: "a.m4a"), title: "Anthem", artist: "B", genre: "Hip-Hop/Rap")
        let serverCopy = LocalTrack(origin: .server(serverID: "s", songID: "1"), title: "Anthem", artist: "B", genre: "Hip-Hop/Rap")
        let quiet = LocalTrack(origin: .file(path: "b.m4a"), title: "Lullaby", artist: "C", genre: "Classical")
        let tracks = PartyMix.tracks(for: .hipHop, from: [serverCopy, quiet, file], history: ListeningHistory([]), now: now)
        let only = try #require(tracks.first)
        #expect(tracks.count == 1)
        #expect(only.isFromServer == false)
    }

    @Test("your own music: songs you've played come before ones you haven't when it's full")
    func playedFirst() {
        let played = LocalTrack(origin: .file(path: "p.m4a"), title: "Played", artist: "A", genre: "Dance")
        let others = (1...4).map { LocalTrack(origin: .file(path: "\($0).m4a"), title: "New \($0)", artist: "Artist \($0)", genre: "Dance") }
        let history = ListeningHistory([play("Played", hoursAgo: 3)])
        let tracks = PartyMix.tracks(for: .danceFloor, from: others + [played], history: history, limit: 2, now: now)
        #expect(tracks.map(\.title).contains("Played"))
        #expect(tracks.count == 2)
    }
}
