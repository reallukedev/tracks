import Testing
import Foundation
@testable import TracksCore

@Suite("Picked for you from a server")
struct ServerMixTests {
    func song(_ title: String, by artist: String) -> LocalTrack {
        LocalTrack(origin: .server(serverID: "octo", songID: "\(artist)-\(title)"), title: title, artist: artist)
    }

    @Test("what you play leads, the artists you picked fill in, then your library's")
    func seedOrder() {
        let seeds = ServerMix.seeds(picked: ["Mara Solis", "Lumen"], played: ["Nova Harbor"], library: ["Glass Coast"], limit: 5)
        #expect(seeds == ["Nova Harbor", "Mara Solis", "Lumen", "Glass Coast"])
    }

    @Test("as your listening grows, the artists you picked give way, keeping one place")
    func picksGiveWay() {
        let played = (1...8).map { "Played \($0)" }
        let seeds = ServerMix.seeds(picked: ["Mara Solis", "Lumen"], played: played, library: [], limit: 5, rotation: 3)
        #expect(Array(seeds.prefix(3)) == ["Played 1", "Played 2", "Played 3"])
        #expect(seeds.filter { ["Mara Solis", "Lumen"].contains($0) } == ["Mara Solis"])
        #expect(seeds.count == 5)
    }

    @Test("past your top three, which artists start it changes with the day")
    func rotation() {
        let played = (1...13).map { "Played \($0)" }
        let days = Set((0..<8).map { ServerMix.seeds(picked: [], played: played, library: [], rotation: UInt64($0)) })
        #expect(days.count > 1)
        #expect(days.allSatisfy { Array($0.prefix(3)) == ["Played 1", "Played 2", "Played 3"] })
        #expect(ServerMix.seeds(picked: [], played: played, library: [], rotation: 5) == ServerMix.seeds(picked: [], played: played, library: [], rotation: 5))
    }

    @Test("with no history and no library, the artists you picked are enough")
    func noHistory() {
        #expect(ServerMix.seeds(picked: ["Mara Solis", "Nova Harbor"], played: [], library: []) == ["Mara Solis", "Nova Harbor"])
    }

    @Test("with nothing picked, played or owned, there's nothing to start from")
    func nothing() {
        #expect(ServerMix.seeds(picked: [], played: [], library: []).isEmpty)
    }

    @Test("an artist is started from once, however it's cased or accented, and blanks are skipped")
    func seedsOnce() {
        let seeds = ServerMix.seeds(picked: ["Beyoncé", "  "], played: ["beyonce", "Mara Solis"], library: ["MARA SOLIS"])
        #expect(seeds == ["beyonce", "Mara Solis"])
    }

    @Test("songs you have and new ones are woven together, one of yours to two new")
    func blend() {
        let mixed = ServerMix.blend(owned: ["O1", "O2", "O3"], new: ["N1", "N2", "N3", "N4", "N5", "N6", "N7"])
        #expect(Array(mixed.prefix(6)) == ["O1", "N1", "N2", "O2", "N3", "N4"])
        #expect(mixed.count == 10)
        #expect(mixed.filter { $0.hasPrefix("O") } == ["O1", "O2", "O3"], "Each list keeps its order")
    }

    @Test("with only one kind, a blend is just that kind", arguments: [
        ([String](), ["N1", "N2"]),
        (["O1", "O2"], [String]()),
    ])
    func blendOneKind(owned: [String], new: [String]) {
        #expect(ServerMix.blend(owned: owned, new: new) == owned + new)
    }

    @Test("your library's artists come most songs first")
    func libraryArtists() {
        let tracks = [song("A", by: "Nova Harbor"), song("B", by: "Mara Solis"), song("C", by: "Mara Solis")]
        #expect(ServerMix.libraryArtists(tracks) == ["Mara Solis", "Nova Harbor"])
        #expect(ServerMix.libraryArtists([]).isEmpty)
    }

    @Test("a mix leaves out songs you've heard, and has each song once")
    func mixSkips() {
        let found = [
            [song("Night Drive", by: "Mara Solis"), song("Tidal", by: "Mara Solis")],
            [song("Night Drive", by: "Mara Solis"), song("Harbor Lights", by: "Nova Harbor")],
        ]
        let heard = HistoryImport.key(title: "Tidal", artistName: "Mara Solis")
        let mix = ServerMix.mix(found, heard: { $0 == heard }, seed: 1)
        #expect(mix.map(\.title).sorted() == ["Harbor Lights", "Night Drive"])
    }

    @Test("a mix spreads artists out, and gives the same order for the same seed")
    func mixSpreads() {
        let found = [
            (1...4).map { song("Mara \($0)", by: "Mara Solis") },
            (1...4).map { song("Nova \($0)", by: "Nova Harbor") },
        ]
        let mix = ServerMix.mix(found, heard: { _ in false }, seed: 7)
        #expect(mix.count == 8)
        #expect(zip(mix, mix.dropFirst()).allSatisfy { $0.artistKey != $1.artistKey }, "No artist twice running")
        #expect(ServerMix.mix(found, heard: { _ in false }, seed: 7) == mix)
    }

    @Test("a mix stops at its limit")
    func mixLimit() {
        let found = [(1...30).map { song("Song \($0)", by: "Artist \($0)") }]
        #expect(ServerMix.mix(found, heard: { _ in false }, seed: 1, limit: 12).count == 12)
    }
}
