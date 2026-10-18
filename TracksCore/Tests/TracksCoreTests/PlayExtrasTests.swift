import Testing
import Foundation
@testable import TracksCore

@Suite("Explicit versions")
struct ExplicitVersionsTests {
    struct Version: Equatable {
        let title: String
        var artist = "Artist"
        let explicit: Bool
    }

    func pick(_ items: [Version], allowsExplicit: Bool) -> [Version] {
        ExplicitVersions.pick(items, allowsExplicit: allowsExplicit, title: \.title, artist: \.artist, isExplicit: \.explicit)
    }

    let search = [
        Version(title: "Song A", explicit: false),
        Version(title: "Song A", explicit: true),
        Version(title: "Song B (Clean)", explicit: false),
        Version(title: "Song B", explicit: true),
        Version(title: "Only Explicit", explicit: true),
        Version(title: "Only Clean", explicit: false),
    ]

    @Test("with explicit allowed, the explicit version of each song stays, in first place")
    func prefersExplicit() {
        #expect(pick(search, allowsExplicit: true) == [
            Version(title: "Song A", explicit: true),
            Version(title: "Song B", explicit: true),
            Version(title: "Only Explicit", explicit: true),
            Version(title: "Only Clean", explicit: false),
        ])
    }

    @Test("without, the clean version stays and explicit-only songs go")
    func prefersClean() {
        #expect(pick(search, allowsExplicit: false) == [
            Version(title: "Song A", explicit: false),
            Version(title: "Song B (Clean)", explicit: false),
            Version(title: "Only Clean", explicit: false),
        ])
    }

    @Test("two clean songs of one name are two songs, not versions")
    func sameNameBothClean() {
        let items = [Version(title: "Hallelujah", explicit: false), Version(title: "Hallelujah", explicit: false)]
        #expect(pick(items, allowsExplicit: true).count == 2)
        #expect(pick(items, allowsExplicit: false).count == 2)
    }

    @Test("a discriminator keeps same-named albums apart")
    func discriminator() {
        struct Album { let title: String; let year: Int; let explicit: Bool }
        let albums = [Album(title: "Weezer", year: 1994, explicit: false), Album(title: "Weezer", year: 2001, explicit: true)]
        let kept = ExplicitVersions.pick(albums, allowsExplicit: true, title: \.title, artist: { _ in "Weezer" }, isExplicit: \.explicit, discriminator: { "\($0.year)" })
        #expect(kept.count == 2)
    }

    @Test("the same title by another artist is another song")
    func artistsKeptApart() {
        let items = [Version(title: "Home", artist: "One", explicit: false), Version(title: "Home", artist: "Two", explicit: true)]
        #expect(pick(items, allowsExplicit: true).count == 2)
    }

    @Test("version markers are ignored", arguments: ["Song (Clean)", "Song [Explicit]", "Song - Clean Version", "song"])
    func markers(title: String) {
        #expect(ExplicitVersions.versionKey(title: title, artist: "A") == ExplicitVersions.versionKey(title: "Song", artist: "A"))
    }
}

@Suite("Play layout")
struct PlayLayoutTests {
    @Test("round-trips through its stored form")
    func stored() {
        var layout = PlayLayout.standard
        layout.setVisible(.library, false)
        layout.move(from: [PlaySection.allCases.firstIndex(of: .radio)!], to: 0)
        let restored = PlayLayout(stored: layout.stored)
        #expect(restored == layout)
        #expect(restored.order.first == .radio)
        #expect(!restored.visible.contains(.library))
    }

    @Test("empty or unreadable storage gives the standard layout")
    func fallback() {
        #expect(PlayLayout(stored: "") == .standard)
        #expect(PlayLayout(stored: "nonsense,,").order == PlaySection.allCases)
    }

    @Test("a layout saved before new sections existed gains them in their default place")
    func upgrade() {
        // "discover" was a section once; it's gone, and dropped.
        let layout = PlayLayout(stored: "forYou,recentlyPlayed,mixes,discover,radio,-library,appleMusic")
        #expect(layout.order == [.forYou, .suggestedSongs, .suggestedArtists, .recentlyPlayed, .yourArtists, .mixes, .moods, .genres, .newReleases, .radio, .charts, .library, .appleMusic])
        #expect(!layout.isVisible(.library))
    }

