import Testing
import Foundation
@testable import TracksCore

@Suite("Play facts")
struct PlayFactsTests {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func play(_ title: String, at hours: Double, kind: CaptureKind = .onDemand, station: String? = nil) -> CaptureStat {
        CaptureStat(
            songKey: title,
            title: title,
            artistName: "Artist",
            capturedAt: start.addingTimeInterval(hours * 3_600),
            stationName: station,
            kind: kind
        )
    }

    @Test("counts every play of a song, however its title was cased")
    func songFacts() throws {
        let history = ListeningHistory([
            play("Song", at: 2, kind: .radio, station: "Chill"),
            play("song", at: 0),
            play("SONG", at: 5),
            play("Other", at: 1),
        ])
        let facts = PlayFacts.songs(in: history)
        let song = try #require(facts[HistoryImport.key(title: "Song", artistName: "Artist")])
        #expect(song.plays == 3)
        #expect(song.radioPlays == 1)
        #expect(song.firstHeard == start)
        #expect(song.lastHeard == start.addingTimeInterval(5 * 3_600))
        #expect(facts.count == 2)
    }

    @Test("stations come most recent first, with their radio plays")
    func stations() {
        let history = ListeningHistory([
            play("A", at: 0, kind: .radio, station: "Chill"),
            play("B", at: 1, kind: .radio, station: "Chill"),
            play("C", at: 3, kind: .radio, station: "Hits"),
            // Not radio, so its station doesn't count.
            play("D", at: 4, kind: .onDemand, station: "Ignored"),
            play("E", at: 2, kind: .radio, station: "  "),
        ])
        let stations = PlayFacts.stations(in: history)
        #expect(stations.map(\.name) == ["Hits", "Chill"])
        #expect(stations.last?.plays == 2)
    }

    @Test("top artists count only plays since the start, most played first")
    func topArtists() {
        var plays: [CaptureStat] = []
        for index in 0..<3 { plays.append(play("A\(index)", at: Double(100 + index))) }
        plays += (0..<5).map { CaptureStat(songKey: "b\($0)", title: "B\($0)", artistName: "Busy", capturedAt: start.addingTimeInterval(Double(200 + $0) * 3_600)) }
        // Lots of plays, but before the start.
        plays += (0..<9).map { CaptureStat(songKey: "o\($0)", title: "O\($0)", artistName: "Old", capturedAt: start.addingTimeInterval(Double($0) * 3_600)) }
        let artists = PlayFacts.topArtists(in: ListeningHistory(plays), since: start.addingTimeInterval(50 * 3_600))
        #expect(artists == ["Busy", "Artist"])
    }
}
