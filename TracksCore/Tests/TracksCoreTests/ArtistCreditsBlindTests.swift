import Testing
@testable import TracksCore

/// One parse input and its expected credits, written as names with featured ones prefixed "ft:".
struct CreditCase: Sendable, CustomTestStringConvertible {
    let artist: String
    var title = ""
    var catalog: [String]? = nil
    let expected: [String]

    var testDescription: String {
        var text = "\"\(artist)\""
        if !title.isEmpty { text += " / \"\(title)\"" }
        if let catalog { text += " catalog \(catalog)" }
        return text
    }
}

@Suite("Artist credits, from the spec")
struct ArtistCreditsBlindTests {
    static func described(_ credits: [ArtistCredit]) -> [String] {
        credits.map { $0.role == .primary ? $0.name : "ft:\($0.name)" }
    }

    static func parsed(_ item: CreditCase) -> [String] {
        described(ArtistCredits.parse(artist: item.artist, title: item.title, catalogArtists: item.catalog))
    }

    @Test("A blank artist has no credits", arguments: ["", "   ", "\n\t "])
    func blank(artist: String) {
        #expect(ArtistCredits.parse(artist: artist).isEmpty)
    }

    @Test("A single artist is one primary credit, trimmed", arguments: [
        CreditCase(artist: "  Mara Solis  ", expected: ["Mara Solis"]),
        CreditCase(artist: "AC/DC", expected: ["AC/DC"]),
        CreditCase(artist: "BTS (방탄소년단)", expected: ["BTS (방탄소년단)"]),
        CreditCase(artist: "Little Feat", expected: ["Little Feat"]),
        CreditCase(artist: "Drake feat.", expected: ["Drake"]),
        CreditCase(artist: "Umbra X Mara Solis", expected: ["Umbra X Mara Solis"]),
    ])
    func singleArtist(item: CreditCase) {
        #expect(Self.parsed(item) == item.expected)
    }

    @Test("Every primary separator splits two artists", arguments: [
        ", ", " & ", " and ", " AND ", " And ", " + ", " x ", " × ", " vs. ", " vs ", " / ", "; ", ", & ", ", and ",
    ])
    func primarySeparators(separator: String) {
        let credits = ArtistCredits.parse(artist: "Umbra\(separator)Mara Solis")
        #expect(Self.described(credits) == ["Umbra", "Mara Solis"])
    }

    @Test("Real credits split into their artists in written order", arguments: [
        CreditCase(artist: "Silk Sonic, Bruno Mars & Anderson .Paak", expected: ["Silk Sonic", "Bruno Mars", "Anderson .Paak"]),
        CreditCase(artist: "Kanye West & JAY-Z", expected: ["Kanye West", "JAY-Z"]),
        CreditCase(artist: "Post Malone & Swae Lee", expected: ["Post Malone", "Swae Lee"]),
        CreditCase(artist: "Lil Nas X & Jack Harlow", expected: ["Lil Nas X", "Jack Harlow"]),
        CreditCase(artist: "Umbra, Mara Solis, and Nova Harbor", expected: ["Umbra", "Mara Solis", "Nova Harbor"]),
        CreditCase(artist: "Ariana Grande & The Weeknd", expected: ["Ariana Grande", "The Weeknd"]),
        CreditCase(artist: "Fern & Fable", expected: ["Fern", "Fable"]),
    ])
    func realCredits(item: CreditCase) {
        #expect(Self.parsed(item) == item.expected)
    }

    @Test("Bands and named ensembles stay whole", arguments: [
        "Simon & Garfunkel", "SIMON & GARFUNKEL", "Earth, Wind & Fire", "Tyler, The Creator",
        "Crosby, Stills, Nash & Young", "Belle and Sebastian", "Dan + Shay", "Chloe x Halle",
        "Florence + the Machine", "Mumford & Sons", "Duke Ellington and His Orchestra",
        "Willie Nelson & Friends", "Bob Marley & The Wailers", "Umbra & The Lanterns",
        "Peter, Paul and Mary", "Tegan and Sara",
    ])
    func bandsStayWhole(artist: String) {
        #expect(Self.described(ArtistCredits.parse(artist: artist)) == [artist])
    }