    @Test("a layout saved before Genres existed shows it right after the moods, wherever they were moved")
    func genresJoinAfterMoods() {
        let layout = PlayLayout(stored: "moods,forYou,-suggestedSongs,suggestedArtists,recentlyPlayed,yourArtists,mixes,newReleases,radio,charts,library,appleMusic")
        #expect(layout.order.prefix(3) == [.moods, .genres, .forYou])
        #expect(layout.isVisible(.genres))
        #expect(layout.isVisible(.suggestedSongs) == false)
    }

    @Test("sections a newer version added are placed where they sit by default")
    func missingSections() {
        let layout = PlayLayout(stored: "radio,forYou")
        #expect(Set(layout.order) == Set(PlaySection.allCases))
        #expect(layout.order.count == PlaySection.allCases.count)
        // Radio and For You keep their chosen order.
        #expect(layout.order.firstIndex(of: .radio)! < layout.order.firstIndex(of: .forYou)!)
    }

    @Test("duplicates are dropped")
    func duplicates() {
        #expect(PlayLayout(stored: "radio,radio,-radio").order.count(where: { $0 == .radio }) == 1)
    }

    @Test("moving works the way a list reports it", arguments: [
        (from: 0, to: 3, expected: [PlaySection.suggestedSongs, .suggestedArtists, .forYou, .recentlyPlayed]),
        (from: 3, to: 0, expected: [PlaySection.recentlyPlayed, .forYou, .suggestedSongs, .suggestedArtists]),
    ])
    func move(from: Int, to: Int, expected: [PlaySection]) {
        var layout = PlayLayout.standard
        layout.move(from: [from], to: to)
        #expect(Array(layout.order.prefix(4)) == expected)
    }
}

