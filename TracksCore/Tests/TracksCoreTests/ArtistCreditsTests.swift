import Testing
@testable import TracksCore

@Suite("Artist credits")
struct ArtistCreditsTests {
    /// "Name" for a primary artist, "+Name" for a featured one, in credit order.
    func credits(_ artist: String, title: String = "", catalog: [String]? = nil) -> [String] {
        ArtistCredits.parse(artist: artist, title: title, catalogArtists: catalog).map {
            $0.role == .featured ? "+" + $0.name : $0.name
        }
    }

    @Test("one artist is one credit, trimmed, and a blank name is none", arguments: [
        ("Taylor Swift", ["Taylor Swift"]),
        ("  Adele ", ["Adele"]),
        ("", []),
        ("   ", []),
        // Separators inside a word, or without the spaces around them, aren't separators.
        ("AC/DC", ["AC/DC"]),
        ("Lil Nas X", ["Lil Nas X"]),
        ("Rag'n'Bone Man", ["Rag'n'Bone Man"]),
        ("Saxon", ["Saxon"]),
        ("Blair", ["Blair"]),
        ("Andromeda", ["Andromeda"]),
        ("Little Feat", ["Little Feat"]),
        ("Featherweight", ["Featherweight"]),
    ])
    func solo(artist: String, expected: [String]) {
        #expect(credits(artist) == expected)
    }

    @Test("artists credited together each count as a main artist", arguments: [
        ("Shawn Mendes & Camila Cabello", ["Shawn Mendes", "Camila Cabello"]),
        ("Lady Gaga and Bradley Cooper", ["Lady Gaga", "Bradley Cooper"]),
        ("Calvin Harris x Dua Lipa", ["Calvin Harris", "Dua Lipa"]),
        ("Rosalía × Ozuna", ["Rosalía", "Ozuna"]),
        ("David Guetta vs. Showtek", ["David Guetta", "Showtek"]),
        ("Mara Solis; Umbra", ["Mara Solis", "Umbra"]),
        ("Lil Nas X & Jack Harlow", ["Lil Nas X", "Jack Harlow"]),
        ("Beyoncé, JAY-Z", ["Beyoncé", "JAY-Z"]),
        ("Mark Ronson, Bruno Mars, Lil Nas X & Cardi B", ["Mark Ronson", "Bruno Mars", "Lil Nas X", "Cardi B"]),
        ("A, B and C", ["A", "B", "C"]),
        ("Umbra, Mara Solis, & Yuki Tanabe", ["Umbra", "Mara Solis", "Yuki Tanabe"]),
        ("Umbra, Mara Solis, and Yuki Tanabe", ["Umbra", "Mara Solis", "Yuki Tanabe"]),
        // The same artist twice is credited once.
        ("Umbra & umbra", ["Umbra"]),
    ])
    func together(artist: String, expected: [String]) {
        #expect(credits(artist) == expected)
    }

    @Test("a featured artist is credited after the main ones, however it's written", arguments: [
        "Drake feat. Rihanna",
        "Drake Feat. Rihanna",
        "Drake ft. Rihanna",
        "Drake ft Rihanna",
        "Drake featuring Rihanna",
        "Drake (feat. Rihanna)",
        "Drake [feat. Rihanna]",
        "Drake (with Rihanna)",
        "Drake with Rihanna",
    ])
    func featured(artist: String) {
        #expect(credits(artist) == ["Drake", "+Rihanna"])
    }

    @Test("several featured artists, after several main ones")
    func severalFeatured() {
        #expect(credits("Mark Ronson feat. Bruno Mars & Mystikal") == ["Mark Ronson", "+Bruno Mars", "+Mystikal"])
        #expect(credits("Umbra & Mara Solis feat. Yuki Tanabe, Nova Harbor") == ["Umbra", "Mara Solis", "+Yuki Tanabe", "+Nova Harbor"])
        // A marker with no one after it credits no one.
        #expect(credits("Drake feat.") == ["Drake"])
        #expect(credits("Drake ()") == ["Drake ()"])
    }

    @Test("a feature in the title is credited, as Apple Music writes them", arguments: [
        ("Lil Nas X", "Old Town Road (feat. Billy Ray Cyrus) [Remix]", ["Lil Nas X", "+Billy Ray Cyrus"]),
        ("Justin Bieber", "Peaches (feat. Daniel Caesar & Giveon)", ["Justin Bieber", "+Daniel Caesar", "+Giveon"]),
        ("The Kid LAROI", "STAY (with Justin Bieber)", ["The Kid LAROI", "+Justin Bieber"]),
        ("Calvin Harris", "Feel So Close [ft. Nova Harbor]", ["Calvin Harris", "+Nova Harbor"]),
        ("Umbra", "Night Drive feat. Mara Solis", ["Umbra", "+Mara Solis"]),
        // Already credited in the artist: once, and as a main artist if they're one.
        ("Drake feat. Rihanna", "Work (feat. Drake)", ["Drake", "+Rihanna"]),
    ])
    func titleFeatures(artist: String, title: String, expected: [String]) {
        #expect(credits(artist, title: title) == expected)
    }

