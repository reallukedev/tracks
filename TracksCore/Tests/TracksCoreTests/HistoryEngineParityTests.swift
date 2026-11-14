import Foundation
import Testing
@testable import TracksCore

/// The engine's charts must be the ones the Swift calculator draws from the same plays:
/// same rows, order, counts, ranks, movement and listening time, in every span.
@Suite("History engine parity")
struct HistoryEngineParityTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    /// Three months of listening, skewed towards favourites, with features, collaborations,
    /// shared album names, every kind of play and an occasional long gap, from a fixed seed.
    private static let captures: [CaptureStat] = {
        let artists = ["Mara Solís", "Umbra", "Umbra feat. Yuki Tanabe", "Juniper Lane & Kaito Rivers", "Solstice Club", "Hollow Pines"]
        let albums = ["Home", "Seasonal", nil, "Overpass", "Home"]
        let kinds: [CaptureKind] = [.onDemand, .onDemand, .radio, .imported, .lastFM]
        var state: UInt64 = 7
        func next() -> Double {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        var at = Date(timeIntervalSince1970: 1_790_000_000)
        return (0..<2_000).map { index in
            let song = Int(40 * pow(next(), 2))
            // Mostly a song after the last; now and then a pause, so the estimate varies.
            at += next() < 0.1 ? 3_600 * 5 : 120 + next() * 200
            return CaptureStat(
                songKey: "\(song)",
                songID: song % 3 == 0 ? "" : "\(1_000 + song)",
                title: "Song \(song)",
                artistName: artists[song % artists.count],
                albumTitle: albums[song % albums.count],
                artworkURL: "https://example.com/\(song).jpg",
                capturedAt: at,
                kind: kinds[index % kinds.count],
                source: index % 7 == 0 ? .yourMusic : .appleMusic
            )
        }
    }()

    private static func periods() -> [ChartPeriod] {
        let last = captures.map(\.capturedAt).max()!
        return [ChartSpan.day, .week, .month, .year, .allTime].flatMap { span in
            let current = ChartPeriod.containing(last, span: span, calendar: calendar)
            return [current, current.previous(calendar: calendar)].compactMap { $0 }
        }
    }

    private static func engine() throws -> HistoryEngine {
        let engine = try #require(HistoryEngine.inMemory())
        engine.sync(captures)
        return engine
    }

    @Test("songs, artists and albums match in every span and scope", arguments: SourceScope.allCases)
    func chartsMatch(scope: SourceScope) throws {
        let engine = try Self.engine()
        #expect(try engine.playCount() == Self.captures.count)
        let history = ListeningHistory(Self.captures).scoped(to: scope)
        for period in Self.periods() {
            let swiftSongs = StatsCalculator.songChart(in: period, history: history, calendar: Self.calendar, limit: 500)
            let rustSongs = try engine.songChart(in: period, scope: scope, calendar: Self.calendar, limit: 500)
            #expect(rustSongs.map(\.id) == swiftSongs.map(\.id), "song order, \(period.span)")
            #expect(rustSongs.map(\.item.count) == swiftSongs.map(\.item.count), "song counts, \(period.span)")
            #expect(rustSongs.map(\.rank) == swiftSongs.map(\.rank), "song ranks, \(period.span)")
            #expect(rustSongs.map(\.movement) == swiftSongs.map(\.movement), "song movement, \(period.span)")
            for (rust, swift) in zip(rustSongs, swiftSongs) where abs(rust.item.listeningSeconds - swift.item.listeningSeconds) > 0.5 {
                Issue.record("\(period.span) \(swift.id): \(rust.item.listeningSeconds) vs \(swift.item.listeningSeconds)")
            }

            let swiftArtists = StatsCalculator.artistChart(in: period, history: history, calendar: Self.calendar, limit: 500)
            let rustArtists = try engine.artistChart(in: period, scope: scope, calendar: Self.calendar, limit: 500)
            #expect(rustArtists.map(\.id) == swiftArtists.map(\.id), "artist order, \(period.span)")
            #expect(rustArtists.map(\.item.name) == swiftArtists.map(\.item.name), "artist names, \(period.span)")
            #expect(rustArtists.map(\.item.count) == swiftArtists.map(\.item.count), "artist counts, \(period.span)")
            #expect(rustArtists.map(\.item.songCount) == swiftArtists.map(\.item.songCount), "artist songs, \(period.span)")
            #expect(rustArtists.map(\.movement) == swiftArtists.map(\.movement), "artist movement, \(period.span)")

            let swiftAlbums = StatsCalculator.albumChart(in: period, history: history, calendar: Self.calendar, limit: 500)
            let rustAlbums = try engine.albumChart(in: period, scope: scope, calendar: Self.calendar, limit: 500)
            #expect(rustAlbums.map(\.id) == swiftAlbums.map(\.id), "album order, \(period.span)")
            #expect(rustAlbums.map(\.item.count) == swiftAlbums.map(\.item.count), "album counts, \(period.span)")
            #expect(rustAlbums.map(\.item.songCount) == swiftAlbums.map(\.item.songCount), "album songs, \(period.span)")
            #expect(rustAlbums.map(\.item.artistName) == swiftAlbums.map(\.item.artistName), "album artists, \(period.span)")
        }
    }

    @Test("a sync of the same history changes nothing, and new plays arrive as steps")
    func stepsKeepTheIndexCurrent() throws {
        let engine = try Self.engine()
        engine.sync(Self.captures)
        #expect(try engine.playCount() == Self.captures.count)

        let later = Self.captures.last!.capturedAt.addingTimeInterval(180)
        let new = CaptureStat(songKey: "x", title: "Brand New", artistName: "Umbra", capturedAt: later, kind: .onDemand)
        engine.apply(.steps([.init(added: [new], changed: [])], sessions: []))
        let top = try engine.songChart(in: .containing(later, span: .day, calendar: Self.calendar), scope: .all, calendar: Self.calendar)
        #expect(top.contains { $0.item.title == "Brand New" })
        #expect(try engine.playCount() == Self.captures.count + 1)
    }
}