@Suite("Live mixes")
struct LiveMixTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func history() -> ListeningHistory {
        var plays: [CaptureStat] = []
        for index in 0..<40 {
            let times = index == 0 ? 60 : 1
            for play in 0..<times {
                plays.append(CaptureStat(
                    songKey: "\(index)",
                    songID: "id\(index)",
                    title: "Song \(index)",
                    artistName: "Artist \(index % 8)",
                    capturedAt: now.addingTimeInterval(-Double(10 + index * 24 + play) * 3_600)
                ))
            }
        }
        // Heard an hour ago, so resting.
        plays.append(CaptureStat(songKey: "fresh", songID: "fresh", title: "Fresh", artistName: "New", capturedAt: now.addingTimeInterval(-3_600)))
        return ListeningHistory(plays)
    }

    func song(_ title: String, artist: String) -> MixSong {
        MixSong(
            songIdentity: HistoryImport.key(title: title, artistName: artist),
            songID: title,
            title: title,
            artistName: artist,
            albumTitle: nil,
            artworkURL: nil,
            plays: 0,
            lastHeard: .distantPast
        )
    }

    func draw(_ mix: inout LiveMix, _ count: Int) -> [MixSong] {
        (0..<count).compactMap { _ in mix.next() }
    }

    @Test("no song comes up twice until every one has")
    func noRepeats() {
        var mix = LiveMix.tracksRadio(from: history(), now: now, seed: 1)
        let round = draw(&mix, 41)
        #expect(Set(round.map(\.id)).count == 41)
        // It never runs out.
        #expect(draw(&mix, 30).count == 30)
    }

    @Test("a song heard in the last few hours waits until the rested ones are used up")
    func resting() {
        for seed in 1...20 as ClosedRange<UInt64> {
            var mix = LiveMix.tracksRadio(from: history(), now: now, seed: seed)
            #expect(!draw(&mix, 40).contains { $0.title == "Fresh" })
            #expect(mix.next()?.title == "Fresh")
        }
    }

    @Test("a history heard only in the last few hours still plays")
    func newHistory() {
        let plays = (0..<10).map {
            CaptureStat(songKey: "\($0)", songID: "\($0)", title: "New \($0)", artistName: "A\($0)", capturedAt: now.addingTimeInterval(-Double($0 + 1) * 600))
        }
        var mix = LiveMix.tracksRadio(from: ListeningHistory(plays), now: now, seed: 3)
        #expect(draw(&mix, 5).count == 5)
    }

    @Test("the song a listen starts with isn't picked again")
    func startingSong() {
        var mix = LiveMix.tracksRadio(from: history(), now: now, seed: 4)
        let first = HistoryImport.key(title: "Song 0", artistName: "Artist 0")
        mix.note(picked: first)
        #expect(!draw(&mix, 39).contains { $0.id == first })
    }

    @Test("an artist doesn't follow themselves when someone else can")
    func artistSpacing() {
        var mix = LiveMix.tracksRadio(from: history(), now: now, seed: 5)
        let artists = draw(&mix, 30).map(\.artistName)
        for (a, b) in zip(artists, artists.dropFirst()) { #expect(a != b) }
    }

    @Test("a much-played song comes up early far more often than a once-played one")
    func weighting() {
        var favourite = 0
        var once = 0
        for seed in 1...200 as ClosedRange<UInt64> {
            var mix = LiveMix.tracksRadio(from: history(), now: now, seed: seed)
            let early = draw(&mix, 5)
            if early.contains(where: { $0.title == "Song 0" }) { favourite += 1 }
            if early.contains(where: { $0.title == "Song 39" }) { once += 1 }
        }
        #expect(favourite > once * 2)
    }

    @Test("skipping an artist makes them rarer for a while, never gone")
    func skipsSteer() {
        let songs = (0..<60).map { song("S\($0)", artist: "Artist \($0 % 6)") }
        func plays(ofArtist0 skipping: Bool) -> Int {
            (1...100 as ClosedRange<UInt64>).reduce(0) { count, seed in
                var mix = LiveMix(candidates: songs.map { .init(song: $0, weight: 1) }, seed: seed)
                if skipping { mix.noteSkipped(songs[0].songIdentity) }
                return count + draw(&mix, 12).filter { $0.artistName == "Artist 0" }.count
            }
        }
        let skipped = plays(ofArtist0: true)
        let unskipped = plays(ofArtist0: false)
        #expect(Double(skipped) < Double(unskipped) * 0.85)
        // A skip is a nudge: the artist still comes round.
        #expect(Double(skipped) > Double(unskipped) * 0.3)
    }

    @Test("new finds take their share, and skipping them shrinks it")
    func newShare() {
        let yours = (0..<50).map { LiveMix.Candidate(song: song("Y\($0)", artist: "Y\($0)"), weight: 1) }
        let new = (0..<50).map { LiveMix.Candidate(song: song("N\($0)", artist: "N\($0)"), weight: 1, isNew: true) }
        var mix = LiveMix(candidates: yours + new, newShare: 0.3, seed: 9)
        let before = mix.newShare
        mix.noteSkipped(new[0].song.songIdentity)
        #expect(mix.newShare < before)
        mix.noteFinished(new[1].song.songIdentity)
        mix.noteFinished(new[2].song.songIdentity)
        #expect(mix.newShare > before * 0.7)

        var fresh = LiveMix(candidates: yours + new, newShare: 0.3, seed: 10)
        let newPicks = draw(&fresh, 40).filter { $0.title.hasPrefix("N") }.count
        #expect((4...24).contains(newPicks))
    }

    @Test("picking only what passes: songs ready to play, or new finds to get ready")
    func pickWhere() {
        let yours = (0..<6).map { LiveMix.Candidate(song: song("Y\($0)", artist: "Y\($0)"), weight: 1) }
        let new = (0..<6).map { LiveMix.Candidate(song: song("N\($0)", artist: "N\($0)"), weight: 1, isNew: true) }
        var mix = LiveMix(candidates: yours + new, newShare: 0.5, seed: 4)
        let ready: Set<String> = ["Y1", "Y2", "N3"]
        for _ in 0..<3 {
            let pick = mix.next(where: { ready.contains($0.title) })
            #expect(pick.map { ready.contains($0.title) } == true)
        }
        #expect(mix.next(where: { ready.contains($0.title) }) == nil, "All the ready ones are picked")

        var finds = LiveMix(candidates: yours + new, newShare: 0, seed: 5)
        #expect(finds.next(newFinds: true, where: { _ in true })?.title.hasPrefix("N") == true, "A new find even with no share for them")
        #expect(finds.next(newFinds: false, where: { $0.title.hasPrefix("N") }) == nil)
    }

    @Test("a mood with none of your songs plays new finds")
    func moodWithoutHistory() {
        let finds = (0..<5).map { song("Find \($0)", artist: "F\($0)") }
        var mix = LiveMix.mood(.chill, from: ListeningHistory([]), newFinds: finds, now: now, seed: 2)
        #expect(Set(draw(&mix, 5).map(\.title)) == Set(finds.map(\.title)))
    }

    @Test("a new find already in the history counts as yours, once")
    func newFindsDeduplicated() {
        let known = song("Song 1", artist: "Artist 1")
        let mix = LiveMix.tracksRadio(from: history(), newFinds: [known], now: now, seed: 1)
        #expect(mix.candidates.filter { $0.song.songIdentity == known.songIdentity }.count == 1)
        #expect(!mix.candidates.contains { $0.isNew })
    }

    @Test("leaning into a genre makes its songs come up far more, without leaving the rest out")
    func tunedGenres() {
        var plays: [CaptureStat] = []
        var metadata: [String: SongMetadata] = [:]
        for index in 0..<40 {
            let title = "T\(index)"
            plays.append(CaptureStat(songKey: title, songID: title, title: title, artistName: "A\(index)", capturedAt: now.addingTimeInterval(-Double(index + 10) * 86_400)))
            metadata[HistoryImport.key(title: title, artistName: "A\(index)")] = SongMetadata(genre: index < 10 ? "Hip-Hop/Rap" : "Country", releaseYear: nil)
        }
        let history = ListeningHistory(plays).with(artistArtwork: [:], songMetadata: metadata)
        let tuning = RadioTuning(genres: ["Hip-Hop"])
        var hipHop = 0
        for seed in 1...40 as ClosedRange<UInt64> {
            var mix = LiveMix.tracksRadio(from: history, tuning: tuning, now: now, seed: seed)
            hipHop += draw(&mix, 10).filter { Int($0.title.dropFirst())! < 10 }.count
        }
        // A quarter of the songs, drawn well over half the time.
        #expect(hipHop > 400 / 2)
        var mix = LiveMix.tracksRadio(from: history, tuning: tuning, now: now, seed: 1)
        #expect(Set(draw(&mix, 40).map(\.id)).count == 40)
    }

    @Test("discovery sets the share of new finds")
    func tunedDiscovery() {
        let finds = (0..<30).map { song("Find \($0)", artist: "F\($0)") }
        let familiar = LiveMix.tracksRadio(from: history(), newFinds: finds, tuning: RadioTuning(discovery: .familiar), now: now, seed: 1)
        let adventurous = LiveMix.tracksRadio(from: history(), newFinds: finds, tuning: RadioTuning(discovery: .adventurous), now: now, seed: 1)
        #expect(familiar.newShare < adventurous.newShare)
    }

    @Test("retuning mid-listen keeps what's been picked")
    func retune() {
        var first = LiveMix.tracksRadio(from: history(), now: now, seed: 1)
        let heard = draw(&first, 10).map(\.id)
        var retuned = LiveMix.tracksRadio(from: history(), tuning: RadioTuning(discovery: .adventurous), now: now, seed: 2)
        retuned.continueListen(from: first)
        #expect(Set(draw(&retuned, 31).map(\.id)).isDisjoint(with: heard))
    }

    @Test("the tuning survives being stored, and nonsense reads as the standard")
    func tuningStorage() {
        let tuning = RadioTuning(discovery: .adventurous, genres: ["Jazz", "R&B/Soul"], bringsBackOldFavorites: true)
        #expect(RadioTuning(stored: tuning.stored) == tuning)
        #expect(RadioTuning(stored: "{") == .standard)
    }

    @Test("the same seed gives the same picks")
    func deterministic() {
        var a = LiveMix.tracksRadio(from: history(), now: now, seed: 7)
        var b = LiveMix.tracksRadio(from: history(), now: now, seed: 7)
        #expect(draw(&a, 20) == draw(&b, 20))
    }
}

