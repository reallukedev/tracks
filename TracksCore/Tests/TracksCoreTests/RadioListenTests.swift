import Foundation
import Testing
@testable import TracksCore

@Suite("How a listen went, and why songs come up")
struct RadioListenTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func song(_ title: String, artist: String) -> MixSong {
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

    /// 60 songs by 30 artists, two genres alternating, none new.
    let twoGenres: [LiveMix.Candidate] = (0..<60).map { index in
        LiveMix.Candidate(
            song: RadioListenTests.song("S\(index)", artist: "Artist \(index % 30)"),
            weight: 1,
            genre: index.isMultiple(of: 2) ? "Jazz" : "Metal"
        )
    }

    func genre(of song: MixSong, in candidates: [LiveMix.Candidate]) -> String? {
        candidates.first { $0.song.songIdentity == song.songIdentity }?.genre
    }

    /// A play of a song at a given time before `now`.
    func play(_ title: String, by artist: String, hoursAgo: Double) -> CaptureStat {
        CaptureStat(songKey: title, songID: title, title: title, artistName: artist, capturedAt: now.addingTimeInterval(-hoursAgo * 3_600))
    }

    // MARK: - Listens

    @Test("when a song gave way tells a skip, a song moved on from, and one let play", arguments: [
        (10.0, 240.0, LiveMix.Listen.skipped),
        (29.0, 240.0, .skipped),
        (60.0, 240.0, .movedOn),
        (140.0, 240.0, .movedOn),
        (150.0, 240.0, .finished),
        (200.0, 240.0, .finished),
        (60.0, 100.0, .finished),
        (60.0, nil, .finished),
    ] as [(TimeInterval, TimeInterval?, LiveMix.Listen)])
    func listens(playedFor: TimeInterval, duration: TimeInterval?, expected: LiveMix.Listen) {
        #expect(LiveMix.Listen(playedFor: playedFor, duration: duration) == expected)
    }

    @Test("songs moved on from make a run beside a real skip, or once there are three of them")
    func movedOnRun() {
        var mix = LiveMix(candidates: twoGenres, seed: 1)
        mix.note(.movedOn, of: twoGenres[0].song.songIdentity)
        mix.note(.movedOn, of: twoGenres[2].song.songIdentity)
        #expect(mix.steering == nil, "Two songs heard a while each are how plenty of people listen")
        mix.note(.movedOn, of: twoGenres[4].song.songIdentity)
        #expect(mix.steering == .awayFromGenre("Jazz"))

        var withSkip = LiveMix(candidates: twoGenres, seed: 1)
        withSkip.note(.movedOn, of: twoGenres[0].song.songIdentity)
        withSkip.note(.skipped, of: twoGenres[2].song.songIdentity)
        #expect(withSkip.steering == .awayFromGenre("Jazz"))
    }

    @Test("a song moved on from never counts as the one a search was looking for")
    func movedOnDoesNotEndSearch() {
        var mix = LiveMix(candidates: twoGenres, seed: 1)
        mix.noteSkipped(twoGenres[0].song.songIdentity)
        mix.noteSkipped(twoGenres[2].song.songIdentity)
        mix.note(.movedOn, of: twoGenres[1].song.songIdentity)
        #expect(mix.steering == .tryingSomethingElse, "Still searching, now across both genres")
        mix.note(.finished, of: twoGenres[3].song.songIdentity)
        #expect(mix.steering == .towardGenre("Metal"))
    }

    @Test("moving on from an artist makes them rarer, though less than a skip does")
    func movedOnWeighsLess() {
        let songs = (0..<60).map { Self.song("S\($0)", artist: "Artist \($0 % 6)") }
        func plays(after listen: LiveMix.Listen) -> Int {
            (1...150 as ClosedRange<UInt64>).reduce(0) { count, seed in
                var mix = LiveMix(candidates: songs.map { .init(song: $0, weight: 1) }, seed: seed)
                mix.note(listen, of: songs[0].songIdentity)
                return count + (0..<12).compactMap { _ in mix.next() }.count { $0.artistName == "Artist 0" }
            }
        }
        let (skipped, movedOn, finished) = (plays(after: .skipped), plays(after: .movedOn), plays(after: .finished))
        #expect(skipped < movedOn)
        #expect(movedOn < finished)
    }