    @Test("a title's words in brackets aren't mistaken for a feature", arguments: [
        "Stand By Me (With Strings)",
        "Señorita",
        "Feather (Remix)",
        "Feat of Clay",
        "Featherstone (Live)",
        "Love Me Harder [Acoustic]",
    ])
    func titleWithoutFeatures(title: String) {
        #expect(credits("Umbra", title: title) == ["Umbra"])
    }

    @Test("a band with a separator in its name stays whole", arguments: [
        "Simon & Garfunkel",
        "Earth, Wind & Fire",
        "Tyler, The Creator",
        "Florence + the Machine",
        "Mumford & Sons",
        "Hall & Oates",
        "Crosby, Stills & Nash",
        "Crosby, Stills, Nash & Young",
        "Kool & the Gang",
        "Bob Marley & The Wailers",
        "Belle and Sebastian",
        "Of Monsters and Men",
        "Duke Ellington and His Orchestra",
        "Chase & Status",
        "Above & Beyond",
        "Years & Years",
        "Iron & Wine",
        "Angus & Julia Stone",
        "Marina and the Diamonds",
        "Echo & the Bunnymen",
        "Emerson, Lake & Palmer",
        "Blood, Sweat & Tears",
        "Peter Bjorn and John",
        "Dan + Shay",
        "Chloe x Halle",
        "Willie Nelson & Friends",
        "EARTH, WIND & FIRE",
        "Earth Wind & Fire",
    ])
    func bands(artist: String) {
        #expect(credits(artist) == [artist])
    }

    @Test("a band is found whole inside a longer credit")
    func bandsInCollaborations() {
        #expect(credits("Bob Marley & The Wailers feat. Lauryn Hill") == ["Bob Marley & The Wailers", "+Lauryn Hill"])
        #expect(credits("Earth, Wind & Fire & The Emotions") == ["Earth, Wind & Fire", "The Emotions"])
        #expect(credits("Simon & Garfunkel, Mara Solis") == ["Simon & Garfunkel", "Mara Solis"])
        #expect(credits("Umbra feat. Tyler, The Creator") == ["Umbra", "+Tyler, The Creator"])
        #expect(credits("Mara Solis x Chloe x Halle") == ["Mara Solis", "Chloe x Halle"])
    }

    @Test("an artist whose name starts with The isn't taken for someone's band")
    func theArtists() {
        #expect(credits("Ariana Grande & The Weeknd") == ["Ariana Grande", "The Weeknd"])
        #expect(credits("Kendrick Lamar and The Weeknd") == ["Kendrick Lamar", "The Weeknd"])
    }

    @Test("Apple Music's own list of artists settles what the name can't")
    func catalog() {
        // An unknown band: split by the name alone, kept whole when the catalog says so.
        #expect(credits("Fern & Fable") == ["Fern", "Fable"])
        #expect(credits("Fern & Fable", catalog: ["Fern & Fable"]) == ["Fern & Fable"])
        // An unknown "The" artist the name alone keeps with the one before.
        #expect(credits("Umbra & The Lanterns") == ["Umbra & The Lanterns"])
        #expect(credits("Umbra & The Lanterns", catalog: ["Umbra", "The Lanterns"]) == ["Umbra", "The Lanterns"])
        // A featured artist from the title who isn't in the catalog's list is still credited,
        // and one who is keeps their role.
        #expect(credits("Lil Nas X", title: "Old Town Road (feat. Billy Ray Cyrus)", catalog: ["Lil Nas X"]) == ["Lil Nas X", "+Billy Ray Cyrus"])
        #expect(credits("Drake feat. Rihanna", catalog: ["Rihanna", "Drake"]) == ["Drake", "+Rihanna"])
        // Names the credit doesn't mention, like another spelling, are no help: the name decides.
        #expect(credits("Fern & Fable", catalog: ["Someone Else"]) == ["Fern", "Fable"])
        #expect(credits("Fern & Fable", catalog: []) == ["Fern", "Fable"])
    }

    @Test("identities ignore case and accents, and the lead is the first main artist")
    func identities() {
        let parsed = ArtistCredits.parse(artist: "Beyoncé & JAY-Z feat. Mara Solís")
        #expect(parsed.map(\.identity) == ["beyonce", "jay-z", "mara solis"])
        #expect(ArtistCredits.lead(of: "Beyoncé & JAY-Z feat. Mara Solís") == "Beyoncé")
        #expect(ArtistCredits.lead(of: "Simon & Garfunkel") == "Simon & Garfunkel")
        #expect(ArtistCredits.lead(of: "") == "")
    }

    @Test("a name that grows when it's folded is still cut at its own separators")
    func foldingLength() {
        #expect(credits("İSMAİL YK feat. Nova Harbor") == ["İSMAİL YK", "+Nova Harbor"])
        #expect(credits("İİİİİİİİİİİİ & Ⱥ Ⱥ") == ["İİİİİİİİİİİİ", "Ⱥ Ⱥ"])
    }
}
