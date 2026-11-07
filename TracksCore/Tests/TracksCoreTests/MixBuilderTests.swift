import Testing
import Foundation
@testable import TracksCore

@Suite("Play mixes")
struct MixBuilderTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// A Tuesday at 7 pm.
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 19))! }

    func play(
        _ title: String,
        by artist: String = "Artist",
        daysAgo: Double,
        hour: Int? = nil,
        kind: CaptureKind = .onDemand,
        id: String? = nil
    ) -> CaptureStat {
        var date = now.addingTimeInterval(-daysAgo * 86_400)
        if let hour {
            date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date)!
        }
        return CaptureStat(
            songKey: title,
            songID: id ?? "id.\(title)",
            title: title,
            artistName: artist,
            albumTitle: "\(title) Album",
            artworkURL: "https://example.com/\(title).jpg",
            capturedAt: date,
            kind: kind
        )
    }

    func build(_ plays: [CaptureStat], signals: ListeningSignals = ListeningSignals()) -> MixBuilder.Output {
        MixBuilder.build(from: ListeningHistory(plays), signals: signals, now: now, calendar: calendar)
    }

    @Test("an empty history has no mixes")
    func empty() {
        #expect(build([]) == .empty)
    }

    @Test("On Repeat takes songs played three times in the last month")
    func onRepeat() throws {
        var plays: [CaptureStat] = []
        for index in 0..<8 {
            for day in [1.0, 3, 5] {
                plays.append(play("Song \(index)", by: "Artist \(index)", daysAgo: day))
            }
        }
        // Twice only, and three times but too long ago.
        plays += [play("Twice", daysAgo: 2), play("Twice", daysAgo: 4)]
        plays += [40.0, 41, 42].map { play("Old", daysAgo: $0) }

        let mix = try #require(build(plays).mixes.first { $0.kind == .onRepeat })
        let titles = Set(mix.songs.map(\.title))
        #expect(titles.count == 8)
        #expect(!titles.contains("Twice"))
        #expect(!titles.contains("Old"))
    }

    @Test("a mix with too few songs isn't offered")
    func tooFewSongs() {
        let plays = (0..<3).flatMap { index in
            [1.0, 2, 3].map { play("Song \(index)", daysAgo: $0) }
        }
        #expect(!build(plays).mixes.contains { $0.kind == .onRepeat })
    }

    @Test("Radio Finds only holds songs never played on demand")
    func radioFinds() throws {
        var plays = (0..<7).map { play("Radio \($0)", by: "Artist \($0)", daysAgo: 3, kind: .radio) }
        plays.append(play("Chosen", daysAgo: 5, kind: .radio))
        plays.append(play("Chosen", daysAgo: 1, kind: .onDemand))
        plays.append(play("Recovered", daysAgo: 5, kind: .radio))
        plays.append(play("Recovered", daysAgo: 1, kind: .imported))

        let mix = try #require(build(plays).mixes.first { $0.kind == .radioFinds })
        #expect(mix.songs.count == 7)
        #expect(!mix.songs.contains { $0.title == "Chosen" || $0.title == "Recovered" })
    }

    @Test("Rediscover needs ninety days of history and sixty days of absence")
    func rediscover() throws {
        var plays: [CaptureStat] = []
        for index in 0..<6 {
            plays += [120.0, 121, 122, 123].map { play("Loved \(index)", by: "A\(index)", daysAgo: $0) }
        }
        // Loved, but heard last week.
        plays += [120.0, 121, 122, 7].map { play("Still Here", daysAgo: $0) }

        let mix = try #require(build(plays).mixes.first { $0.kind == .rediscover })
        #expect(mix.songs.count == 6)
        #expect(!mix.songs.contains { $0.title == "Still Here" })

        // The same songs in a history only eighty days long.
        let short = plays.map { play($0.title, by: $0.artistName, daysAgo: 70) }
        #expect(!build(short).mixes.contains { $0.kind == .rediscover })
    }

    @Test("Right Now matches the part of the day and the kind of day")
    func rightNow() throws {
        var plays: [CaptureStat] = []
        // Tuesday and Wednesday evenings, a week and two weeks back: weekdays.
        for index in 0..<9 {
            plays.append(play("Evening \(index)", by: "E\(index)", daysAgo: 7, hour: 20))
            plays.append(play("Evening \(index)", by: "E\(index)", daysAgo: 13, hour: 18))
        }
        // Weekday mornings, and a weekend evening (the Sunday two days back).
        for index in 0..<9 {
            plays.append(play("Morning \(index)", daysAgo: 7, hour: 8))
            plays.append(play("Morning \(index)", daysAgo: 8, hour: 9))
            plays.append(play("Weekend \(index)", daysAgo: 2, hour: 20))
            plays.append(play("Weekend \(index)", daysAgo: 9, hour: 20))
        }

        let mix = try #require(build(plays).rightNow)
        #expect(mix.kind == .rightNow(.evening, isWeekend: false))
        #expect(mix.songs.allSatisfy { $0.title.hasPrefix("Evening") })
        #expect(mix.songs.count == 9)
    }

    @Test("Right Now leaves out what was just played")
    func rightNowSkipsJustPlayed() throws {
        var plays: [CaptureStat] = []
        for index in 0..<9 {
            plays.append(play("Evening \(index)", by: "E\(index)", daysAgo: 7, hour: 20))
            plays.append(play("Evening \(index)", by: "E\(index)", daysAgo: 14, hour: 20))
        }
        plays.append(play("Evening 0", by: "E0", daysAgo: 1.0 / 24))

        let mix = try #require(build(plays).rightNow)
        #expect(!mix.songs.contains { $0.title == "Evening 0" })
    }

    @Test("A throwback falls back to six months when a year isn't there")
    func throwback() throws {
        let sixMonthsAgo = now.timeIntervalSince(calendar.date(byAdding: .month, value: -6, to: now)!) / 86_400
        let plays = (0..<10).map { play("Then \($0)", by: "T\($0)", daysAgo: sixMonthsAgo + 2) }
            + [play("Start", daysAgo: 200)]
        let mix = try #require(build(plays).mixes.first { if case .throwback = $0.kind { true } else { false } })
        guard case .throwback(let months, _) = mix.kind else { Issue.record("not a throwback"); return }
        #expect(months == 6)
        #expect(mix.songs.count == 10)
    }

    @Test("songs asked to hear less of, or skipped twice, drop out")
    func signalsExclude() throws {
        var plays: [CaptureStat] = []
        for index in 0..<9 {
            for day in [1.0, 3, 5] {
                plays.append(play("Song \(index)", by: "Artist \(index)", daysAgo: day))
            }
        }
        var signals = ListeningSignals()
        signals.setSuggestLess(HistoryImport.key(title: "Song 0", artistName: "Artist 0"), true)
        let skipped = HistoryImport.key(title: "Song 1", artistName: "Artist 1")
        signals.recordSkip(of: skipped, at: now.addingTimeInterval(-86_400))
        signals.recordSkip(of: skipped, at: now.addingTimeInterval(-3_600))

        let mix = try #require(build(plays, signals: signals).mixes.first { $0.kind == .onRepeat })
        #expect(!mix.songs.contains { $0.title == "Song 0" || $0.title == "Song 1" })
        #expect(mix.songs.count == 7)
    }

    @Test("a mix keeps its order through the day and holds the newest facts")
    func stableOrderAndNewestFacts() throws {
        var plays: [CaptureStat] = []
        for index in 0..<10 {
            for day in [1.0, 3, 5] {
                plays.append(play("Song \(index)", by: "Artist \(index % 3)", daysAgo: day, id: day == 5 ? "" : "id.\(index)"))
            }
        }
        let first = try #require(build(plays).mixes.first { $0.kind == .onRepeat })
        let second = try #require(build(plays).mixes.first { $0.kind == .onRepeat })
        #expect(first.songs.map(\.title) == second.songs.map(\.title))
        #expect(first.songs.allSatisfy { $0.songID.hasPrefix("id.") && $0.plays == 3 })
        #expect(first.playableSongs.count == 10)
        #expect(first.playCount == 30)
    }

    @Test("covers come from different albums")
    func covers() {
        let songs = (0..<6).map { index in
            MixSong(
                songIdentity: "\(index)",
                songID: "\(index)",
                title: "\(index)",
                artistName: "A",
                albumTitle: index < 3 ? "Same" : "Album \(index)",
                artworkURL: "https://example.com/\(index)",
                plays: 1,
                lastHeard: now
            )
        }
        let mix = Mix(kind: .onRepeat, songs: songs, playCount: 6)
        #expect(mix.covers.map(\.url) == ["https://example.com/0", "https://example.com/3", "https://example.com/4", "https://example.com/5"])
    }

    @Test("albums without a cover still give the mix art, after those with one")
    func coversWithoutArt() {
        let songs = (0..<3).map { index in
            MixSong(
                songIdentity: "\(index)",
                songID: "",
                title: "Song \(index)",
                artistName: "A",
                albumTitle: "Album \(index)",
                artworkURL: index == 2 ? "https://example.com/2" : nil,
                plays: 1,
                lastHeard: now
            )
        }
        let covers = Mix(kind: .onRepeat, songs: songs, playCount: 3).covers
        #expect(covers.map(\.seed) == ["Album 2", "Album 0", "Album 1"])
        #expect(covers.first?.url == "https://example.com/2")
    }
}
