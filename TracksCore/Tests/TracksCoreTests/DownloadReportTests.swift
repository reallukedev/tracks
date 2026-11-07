import Testing
import Foundation
@testable import TracksCore

@Suite("What's downloaded")
struct DownloadReportTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let day: TimeInterval = 24 * 60 * 60

    func song(_ title: String, artist: String = "Mara Solis", album: String = "Coastlines", bytes: Int64 = 10, daysAgo: Double = 200, lossless: Bool = false) -> DownloadedSong {
        DownloadedSong(
            track: LocalTrack(
                origin: .server(serverID: "home", songID: title),
                title: title,
                artist: artist,
                album: album,
                duration: 200,
                format: lossless ? AudioFormat(codec: "FLAC", sampleRate: 44_100, bitDepth: 16) : AudioFormat(codec: "MP3", bitRate: 320)
            ),
            bytes: bytes,
            downloadedAt: now.addingTimeInterval(-daysAgo * day)
        )
    }

    func facts(_ plays: Int, lastHeardDaysAgo: Double) -> SongFacts {
        let last = now.addingTimeInterval(-lastHeardDaysAgo * day)
        return SongFacts(plays: plays, radioPlays: 0, firstHeard: last, lastHeard: last)
    }

    func key(_ title: String) -> String { HistoryImport.key(title: title, artistName: "Mara Solis") }

    @Test("counts songs, albums, artists, room, time, what's lossless and what's never played")
    func stats() {
        let songs = [
            song("One", bytes: 30, lossless: true), song("Two", album: "Tides", bytes: 20),
            song("Three", artist: "Nova Harbor", album: "Lights", bytes: 10, lossless: true),
        ]
        let stats = DownloadReport.stats(songs, facts: [key("One"): facts(4, lastHeardDaysAgo: 1)])
        #expect(stats.songs == 3)
        #expect(stats.albums == 3)
        #expect(stats.artists == 2)
        #expect(stats.bytes == 60)
        #expect(stats.duration == 600)
        #expect(abs(stats.losslessShare - 2.0 / 3) < 0.0001)
        #expect(stats.neverPlayed == 2)
        #expect(DownloadReport.stats([], facts: [:]) == DownloadReport.Stats())
    }

    @Test("what could go: not played in three months, and not just downloaded, biggest first")
    func unplayed() {
        let songs = [
            song("Stale", bytes: 5), song("Big and Stale", bytes: 50), song("Played Lately", bytes: 40),
            song("Never Played", bytes: 20), song("Just Downloaded", bytes: 90, daysAgo: 3),
        ]
        let facts = [
            key("Stale"): facts(2, lastHeardDaysAgo: 120),
            key("Big and Stale"): facts(9, lastHeardDaysAgo: 100),
            key("Played Lately"): facts(3, lastHeardDaysAgo: 10),
        ]
        #expect(DownloadReport.unplayed(songs, facts: facts, now: now).map(\.track.title) == ["Big and Stale", "Never Played", "Stale"])
    }

    @Test("the most played, most first, leaving out ones never played")
    func mostPlayed() {
        let songs = [song("A"), song("B"), song("C")]
        let facts = [key("A"): facts(2, lastHeardDaysAgo: 1), key("B"): facts(7, lastHeardDaysAgo: 1)]
        #expect(DownloadReport.mostPlayed(songs, facts: facts).map(\.track.title) == ["B", "A"])
    }

    @Test("orders by when, name, artist and album, size, or least played", arguments: [
        (DownloadReport.Order.recent, ["New", "Mid", "Old"]),
        (.title, ["Mid", "New", "Old"]),
        (.artist, ["Old", "Mid", "New"]),
        (.size, ["Old", "New", "Mid"]),
        (.leastPlayed, ["Mid", "Old", "New"]),
    ])
    func order(order: DownloadReport.Order, expected: [String]) {
        let songs = [
            song("Old", artist: "Aria", bytes: 90, daysAgo: 30),
            song("Mid", artist: "Mara Solis", album: "A", bytes: 10, daysAgo: 20),
            song("New", artist: "Mara Solis", album: "B", bytes: 50, daysAgo: 10),
        ]
        let facts = [
            key("New"): facts(5, lastHeardDaysAgo: 1),
            HistoryImport.key(title: "Old", artistName: "Aria"): facts(1, lastHeardDaysAgo: 1),
        ]
        #expect(DownloadReport.sorted(songs, by: order, facts: facts).map(\.track.title) == expected)
    }
}