    // MARK: - Balance and flow

    @Test("an artist with many songs doesn't take over the radio, and still comes up")
    func prolificArtist() {
        var plays: [CaptureStat] = []
        for index in 0..<30 {
            for round in 0..<3 {
                plays.append(play("Big \(index)", by: "Big Band", hoursAgo: Double(24 + index * 30 + round)))
                plays.append(play("Solo \(index)", by: "Solo \(index)", hoursAgo: Double(24 + index * 30 + round + 10)))
            }
        }
        let history = ListeningHistory(plays)
        var big = 0
        var total = 0
        for seed in 1...40 as ClosedRange<UInt64> {
            var mix = LiveMix.tracksRadio(from: history, now: now, seed: seed)
            let picks = (0..<20).compactMap { _ in mix.next() }
            big += picks.count { $0.artistName == "Big Band" }
            total += picks.count
        }
        // Half the songs are theirs; well under a quarter of the picks are.
        #expect(big * 4 < total)
        #expect(big > 0)
    }

    @Test("an artist with many songs is spaced out, even before any balancing")
    func artistMemory() {
        // Half the songs are one artist's, the rest by thirty others, all even.
        let candidates = (0..<30).map { LiveMix.Candidate(song: Self.song("Big \($0)", artist: "Big Band"), weight: 1) }
            + (0..<30).map { LiveMix.Candidate(song: Self.song("Solo \($0)", artist: "Solo \($0)"), weight: 1) }
        var big = 0
        var total = 0
        for seed in 1...60 as ClosedRange<UInt64> {
            var mix = LiveMix(candidates: candidates, seed: seed)
            let picks = (0..<20).compactMap { _ in mix.next() }
            big += picks.count { $0.artistName == "Big Band" }
            total += picks.count
        }
        // Kept only from following themselves, they'd be well over a third of the picks.
        #expect(big * 100 < total * 30)
    }

    @Test("a mix of only a few artists isn't made to go round them in turn")
    func fewArtists() {
        #expect(LiveMix.artistMemory(artists: 6) <= 2)
        #expect(LiveMix.artistMemory(artists: 400) == LiveMix.artistMemory)
    }

    @Test("each pick leans toward the genre of the song before it")
    func flow() {
        var same = 0
        var pairs = 0
        for seed in 1...80 as ClosedRange<UInt64> {
            var mix = LiveMix(candidates: twoGenres, seed: seed)
            let genres = (0..<10).compactMap { _ in mix.next() }.map { genre(of: $0, in: twoGenres) }
            for (a, b) in zip(genres, genres.dropFirst()) {
                pairs += 1
                if a == b { same += 1 }
            }
        }
        // Even would be half.
        #expect(same * 100 > pairs * 53)
        // And never only one genre.
        #expect(same < pairs * 3 / 4)
    }

    @Test("a song skipped once lately comes up less, even off the road")
    func skippedOnce() {
        var plays: [CaptureStat] = []
        for index in 0..<20 {
            plays.append(play("Song \(index)", by: "Artist \(index)", hoursAgo: Double(24 + index)))
        }
        let history = ListeningHistory(plays)
        var signals = ListeningSignals()
        let skipped = HistoryImport.key(title: "Song 0", artistName: "Artist 0")
        signals.recordSkip(of: skipped, at: now.addingTimeInterval(-86_400))
        func early(_ signals: ListeningSignals) -> Int {
            (1...200 as ClosedRange<UInt64>).reduce(0) { count, seed in
                var mix = LiveMix.tracksRadio(from: history, signals: signals, now: now, seed: seed)
                return count + ((0..<4).compactMap { _ in mix.next() }.contains { $0.songIdentity == skipped } ? 1 : 0)
            }
        }
        #expect(early(signals) * 10 < early(ListeningSignals()) * 8)
    }