    @Test("A known band inside a longer credit is one of its credits")
    func bandInsideCredit() {
        let credits = ArtistCredits.parse(artist: "Simon & Garfunkel, Someone")
        #expect(Self.described(credits) == ["Simon & Garfunkel", "Someone"])
    }

    @Test("Every featured marker in the artist makes a featured credit", arguments: [
        "Umbra feat. Mara Solis", "Umbra FEAT. Mara Solis", "Umbra feat Mara Solis", "Umbra ft. Mara Solis",
        "Umbra ft Mara Solis", "Umbra featuring Mara Solis", "Umbra with Mara Solis", "Umbra With Mara Solis",
        "Umbra (feat. Mara Solis)", "Umbra [feat. Mara Solis]", "Umbra (ft. Mara Solis)",
        "Umbra (featuring Mara Solis)", "Umbra (with Mara Solis)",
    ])
    func artistFeatureMarkers(artist: String) {
        #expect(Self.described(ArtistCredits.parse(artist: artist)) == ["Umbra", "ft:Mara Solis"])
    }

    @Test("A featured list is split by the separators too")
    func featuredListSplits() {
        let credits = ArtistCredits.parse(artist: "Daft Punk feat. Pharrell Williams & Nile Rodgers")
        #expect(Self.described(credits) == ["Daft Punk", "ft:Pharrell Williams", "ft:Nile Rodgers"])
    }

    @Test("Features in the title are credited", arguments: [
        CreditCase(artist: "Umbra", title: "Golden Moon (feat. Mara Solis)", expected: ["Umbra", "ft:Mara Solis"]),
        CreditCase(artist: "Umbra", title: "Golden Moon [feat. Mara Solis]", expected: ["Umbra", "ft:Mara Solis"]),
        CreditCase(artist: "Umbra", title: "Golden Moon (ft. Mara Solis)", expected: ["Umbra", "ft:Mara Solis"]),
        CreditCase(artist: "Umbra", title: "Golden Moon (featuring Mara Solis)", expected: ["Umbra", "ft:Mara Solis"]),
        CreditCase(artist: "Umbra", title: "Golden Moon (with Mara Solis)", expected: ["Umbra", "ft:Mara Solis"]),
        CreditCase(artist: "Umbra", title: "Golden Moon feat. Mara Solis - Radio Edit", expected: ["Umbra", "ft:Mara Solis"]),
        CreditCase(artist: "Umbra", title: "Golden Moon ft. Mara Solis (Remix)", expected: ["Umbra", "ft:Mara Solis"]),
        CreditCase(artist: "Umbra", title: "Golden Moon featuring Mara Solis [Live]", expected: ["Umbra", "ft:Mara Solis"]),
        CreditCase(artist: "Umbra", title: "Golden Moon (feat. Mara Solis & Nova Harbor)", expected: ["Umbra", "ft:Mara Solis", "ft:Nova Harbor"]),
    ])
    func titleFeatures(item: CreditCase) {
        #expect(Self.parsed(item) == item.expected)
    }

    @Test("A title bracket that isn't a feature adds nobody", arguments: [
        "Golden Moon (With Strings)", "Golden Moon (Remix)", "Golden Moon ()", "Golden Moon [Live]",
    ])
    func titleNonFeatures(title: String) {
        #expect(Self.described(ArtistCredits.parse(artist: "Umbra", title: title)) == ["Umbra"])
    }

    @Test("Features from the artist and the title are both kept, after the primary")
    func featuresFromBoth() {
        let credits = ArtistCredits.parse(artist: "Umbra feat. Mara Solis", title: "Golden Moon (feat. Nova Harbor)")
        #expect(credits.first?.name == "Umbra")
        #expect(credits.first?.role == .primary)
        #expect(credits.count == 3)
        #expect(Set(credits.dropFirst().map(\.name)) == ["Mara Solis", "Nova Harbor"])
        #expect(credits.dropFirst().allSatisfy { $0.role == .featured })
    }

