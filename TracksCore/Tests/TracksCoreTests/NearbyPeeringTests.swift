import Testing
@testable import TracksCore

@Suite("Your devices finding each other")
struct NearbyPeeringTests {
    @Test("only the device whose id sorts first opens the connection")
    func oneSideDials() {
        #expect(NearbyPeering.dials("B", from: "A", linked: []))
        #expect(NearbyPeering.dials("A", from: "B", linked: []) == false)
        #expect(NearbyPeering.dials("A", from: "A", linked: []) == false)
    }

    @Test("a device already connected isn't dialled again, one that's gone is")
    func redials() {
        #expect(NearbyPeering.dials("B", from: "A", linked: ["B"]) == false)
        #expect(NearbyPeering.dials("B", from: "A", linked: ["C"]))
    }

    @Test("a device back on a new connection replaces its old one, and only its own")
    func newConnectionWins() {
        let links: [Int: String?] = [1: "phone", 2: "phone", 3: "ipad", 4: nil]
        #expect(NearbyPeering.replaced(by: 2, from: "phone", links: links) == [1])
        #expect(NearbyPeering.replaced(by: 3, from: "ipad", links: links).isEmpty)
    }

    @Test("Tracks speaks for the Mac while it plays, or holds a song with Music quiet", arguments: [
        (true, true, true, true),
        (true, false, false, true),
        (true, false, true, false),
        (false, false, false, false),
        (false, false, true, false),
    ])
    func macVoice(hasSong: Bool, isPlaying: Bool, musicIsPlaying: Bool, expected: Bool) {
        #expect(NearbyVoice.isTracks(hasSong: hasSong, isPlaying: isPlaying, musicIsPlaying: musicIsPlaying) == expected)
    }
}