@Suite("More mixes")
struct MoreMixesTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// A Tuesday at 7 pm.
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 19))! }

    func play(_ title: String, by artist: String, daysAgo: Double, hour: Int = 12) -> CaptureStat {
        let day = now.addingTimeInterval(-daysAgo * 86_400)
        return CaptureStat(
            songKey: title,
            songID: "id.\(title)",
            title: title,
            artistName: artist,
            capturedAt: calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        )
    }

    @Test("the other times of day come after this one, in the order they come round")
    func otherTimes() {
        var plays: [CaptureStat] = []
        for (part, hour) in [(0, 8), (1, 14), (2, 20), (3, 23)] {
            for index in 0..<9 {
                // Weekdays a week and two weeks back.
                plays.append(play("P\(part) \(index)", by: "A\(index)", daysAgo: 7, hour: hour))
                plays.append(play("P\(part) \(index)", by: "A\(index)", daysAgo: 14, hour: hour))
            }
        }
        let output = MixBuilder.build(from: ListeningHistory(plays), now: now, calendar: calendar)
        #expect(output.rightNow?.kind == .rightNow(.evening, isWeekend: false))
        #expect(output.otherTimes.map(\.kind) == [
            .rightNow(.night, isWeekend: false),
            .rightNow(.morning, isWeekend: false),
            .rightNow(.afternoon, isWeekend: false),
        ])
    }

    @Test("Deep Cuts holds barely heard songs by the artists played most")
    func deepCuts() throws {
        var plays: [CaptureStat] = []
        // A loved artist: a hit played a lot, and eight songs heard once, a while ago.
        for day in 1...30 { plays.append(play("Hit", by: "Loved", daysAgo: Double(day))) }
        for index in 0..<8 { plays.append(play("Cut \(index)", by: "Loved", daysAgo: 60)) }
        // Heard once, but last week: too recent to be a deep cut.
        plays.append(play("Recent Cut", by: "Loved", daysAgo: 5))
        let output = MixBuilder.build(from: ListeningHistory(plays), now: now, calendar: calendar)
        let mix = try #require(output.mixes.first { $0.kind == .deepCuts })
        #expect(mix.songs.count == 8)
        #expect(mix.songs.allSatisfy { $0.title.hasPrefix("Cut") })
    }

    @Test("All-Time Favorites needs five plays a song")
    func favourites() throws {
        var plays: [CaptureStat] = []
        for index in 0..<7 {
            for day in 0..<5 { plays.append(play("Fave \(index)", by: "A\(index)", daysAgo: Double(day * 40 + 1))) }
        }
        for day in 0..<4 { plays.append(play("Almost", by: "B", daysAgo: Double(day + 1))) }
        let output = MixBuilder.build(from: ListeningHistory(plays), now: now, calendar: calendar)
        let mix = try #require(output.mixes.first { $0.kind == .allTimeFavorites })
        #expect(mix.songs.count == 7)
        #expect(!mix.songs.contains { $0.title == "Almost" })
        #expect(output.mix(id: mix.id) == mix)
    }
}

