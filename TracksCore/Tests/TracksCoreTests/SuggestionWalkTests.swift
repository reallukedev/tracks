import Testing
@testable import TracksCore

struct SuggestionWalkTests {
    struct Artist: Equatable {
        let id: Int
        let name: String
    }

    let similar = [
        Artist(id: 1, name: "Nova Harbor"),
        Artist(id: 2, name: "Mara Solis"),
        Artist(id: 3, name: "Paper Lanterns"),
        Artist(id: 4, name: "Umbra"),
    ]

    private func step(
        _ artists: [Artist],
        visited: inout Set<Int>,
        heard: Set<String> = [],
        leftOut: Set<String> = []
    ) -> SuggestionWalk.Step<Artist> {
        SuggestionWalk.step(
            from: artists,
            id: \.id,
            name: \.name,
            visited: &visited,
            heard: heard,
            isLeftOut: { leftOut.contains($0) }
        )
    }

    @Test("Having played every artist like yours still leaves the walk somewhere to go")
    func walksThroughKnownArtists() {
        var visited = Set<Int>()
        let heard = Set(similar.map { StatsCalculator.folded($0.name) })

        let result = step(similar, visited: &visited, heard: heard)

        #expect(result.walk == similar)
        #expect(result.new.isEmpty)
    }

    @Test("Never-played artists are suggested, and walked before the ones you know")
    func newArtistsComeFirst() {
        var visited = Set<Int>()
        let heard: Set = [StatsCalculator.folded("Nova Harbor"), StatsCalculator.folded("Paper Lanterns")]

        let result = step(similar, visited: &visited, heard: heard)

        #expect(result.new.map(\.name) == ["Mara Solis", "Umbra"])
        #expect(result.walk.map(\.name) == ["Mara Solis", "Umbra", "Nova Harbor", "Paper Lanterns"])
    }

    @Test("Artists already on the walk, or left out, are skipped; each artist is taken once")
    func skipsVisitedAndLeftOut() {
        var visited: Set = [1]
        let repeated = similar + [similar[1]]

        let result = step(repeated, visited: &visited, leftOut: ["Umbra"])

        #expect(result.walk.map(\.id) == [2, 3])
        #expect(visited == [1, 2, 3])
    }

    @Test("An artist counts as played however the history spelled the name", arguments: [
        "mara solis",
        "MARA SOLÍS",
        "Mara Solís",
    ])
    func matchesHeardFolded(spelling: String) {
        var visited = Set<Int>()

        let result = step([similar[1]], visited: &visited, heard: [StatsCalculator.folded(spelling)])

        #expect(result.new.isEmpty)
        #expect(result.walk == [similar[1]])
    }
}
