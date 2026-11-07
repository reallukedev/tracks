import Testing
import Foundation
import TracksCore

@Suite("What someone asked Siri to play")
struct SpokenMediaTests {
    typealias Source = SpokenMedia.Source

    // MARK: - Where to play from

    @Test("a trailing source phrase is split off, keeping the rest as said", arguments: [
        ("Bad Guy on Apple Music", "Bad Guy", Source.appleMusic),
        ("Blue from my music", "Blue", .yourMusic),
        ("Halo ON APPLE MUSIC", "Halo", .appleMusic),
        ("Halo in Apple Music", "Halo", .appleMusic),
        ("Halo using apple music", "Halo", .appleMusic),
        ("Halo with Apple Music", "Halo", .appleMusic),
        ("Halo off Apple Music", "Halo", .appleMusic),
        ("Halo on Äpple Músic", "Halo", .appleMusic),
        ("  Bad Guy   on Apple Music  ", "Bad Guy", .appleMusic),
        ("Blue on your music", "Blue", .yourMusic),
        ("Blue from my own music", "Blue", .yourMusic),
        ("Blue from my files", "Blue", .yourMusic),
        ("Blue on my server", "Blue", .yourMusic),
        ("Blue on my servers", "Blue", .yourMusic),
        ("Blue from my music server", "Blue", .yourMusic),
        ("Blue from my downloads", "Blue", .yourMusic),
        ("Blue From My Downloads", "Blue", .yourMusic),
    ])
    func trailingSource(spoken: String, name: String, source: Source) {
        let result = SpokenMedia.source(in: spoken)
        #expect(result.name == name)
        #expect(result.source == source)
    }

    @Test("a name that is only a source phrase leaves an empty name", arguments: [
        ("Apple Music", Source.appleMusic),
        ("my music", .yourMusic),
        ("  My Downloads ", .yourMusic),
    ])
    func onlySource(spoken: String, source: Source) {
        let result = SpokenMedia.source(in: spoken)
        #expect(result.name == "")
        #expect(result.source == source)
    }

    @Test("without a trailing source phrase the trimmed name comes back with no source", arguments: [
        ("Bad Guy", "Bad Guy"),
        ("  Bad Guy  ", "Bad Guy"),
        ("Apple Music Hits", "Apple Music Hits"),
        ("Music", "Music"),
        ("music from my music collection", "music from my music collection"),
        ("", ""),
    ])
    func noSource(spoken: String, name: String) {
        let result = SpokenMedia.source(in: spoken)
        #expect(result.name == name)
        #expect(result.source == nil)
    }

    // MARK: - Order to try

    @Test("a source that was asked for is the only one tried", arguments: Source.allCases, Source.allCases)
    func askedOnly(current: Source, asked: Source) {
        #expect(SpokenMedia.order(current: current, asked: asked, otherAvailable: true) == [asked])
        #expect(SpokenMedia.order(current: current, asked: asked, otherAvailable: false) == [asked])
    }

    @Test("with nothing asked, the current source first and the other only when available", arguments: Source.allCases)
    func notAsked(current: Source) {
        let other: Source = current == .appleMusic ? .yourMusic : .appleMusic
        #expect(SpokenMedia.order(current: current, asked: nil, otherAvailable: true) == [current, other])
        #expect(SpokenMedia.order(current: current, asked: nil, otherAvailable: false) == [current])
    }

    @Test("each source's other is the other one")
    func other() {
        #expect(Source.appleMusic.other == .yourMusic)
        #expect(Source.yourMusic.other == .appleMusic)
    }

    // MARK: - Tracks' own mixes

    @Test("a whole mix name picks that mix", arguments: [
        ("Tracks Radio", "station"), ("my station", "station"), ("my radio", "station"),
        ("My Mix", "forYou"),
        ("Discover", "discover"), ("something new", "discover"),
        ("On Repeat", "onRepeat"),
        ("All-Time Favorites", "favorites"), ("all time favorites", "favorites"),
        ("my favorites", "favorites"), ("my favourites", "favorites"),
        ("Deep Cuts", "deepCuts"), ("Radio Finds", "radioFinds"),
        ("chill music", "chill"), ("something chill", "chill"),
        ("sad songs", "heartbreak"), ("driving music", "drive"), ("workout music", "workout"),
        ("sleep music", "sleep"), ("party music", "party"), ("love songs", "love"),
        ("focus music", "focus"), ("energy", "energy"), ("feel good music", "feelGood"),
        ("  ON REPEAT  ", "onRepeat"), ("Dëep Cüts", "deepCuts"),
    ])
    func choice(spoken: String, expected: String) {
        #expect(SpokenMedia.choice(named: spoken) == expected)
    }

    @Test("part of a mix name, or more than one, is not a mix", arguments: [
        "my mixtape", "discover weekly", "radio", "", "Bad Guy",
    ])
    func notAChoice(spoken: String) {
        #expect(SpokenMedia.choice(named: spoken) == nil)
    }

    // MARK: - Moods

    @Test("a mood heard at the start of a word", arguments: [
        ("something chill", "chill"), ("Relaxing music", "chill"), ("calm down", "chill"), ("mellow", "chill"),
        ("study beats", "focus"), ("concentration", "focus"), ("Focus", "focus"),
        ("work out mix", "workout"), ("gym", "workout"), ("running songs", "workout"), ("exercise", "workout"),
        ("music for dancing", "party"), ("party", "party"),
        ("bedtime", "sleep"), ("sleepy", "sleep"),
        ("romantic dinner", "love"), ("lovely", "love"),
        ("heartbroken", "heartbreak"), ("breakup songs", "heartbreak"), ("sad", "heartbreak"),
        ("happy", "feelGood"), ("feel good", "feelGood"), ("upbeat", "feelGood"), ("cheerful", "feelGood"),
        ("energetic", "energy"), ("pump up", "energy"), ("hype", "energy"),
        ("Driving", "drive"), ("road trip", "drive"), ("roadtrip", "drive"),
        ("chill-out", "chill"), ("RÉLAXING", "chill"),
    ])
    func mood(spoken: String, expected: String) {
        #expect(SpokenMedia.mood(in: spoken) == expected)
    }

    @Test("a mood inside a word, or none at all, is no mood", arguments: [
        "unhappy", "brunch", "Gloves", "", "Bad Guy",
    ])
    func noMood(spoken: String) {
        #expect(SpokenMedia.mood(in: spoken) == nil)
    }

    @Test("of two moods, the one said first wins")
    func firstMoodWins() {
        #expect(SpokenMedia.mood(in: "sad then happy") == "heartbreak")
        #expect(SpokenMedia.mood(in: "happy and sad") == "feelGood")
    }

    // MARK: - Genres

    @Test("a name that is just a genre finds its page", arguments: [
        ("jazz", "jazz"), ("Jazz", "jazz"),
        ("some hip hop", "hip-hop"), ("hip-hop", "hip-hop"),
        ("Classical music", "classical"), ("country songs", "country"), ("rock tunes", "rock"),
        ("K-Pop", "k-pop"), ("k pop", "k-pop"),
        ("R&B", "r-b"),
        ("indie", "alternative"), ("house music", "electronic"),
    ])
    func genre(spoken: String, id: String) {
        #expect(SpokenMedia.genre(named: spoken)?.id == id)
    }

    @Test("a name that isn't only a genre finds none", arguments: [
        "Bad Guy", "music", "", "the best jazz of all",
    ])
    func notAGenre(spoken: String) {
        #expect(SpokenMedia.genre(named: spoken) == nil)
    }
}
