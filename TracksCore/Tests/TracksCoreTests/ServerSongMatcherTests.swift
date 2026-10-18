import Testing
@testable import TracksCore

@Suite("Finding a suggested song on a server")
struct ServerSongMatcherTests {
    func song(_ title: String, by artist: String, id: String = "found") -> SubsonicSong {
        SubsonicSong(id: id, title: title, artist: artist)
    }

    @Test("names written differently are still the same song", arguments: [
        ("Havana (feat. Young Thug)", "Camila Cabello", "Havana", "Camila Cabello"),
        ("MISS MY DAWG", "Yeat & Drake", "Miss My Dawg", "Yeat"),
        ("Here Comes the Sun - Remastered 2019", "The Beatles", "Here Comes The Sun", "The Beatles"),
        ("Dance For You", "Beyoncé", "Dance for You", "Beyonce"),
        ("Dog Days Are Over", "Florence + the Machine", "Dog Days Are Over", "Florence + The Machine"),
    ])
    func sameSong(title: String, artist: String, foundTitle: String, foundArtist: String) throws {
        let match = try #require(ServerSongMatcher.bestMatch(title: title, artist: artist, in: [song(foundTitle, by: foundArtist)]))
        #expect(match.title == foundTitle)
    }

    @Test("a different recording, or someone else's song of that name, isn't", arguments: [
        ("Tide", "daste.", "Tide (Live)", "daste."),
        ("Tide", "daste.", "Tide", "Lucy Rose"),
        ("Havana", "Camila Cabello", "Havana Nights", "Camila Cabello"),
    ])
    func differentSong(title: String, artist: String, foundTitle: String, foundArtist: String) {
        #expect(ServerSongMatcher.bestMatch(title: title, artist: artist, in: [song(foundTitle, by: foundArtist)]) == nil)
    }

    @Test("a song named exactly the same wins over a looser match found first")
    func exactFirst() {
        let loose = song("Havana (feat. Young Thug)", by: "Camila Cabello", id: "loose")
        let exact = song("Havana", by: "Camila Cabello", id: "exact")
        #expect(ServerSongMatcher.bestMatch(title: "Havana", artist: "Camila Cabello", in: [loose, exact])?.id == "exact")
    }

    @Test("nothing to look through finds nothing")
    func empty() {
        #expect(ServerSongMatcher.bestMatch(title: "Tide", artist: "daste.", in: []) == nil)
    }
}
