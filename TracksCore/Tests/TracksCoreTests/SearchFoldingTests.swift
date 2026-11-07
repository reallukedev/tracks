import Testing
@testable import TracksCore

@Suite("Searching your music")
struct SearchFoldingTests {
    func track(_ title: String, artist: String = "Mara Solis", album: String? = "Coastlines") -> LocalTrack {
        LocalTrack(origin: .file(path: "\(artist)/\(title).flac"), title: title, artist: artist, album: album)
    }

    @Test("case, accents and punctuation aside, apostrophes dropped, & read as and", arguments: [
        ("Don't Stop", "dont stop"),
        ("Don\u{2019}t Stop", "dont stop"),
        ("AC/DC", "ac dc"),
        ("Beyoncé", "beyonce"),
        ("Sigur Rós", "sigur ros"),
        ("Simon & Garfunkel", "simon and garfunkel"),
        ("  Hello,   World!  ", "hello world"),
        ("(What's the Story) Morning Glory?", "whats the story morning glory"),
    ])
    func folding(text: String, folded: String) {
        #expect(SearchFolding.fold(text) == folded)
    }

    @Test("a word a letter off, or the start of one, is near", arguments: [
        ("beyonse", "beyonce", true),   // wrong
        ("beyoce", "beyonce", true),    // missing
        ("beyoncee", "beyonce", true),  // extra
        ("byeonce", "beyonce", true),   // swapped
        ("lulab", "lullaby", true),     // the start of it, a letter missing
        ("garden", "garden", true),
        ("gardne", "garden", true),
        ("grdnx", "garden", false),
        ("caf", "cafe", false),         // too short to guess at
        ("ocean", "halo", false),
    ])
    func near(typed: String, word: String, isNear: Bool) {
        #expect(SearchFolding.isNear(typed, word) == isNear)
    }

    @Test("a song of that very name comes before ones with it in a longer name, or its album's")
    func exactFirst() {
        let index = LocalLibraryIndex(tracks: [
            track("Café Night"),
            track("Two Lullaby Café", artist: "Juniper Lane"),
            track("Paper", album: "Café"),
            track("Café", artist: "AC/DC"),
        ])
        #expect(index.search("cafe").tracks.map(\.title) == ["Café", "Café Night", "Two Lullaby Café", "Paper"])
    }

    @Test("punctuation typed or not finds the same songs and artists")
    func punctuation() {
        let index = LocalLibraryIndex(tracks: [track("Don't Stop", artist: "Cassia Ray"), track("Blue", artist: "AC/DC")])
        #expect(index.search("dont stop").tracks.map(\.title) == ["Don't Stop"])
        #expect(index.search("don't").tracks.map(\.title) == ["Don't Stop"])
        #expect(index.search("ac dc").artists.map(\.name) == ["AC/DC"])
        #expect(index.search("ac/dc").tracks.map(\.title) == ["Blue"])
    }

    @Test("with nothing found, a typo still finds it; with something found, it doesn't widen")
    func typos() {
        let index = LocalLibraryIndex(tracks: [track("Paper", artist: "Beyoncé"), track("Lullaby Ivy"), track("Halo")])
        #expect(index.search("beyonse").artists.map(\.name) == ["Beyoncé"])
        #expect(index.search("lulaby").tracks.map(\.title) == ["Lullaby Ivy"])
        #expect(index.search("halo").tracks.map(\.title) == ["Halo"])
        #expect(index.search("zzzzz").tracks.isEmpty)
    }

    @Test("a server's songs are ranked as your own are, equal ones in the order they came")
    func rankedServerSongs() {
        let found = [track("Café Night"), track("Two Lullaby Café"), track("Café", artist: "AC/DC"), track("Café", artist: "The Velvet Hours")]
        #expect(LocalLibraryIndex.ranked(found, for: "Café").map(\.artist) == ["AC/DC", "The Velvet Hours", "Mara Solis", "Mara Solis"])
        #expect(LocalLibraryIndex.ranked(found, for: " ").map(\.title) == found.map(\.title))
    }

    @Test("the top result folds the same way")
    func topResult() {
        #expect(SearchRanking.topKind(for: "acdc", artist: "AC/DC", album: nil, song: "Blue") == .song)
        #expect(SearchRanking.topKind(for: "ac dc", artist: "AC/DC", album: nil, song: "Blue") == .artist)
        #expect(SearchRanking.topKind(for: "dont", artist: nil, album: nil, song: "Don't") == .song)
    }
}