@Suite("Moods and favorite artists")
struct MoodTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func play(_ title: String, by artist: String, hoursAgo: Double, songID: String = "") -> CaptureStat {
        CaptureStat(
            songKey: title,
            songID: songID.isEmpty ? "id.\(title)" : songID,
            title: title,
            artistName: artist,
            artworkURL: "https://example.com/\(title)",
            capturedAt: now.addingTimeInterval(-hoursAgo * 3_600)
        )
    }

    func history(genres: [String: String], plays: [CaptureStat]) -> ListeningHistory {
        let metadata = Dictionary(uniqueKeysWithValues: genres.map {
            (HistoryImport.key(title: $0.key, artistName: "A"), SongMetadata(genre: $0.value, releaseYear: nil))
        })
        return ListeningHistory(plays).with(artistArtwork: [:], songMetadata: metadata)
    }

    @Test("a mood takes songs whose genre suits it, and nothing unlooked-up")
    func moodBySongGenre() {
        let plays = ["Calm", "Loud", "Unknown", "Smooth"].map { play($0, by: "A", hoursAgo: 5) }
        let history = history(genres: ["Calm": "Ambient", "Loud": "Metal", "Smooth": "Jazz"], plays: plays)
        #expect(Set(MoodMix.songs(for: .focus, in: history, now: now).map(\.title)) == ["Calm", "Smooth"])
        #expect(MoodMix.songs(for: .workout, in: history, now: now).map(\.title) == ["Loud"])
    }

    @Test("genre names match by part, however they're cased", arguments: [
        (Mood.chill, "R&B/Soul", true), (.party, "Hip-Hop/Rap", true), (.sleep, "Hip-Hop/Rap", false),
        (.feelGood, "K-Pop", true), (.energy, "Alternative", true), (.focus, "Country", false),
    ])
    func genreMatching(mood: Mood, genre: String, suits: Bool) {
        #expect(mood.suits(genre: genre) == suits)
    }

    @Test("favorite artists are the most played lately, with a picture")
    func favoriteArtists() {
        var plays: [CaptureStat] = []
        plays += (0..<5).map { play("Busy \($0)", by: "Busy", hoursAgo: Double($0 + 1)) }
        plays += (0..<2).map { play("Quiet \($0)", by: "Quiet", hoursAgo: Double($0 + 1)) }
        plays += (0..<9).map { play("Old \($0)", by: "Old", hoursAgo: 24 * 400) }
        let favourites = PlayFacts.favoriteArtists(in: ListeningHistory(plays), since: now.addingTimeInterval(-24 * 3_600 * 180))
        #expect(favourites.map(\.name) == ["Busy", "Quiet"])
        #expect(favourites.first?.plays == 5)
        #expect(favourites.first?.artworkURL != nil)
    }

    @Test("with a half-life, where listening is going outranks where it's been")
    func favoriteArtistsLately() {
        var plays: [CaptureStat] = []
        plays += (0..<8).map { play("Then \($0)", by: "Then", hoursAgo: 24 * 120 + Double($0)) }
        plays += (0..<3).map { play("Now \($0)", by: "Now", hoursAgo: Double($0 + 1)) }
        let since = now.addingTimeInterval(-24 * 3_600 * 180)
        #expect(PlayFacts.favoriteArtists(in: ListeningHistory(plays), since: since, now: now).map(\.name) == ["Then", "Now"])
        let lately = PlayFacts.favoriteArtists(in: ListeningHistory(plays), since: since, halfLife: 30 * 24 * 3_600, now: now)
        #expect(lately.map(\.name) == ["Now", "Then"])
        #expect(lately.last?.plays == 8, "Counts stay counts")
    }

    @Test("an artist's songs come most played first, with their newest id")
    func songsByArtist() {
        let plays = [
            play("Hit", by: "A", hoursAgo: 5, songID: ""), play("Hit", by: "A", hoursAgo: 3, songID: "newer"),
            play("Hit", by: "A", hoursAgo: 1, songID: ""), play("B-Side", by: "A", hoursAgo: 2),
            play("Other", by: "B", hoursAgo: 2),
        ]
        let songs = PlayFacts.songs(byArtist: StatsCalculator.folded("A"), in: ListeningHistory(plays))
        #expect(songs.map(\.title) == ["Hit", "B-Side"])
        #expect(songs.first?.plays == 3)
        #expect(songs.first?.songID == "id.Hit")
    }
}
