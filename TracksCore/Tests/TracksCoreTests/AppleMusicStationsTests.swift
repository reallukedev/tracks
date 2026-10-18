import Testing
@testable import TracksCore

/// The stations Settings offers a switch for.
@Suite("Apple Music stations")
struct AppleMusicStationsTests {
    @Test("the live stations come first, in Apple's order, before anything is heard")
    func liveStationsFirst() {
        let choices = AppleMusicStations.choices(heard: [], excluded: [])
        #expect(choices == [
            "Apple Music 1",
            "Apple Music Hits",
            "Apple Music Country",
            "Apple Música Uno",
            "Apple Music Club",
            "Apple Music Chill",
        ])
    }

    /// Hearing Chill most recently mustn't move it up the list or list it twice.
    @Test("heard stations follow the live ones, without repeating them")
    func heardStationsFollow() {
        let choices = AppleMusicStations.choices(
            heard: ["Apple Music Chill", "Kendrick Lamar Station", "Apple Music 1", "Focus"],
            excluded: []
        )
        #expect(choices == AppleMusicStations.live + ["Kendrick Lamar Station", "Focus"])
    }

    @Test("an excluded station nobody mentions still gets a switch, after the rest")
    func excludedStationsKeepASwitch() {
        let choices = AppleMusicStations.choices(
            heard: ["Focus"],
            excluded: ["Pop Station", "Apple Music Hits", "Country Station"]
        )
        #expect(choices == AppleMusicStations.live + ["Focus", "Country Station", "Pop Station"])
    }
}