    @Test("Each artist appears once, and primary wins over featured", arguments: [
        CreditCase(artist: "Umbra & umbra", expected: ["Umbra"]),
        CreditCase(artist: "Beyoncé & BEYONCE", expected: ["Beyoncé"]),
        CreditCase(artist: "Umbra feat. Mara Solis", title: "Golden Moon (feat. Mara Solis)", expected: ["Umbra", "ft:Mara Solis"]),
        CreditCase(artist: "Umbra feat. Umbra", expected: ["Umbra"]),
        CreditCase(artist: "Umbra & Mara Solis", title: "Golden Moon (feat. mara solis)", expected: ["Umbra", "Mara Solis"]),
    ])
    func deduplicates(item: CreditCase) {
        #expect(Self.parsed(item) == item.expected)
    }

    @Test("Identity is folded while the name keeps how it was written")
    func identityFolds() throws {
        let credit = try #require(ArtistCredits.parse(artist: "  Beyoncé ").first)
        #expect(credit.name == "Beyoncé")
        #expect(credit.identity == "beyonce")
        #expect(credit.role == .primary)
    }

    @Test("The catalog decides the credits when it matches the text", arguments: [
        CreditCase(artist: "Fern & Fable", catalog: ["Fern & Fable"], expected: ["Fern & Fable"]),
        CreditCase(artist: "Umbra & Mara Solis", catalog: ["Mara Solis", "Umbra"], expected: ["Mara Solis", "Umbra"]),
        CreditCase(artist: "Fern & Fable feat. Mara Solis", catalog: ["Fern & Fable", "Mara Solis"], expected: ["Fern & Fable", "ft:Mara Solis"]),
        CreditCase(artist: "Fern & Fable feat. Mara Solis", catalog: ["Fern & Fable"], expected: ["Fern & Fable", "ft:Mara Solis"]),
        CreditCase(artist: "Fern & Fable", title: "Golden Moon (feat. Mara Solis)", catalog: ["fern & fable", "Mara Solis"], expected: ["fern & fable", "ft:Mara Solis"]),
    ])
    func catalogUsed(item: CreditCase) {
        #expect(Self.parsed(item) == item.expected)
    }

    @Test("A catalog that doesn't match the text is ignored", arguments: [
        CreditCase(artist: "Fern & Fable", catalog: ["Someone Else"], expected: ["Fern", "Fable"]),
        CreditCase(artist: "Fern & Fable", catalog: ["Fern & Fable", "Someone Else"], expected: ["Fern", "Fable"]),
        CreditCase(artist: "Fern & Fable", catalog: [], expected: ["Fern", "Fable"]),
        CreditCase(artist: "Fernando & Fable", catalog: ["Fern"], expected: ["Fernando", "Fable"]),
    ])
    func catalogIgnored(item: CreditCase) {
        #expect(Self.parsed(item) == item.expected)
    }

    @Test("The lead is the first primary credit, or the trimmed input", arguments: [
        ("Daft Punk feat. Pharrell Williams & Nile Rodgers", "Daft Punk"),
        ("  Kanye West & JAY-Z ", "Kanye West"),
        ("Mumford & Sons", "Mumford & Sons"),
        ("BTS (방탄소년단)", "BTS (방탄소년단)"),
        ("   ", ""),
    ])
    func lead(artist: String, expected: String) {
        #expect(ArtistCredits.lead(of: artist) == expected)
    }

    @Test("The several-credits hint is never false when parse finds more than one", arguments: [
        CreditCase(artist: "Silk Sonic, Bruno Mars & Anderson .Paak", expected: []),
        CreditCase(artist: "Daft Punk feat. Pharrell Williams", expected: []),
        CreditCase(artist: "Umbra", title: "Golden Moon (feat. Mara Solis)", expected: []),
        CreditCase(artist: "Umbra x Mara Solis", expected: []),
        CreditCase(artist: "Umbra (with Mara Solis)", expected: []),
        CreditCase(artist: "Ariana Grande & The Weeknd", expected: []),
        CreditCase(artist: "Umbra; Mara Solis", expected: []),
    ])
    func hintCoversParse(item: CreditCase) {
        #expect(ArtistCredits.parse(artist: item.artist, title: item.title).count > 1)
        #expect(ArtistCredits.mayCreditSeveral(artist: item.artist, title: item.title))
    }
}