    @Test("a song heard yesterday gives way to others, and is back in full after a few days")
    func freshness() {
        #expect(LiveMix.freshness(lastHeard: now.addingTimeInterval(-24 * 3_600), now: now) < 0.8)
        #expect(LiveMix.freshness(lastHeard: now.addingTimeInterval(-12 * 3_600), now: now)
            < LiveMix.freshness(lastHeard: now.addingTimeInterval(-48 * 3_600), now: now))
        #expect(LiveMix.freshness(lastHeard: now.addingTimeInterval(-7 * 86_400), now: now) > 0.98)
    }

    @Test("a listen opens on one of your strongest songs, never a new find while yours are there", arguments: 1...40 as ClosedRange<UInt64>)
    func opener(seed: UInt64) throws {
        let yours = (0..<30).map { index in
            LiveMix.Candidate(song: Self.song("Y\(index)", artist: "Y\(index)"), weight: index < 3 ? 12 : 1)
        }
        let new = (0..<30).map { LiveMix.Candidate(song: Self.song("N\($0)", artist: "N\($0)"), weight: 1, isNew: true) }
        var mix = LiveMix(candidates: yours + new, newShare: 0.6, seed: seed)
        let first = mix.opener(where: { _ in true })
        let pick = try #require(first)
        #expect(!pick.title.hasPrefix("N"))
        #expect(mix.hasPicked(pick.songIdentity))
    }

    @Test("the strongest songs open far more often than their share")
    func openerLeans() {
        let yours = (0..<30).map { index in
            LiveMix.Candidate(song: Self.song("Y\(index)", artist: "Y\(index)"), weight: index < 3 ? 4 : 1)
        }
        let strong = (1...200 as ClosedRange<UInt64>).count { seed in
            var mix = LiveMix(candidates: yours, seed: seed)
            return mix.opener(where: { _ in true }).map { ["Y0", "Y1", "Y2"].contains($0.title) } ?? false
        }
        // Their share of the weight is 12 in 39, under a third; squared it's 48 in 75.
        #expect(strong > 200 / 2)
    }

    @Test("with none of yours to open on, a listen opens on whatever passes")
    func openerFallsBack() {
        let new = (0..<5).map { LiveMix.Candidate(song: Self.song("N\($0)", artist: "N\($0)"), weight: 1, isNew: true) }
        var mix = LiveMix(candidates: new, seed: 1)
        #expect(mix.opener(where: { _ in true }) != nil)
        var nothing = LiveMix(candidates: new, seed: 1)
        #expect(nothing.opener(where: { _ in false }) == nil)
    }

    // MARK: - Reasons

    @Test("a new find says so")
    func newFindReason() throws {
        let find = Self.song("Find", artist: "Stranger")
        var mix = LiveMix(candidates: [.init(song: find, weight: 1, isNew: true)], seed: 1)
        let next = mix.next()
        let pick = try #require(next)
        #expect(mix.reason(for: pick.songIdentity) == .newFind)
    }

    @Test("a new find says why it was suggested, or that it's by an artist you play, or just that it's new")
    func newFindReasons() {
        let history = ListeningHistory([play("Known", by: "Mara Solis", hoursAgo: 48)])
        let byYours = Self.song("Unheard", artist: "Mara Solis")
        let like = Self.song("Kindred", artist: "Nova Harbor")
        let stranger = Self.song("Cold", artist: "Nobody")
        let mix = LiveMix.tracksRadio(
            from: history,
            newFinds: [byYours, like, stranger],
            newFindReasons: [like.songIdentity: .newFindLike("Mara Solis")],
            now: now,
            seed: 1
        )
        #expect(mix.reason(for: byYours.songIdentity) == .newFromYourArtist)
        #expect(mix.reason(for: like.songIdentity) == .newFindLike("Mara Solis"))
        #expect(mix.reason(for: stranger.songIdentity) == .newFind)
    }

    @Test("a song played far more than the rest is among your most played; a small history has none")
    func mostPlayedReason() {
        var plays: [CaptureStat] = (0..<40).map { play("Song \($0)", by: "Artist \($0)", hoursAgo: Double(24 + $0)) }
        for round in 0..<30 { plays.append(play("Song 0", by: "Artist 0", hoursAgo: Double(100 + round))) }
        let mix = LiveMix.tracksRadio(from: ListeningHistory(plays), now: now, seed: 1)
        #expect(mix.reason(for: HistoryImport.key(title: "Song 0", artistName: "Artist 0")) == .mostPlayed)
        #expect(mix.reason(for: HistoryImport.key(title: "Song 1", artistName: "Artist 1")) == nil)

        let small = (0..<5).flatMap { index in (0..<3).map { play("Tiny \(index)", by: "A\(index)", hoursAgo: Double(24 + index * 5 + $0)) } }
        let tiny = LiveMix.tracksRadio(from: ListeningHistory(small), now: now, seed: 1)
        #expect(tiny.candidates.allSatisfy { $0.reason == nil })
    }

    @Test("a song in a genre leaned into says the genre as it was picked")
    func leaningReason() {
        let key = HistoryImport.key(title: "Beat", artistName: "MC")
        let history = ListeningHistory([play("Beat", by: "MC", hoursAgo: 48)])
            .with(artistArtwork: [:], songMetadata: [key: SongMetadata(genre: "Hip-Hop/Rap", releaseYear: nil)])
        let mix = LiveMix.tracksRadio(from: history, tuning: RadioTuning(genres: ["Hip-Hop"]), now: now, seed: 1)
        #expect(mix.reason(for: key) == .leaningInto("Hip-Hop"))
    }

    @Test("an old favorite brought back says when it was last heard, only when the tuning brings them back")
    func oldFavoriteReason() {
        let heard = now.addingTimeInterval(-200 * 86_400)
        let history = ListeningHistory([CaptureStat(songKey: "Old", songID: "Old", title: "Old", artistName: "Past", capturedAt: heard)])
        let key = HistoryImport.key(title: "Old", artistName: "Past")
        let bringsBack = LiveMix.tracksRadio(from: history, tuning: RadioTuning(bringsBackOldFavorites: true), now: now, seed: 1)
        #expect(bringsBack.reason(for: key) == .oldFavorite(lastHeard: heard))
        let standard = LiveMix.tracksRadio(from: history, now: now, seed: 1)
        #expect(standard.reason(for: key) == nil)
    }

    @Test("a song you play around this hour says so when the radio follows the time")
    func aroundNowReason() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let hour = calendar.component(.hour, from: now)
        let isWeekend = calendar.isDateInWeekend(now)
        var plays: [CaptureStat] = []
        // Night Song, always within the hour of now, a week apart; the rest twelve hours away.
        for week in 1...5 {
            plays.append(play("Night Song", by: "Owl", hoursAgo: Double(week * 7 * 24)))
            for index in 0..<6 { plays.append(play("Day \(index)", by: "Lark \(index)", hoursAgo: Double(week * 7 * 24 + 12))) }
        }
        let moment = RadioMoment(hour: hour, isWeekend: isWeekend)
        let mix = LiveMix.tracksRadio(from: ListeningHistory(plays), moment: moment, now: now, calendar: calendar, seed: 1)
        #expect(mix.reason(for: HistoryImport.key(title: "Night Song", artistName: "Owl")) == .aroundNow)
        #expect(mix.reason(for: HistoryImport.key(title: "Day 0", artistName: "Lark 0")) == nil)

        let anytime = LiveMix.tracksRadio(from: ListeningHistory(plays), now: now, calendar: calendar, seed: 1)
        #expect(anytime.reason(for: HistoryImport.key(title: "Night Song", artistName: "Owl")) == nil)
    }

    @Test("a song played on a drive says so while the radio plays for the road")
    func roadReason() {
        let heard = now.addingTimeInterval(-3 * 86_400)
        let history = ListeningHistory([
            CaptureStat(songKey: "Highway", songID: "Highway", title: "Highway", artistName: "Wheels", capturedAt: heard),
            CaptureStat(songKey: "Couch", songID: "Couch", title: "Couch", artistName: "Home", capturedAt: heard.addingTimeInterval(-86_400)),
        ])
        let drives = DriveLog(drives: [DateInterval(start: heard.addingTimeInterval(-600), duration: 1_800)])
        let driving = LiveMix.tracksRadio(from: history, moment: RadioMoment(isDriving: true), drives: drives, now: now, seed: 1)
        #expect(driving.reason(for: HistoryImport.key(title: "Highway", artistName: "Wheels")) == .onTheRoad)
        #expect(driving.reason(for: HistoryImport.key(title: "Couch", artistName: "Home")) == nil)
        let parked = LiveMix.tracksRadio(from: history, drives: drives, now: now, seed: 1)
        #expect(parked.reason(for: HistoryImport.key(title: "Highway", artistName: "Wheels")) == nil)
    }

    @Test("after a run of skips, a pick in the genre let play says it's more of it, and keeps saying so after a retune")
    func steeringReason() throws {
        var mix = LiveMix(candidates: twoGenres, seed: 3)
        mix.noteSkipped(twoGenres[0].song.songIdentity)
        mix.noteSkipped(twoGenres[2].song.songIdentity)
        mix.noteFinished(twoGenres[1].song.songIdentity)
        #expect(mix.steering == .towardGenre("Metal"))
        let next = mix.next(where: { genre(of: $0, in: twoGenres) == "Metal" })
        let metal = try #require(next)
        #expect(mix.reason(for: metal.songIdentity) == .moreOf("Metal"))

        var retuned = LiveMix(candidates: twoGenres, seed: 4)
        retuned.continueListen(from: mix)
        #expect(retuned.reason(for: metal.songIdentity) == .moreOf("Metal"))
    }

    @Test("a song come round again says why it came up this time, not what it came up for before")
    func reasonComesRoundAgain() throws {
        var mix = LiveMix(candidates: twoGenres, seed: 1)
        mix.noteSkipped(twoGenres[0].song.songIdentity)
        mix.noteSkipped(twoGenres[2].song.songIdentity)
        mix.noteFinished(twoGenres[1].song.songIdentity)
        let first = mix.next(where: { genre(of: $0, in: twoGenres) == "Metal" })
        let steered = try #require(first)
        #expect(mix.reason(for: steered.songIdentity) == .moreOf("Metal"))
        // Round every song and more, until it comes up again, long after homing in has eased.
        var again = false
        for _ in 0..<150 where !again {
            again = mix.next() == steered
        }
        #expect(again)
        #expect(mix.reason(for: steered.songIdentity) != .moreOf("Metal"))
    }

    @Test("more of a genre is said only while letting one play still counts for much")
    func moreOfFades() {
        var mix = LiveMix(candidates: twoGenres, seed: 5)
        mix.noteSkipped(twoGenres[0].song.songIdentity)
        mix.noteSkipped(twoGenres[2].song.songIdentity)
        mix.noteFinished(twoGenres[1].song.songIdentity)
        #expect(mix.steering == .towardGenre("Metal"))
        for _ in 0..<30 { _ = mix.next() }
        let next = mix.next(where: { genre(of: $0, in: twoGenres) == "Metal" })
        #expect(next.map { mix.reason(for: $0.songIdentity) } == .some(nil), "Thirty picks on, the boost has eased back")
    }

    @Test("a song queued before a retune keeps saying why it was picked, even when nothing stood out")
    func reasonSurvivesRetune() throws {
        let plain = (0..<10).map { LiveMix.Candidate(song: Self.song("P\($0)", artist: "P\($0)"), weight: 1) }
        var mix = LiveMix(candidates: plain, seed: 1)
        let next = mix.next()
        let queued = try #require(next)
        #expect(mix.reason(for: queued.songIdentity) == nil)
        // Retuned to lean into something the queued song happens to be.
        let leaning = plain.map { LiveMix.Candidate(song: $0.song, weight: 1, reason: .leaningInto("Jazz")) }
        var retuned = LiveMix(candidates: leaning, seed: 2)
        retuned.continueListen(from: mix)
        #expect(retuned.reason(for: queued.songIdentity) == nil)
        // A song it never drew says what it stands for.
        let undrawn = try #require(plain.map(\.song).first { !mix.hasPicked($0.songIdentity) })
        #expect(retuned.reason(for: undrawn.songIdentity) == .leaningInto("Jazz"))
    }

    @Test("a share of new finds tuned below the usual floor is never raised by skipping one")
    func lowShareStaysLow() {
        let yours = (0..<20).map { LiveMix.Candidate(song: Self.song("Y\($0)", artist: "Y\($0)"), weight: 1) }
        let new = (0..<20).map { LiveMix.Candidate(song: Self.song("N\($0)", artist: "N\($0)"), weight: 1, isNew: true) }
        var mix = LiveMix(candidates: yours + new, newShare: 0.032, seed: 1)
        mix.noteSkipped(new[0].song.songIdentity)
        #expect(mix.newShare <= 0.032)
        var retuned = LiveMix(candidates: yours + new, newShare: 0.032, seed: 2)
        retuned.continueListen(from: mix)
        #expect(retuned.newShare <= 0.032)
    }

    @Test("after a love, songs in its genre say they're more like its artist, while that counts for much")
    func lovedGenreReason() throws {
        var mix = LiveMix(candidates: twoGenres, seed: 3)
        // S0 is Jazz, by Artist 0.
        mix.noteLoved(twoGenres[0].song.songIdentity)
        let next = mix.next(where: { genre(of: $0, in: twoGenres) == "Jazz" && $0.artistName != "Artist 0" })
        let jazz = try #require(next)
        #expect(mix.reason(for: jazz.songIdentity) == .moreLike("Artist 0"))
        for _ in 0..<12 { _ = mix.next() }
        let later = mix.next(where: { genre(of: $0, in: twoGenres) == "Jazz" && $0.artistName != "Artist 0" })
        let faded = try #require(later)
        #expect(mix.reason(for: faded.songIdentity) == nil)
    }

    @Test("a pick taken back can come up again, and no longer counts toward the artists heard")
    func release() throws {
        var mix = LiveMix(candidates: twoGenres, seed: 1)
        let next = mix.next()
        let pick = try #require(next)
        mix.release(pick.songIdentity)
        #expect(!mix.hasPicked(pick.songIdentity))
        #expect(mix.picks.isEmpty)
        var comesBack = false
        for _ in 0..<twoGenres.count where !comesBack { comesBack = mix.next() == pick }
        #expect(comesBack)
    }

    @Test("a mix knows its own songs, not the ones it follows on from")
    func knows() {
        let mix = LiveMix(candidates: twoGenres, seed: 1)
        #expect(mix.knows(twoGenres[0].song.songIdentity))
        #expect(!mix.knows(Self.song("Seed", artist: "Queue").songIdentity))
    }

    @Test("loving a song says the next of that artist's songs is more like them")
    func lovedReason() throws {
        let candidates = (0..<12).map { LiveMix.Candidate(song: Self.song("S\($0)", artist: "Artist \($0 % 4)"), weight: 1) }
        var mix = LiveMix(candidates: candidates, seed: 2)
        mix.noteLoved(candidates[0].song.songIdentity)
        let next = mix.next(where: { $0.artistName == "Artist 0" && $0 != candidates[0].song })
        let same = try #require(next)
        #expect(mix.reason(for: same.songIdentity) == .moreLike("Artist 0"))
    }
}
