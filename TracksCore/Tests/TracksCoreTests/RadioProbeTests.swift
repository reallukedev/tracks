import Foundation
import Testing
@testable import TracksCore

@Suite("Tracks Radio probing what you want to hear")
struct RadioProbeTests {
    /// Shares of the radio, as songs of equal weight: seven families worth trying, and Polka,
    /// too small to be one.
    static let families: [(genre: String, songs: Int)] = [
        ("Alternative", 40), ("Hip-Hop/Rap", 30), ("Pop", 25), ("Jazz", 20),
        ("Country", 15), ("Electronic", 12), ("R&B/Soul", 10), ("Polka", 2),
    ]

    let yours: [LiveMix.Candidate] = RadioProbeTests.families.flatMap { family in
        (0..<family.songs).map { index in
            LiveMix.Candidate(
                song: RadioProbeTests.song("\(family.genre) \(index)", artist: "\(family.genre) Artist \(index % 6)"),
                weight: 1,
                genre: family.genre,
                releaseYear: 1975 + (index % 5) * 10
            )
        }
    }

    let new: [LiveMix.Candidate] = (0..<30).map { index in
        let genre = RadioProbeTests.families[index % 7].genre
        return LiveMix.Candidate(
            song: RadioProbeTests.song("New \(index)", artist: "Newcomer \(index)"),
            weight: 1,
            isNew: true,
            genre: genre,
            releaseYear: 2020
        )
    }

    static let evening = RadioMoment(hour: 20)
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

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

    func candidate(_ song: MixSong) -> LiveMix.Candidate? {
        (yours + new).first { $0.song.songIdentity == song.songIdentity }
    }

    func family(_ song: MixSong) -> String? {
        candidate(song)?.genre
    }

    func radio(seed: UInt64, newShare: Double = 0, habits: RadioHabits = RadioHabits(), probing: Bool = true) -> LiveMix {
        var mix = LiveMix(candidates: yours + new, newShare: newShare, moment: Self.evening, seed: seed)
        mix.begin(with: habits, probing: probing, now: Self.now)
        return mix
    }

    /// The opener and the picks after it, as the player makes them.
    func probe(_ mix: inout LiveMix, count: Int) -> [MixSong] {
        var picks: [MixSong] = []
        if let first = mix.opener(where: { _ in true }) { picks.append(first) }
        while picks.count < count, let next = mix.next() { picks.append(next) }
        return picks
    }

    // MARK: - The probe

    @Test("the opening picks each come from a different genre family, by different artists, and say why", arguments: 1...40 as ClosedRange<UInt64>)
    func spreadsAcrossFamilies(seed: UInt64) {
        var mix = radio(seed: seed)
        #expect(mix.isProbing)
        let picks = probe(&mix, count: RadioProbe.length)
        #expect(picks.count == RadioProbe.length)
        #expect(Set(picks.compactMap(family)).count == RadioProbe.length)
        #expect(Set(picks.map(\.artistName)).count == RadioProbe.length)
        #expect(picks.allSatisfy { mix.reason(for: $0.songIdentity) == .probing })
    }

    @Test("the probe tries the families you play most, and never one too small to be a direction")
    func favorsBigFamilies() {
        var alternative = 0
        var polka = 0
        for seed in 1...200 as ClosedRange<UInt64> {
            var mix = radio(seed: seed)
            let families = Set(probe(&mix, count: RadioProbe.length).compactMap(family))
            if families.contains("Alternative") { alternative += 1 }
            if families.contains("Polka") { polka += 1 }
        }
        #expect(alternative > 170)
        #expect(polka == 0)
    }

    @Test("the probe tries different decades within its families")
    func alternatesDecades() {
        var spread = 0
        for seed in 1...50 as ClosedRange<UInt64> {
            var mix = radio(seed: seed)
            let decades = Set(probe(&mix, count: RadioProbe.length).compactMap { candidate($0)?.decade })
            if decades.count == RadioProbe.length { spread += 1 }
        }
        #expect(spread > 45)
    }

    @Test("new finds take their tuned share of the probe", arguments: [(0.08, 0), (0.25, 1), (0.5, 2)])
    func newFindsInProbe(share: Double, expected: Int) {
        for seed in 1...20 as ClosedRange<UInt64> {
            var mix = radio(seed: seed, newShare: share)
            let picks = probe(&mix, count: RadioProbe.length)
            #expect(picks.count { candidate($0)?.isNew == true } >= expected)
            #expect(candidate(picks[0])?.isNew == false, "The opener is always one of yours")
        }
    }

    @Test("a small library isn't probed")
    func smallLibrary() {
        var mix = LiveMix(candidates: Array(yours.prefix(12)), moment: Self.evening, seed: 1)
        mix.begin(with: RadioHabits(), probing: true, now: Self.now)
        #expect(!mix.isProbing)
    }

    @Test("blocked artists and resting songs stay out of the probe", arguments: 1...20 as ClosedRange<UInt64>)
    func blockedAndResting(seed: UInt64) {
        let resting = yours.map { candidate in
            candidate.genre == "Alternative" && candidate.song.artistName.hasSuffix("0")
                ? LiveMix.Candidate(song: candidate.song, weight: candidate.weight, isResting: true, genre: candidate.genre, releaseYear: candidate.releaseYear)
                : candidate
        }
        var mix = LiveMix(candidates: resting, moment: Self.evening, seed: seed)
        mix.blocked = BlockedArtists(["Hip-Hop/Rap Artist 1", "Pop Artist 2"])
        mix.begin(with: RadioHabits(), probing: true, now: Self.now)
        let picks = probe(&mix, count: RadioProbe.length)
        #expect(!picks.contains { ["Hip-Hop/Rap Artist 1", "Pop Artist 2"].contains($0.artistName) })
        #expect(!picks.contains { $0.artistName == "Alternative Artist 0" })
    }

    // MARK: - Learning from it

    /// Probes, lets every song in `landing` play through and skips the rest, then counts the
    /// next picks in `landing`.
    func picksAfterProbe(landing: String?, seeds: ClosedRange<UInt64>, after: Int = 15) -> (landing: Int, probed: Int) {
        var count = 0
        var probed = 0
        for seed in seeds {
            var mix = radio(seed: seed)
            let picks = probe(&mix, count: RadioProbe.length)
            guard picks.contains(where: { family($0) == "Jazz" }) else { continue }
            probed += 1
            if let landing {
                for pick in picks { mix.note(family(pick) == landing ? .finished : .skipped, of: pick.songIdentity) }
            }
            count += (0..<after).compactMap { _ in mix.next() }.count { family($0) == "Jazz" }
        }
        return (count, probed)
    }

    @Test("a probe song let play makes its family come up far more after the probe")
    func probeOutcomesShiftPicks() {
        let landed = picksAfterProbe(landing: "Jazz", seeds: 1...150)
        let unheard = picksAfterProbe(landing: nil, seeds: 1...150)
        let landedRate = Double(landed.landing) / Double(landed.probed)
        let unheardRate = Double(unheard.landing) / Double(unheard.probed)
        #expect(landed.probed > 40)
        // About twice as often, measured; well clear of chance at these counts.
        #expect(landedRate > unheardRate * 1.6)
    }

    @Test("once something lands, the probe ends and says what it settled on")
    func settles() throws {
        var mix = radio(seed: 9)
        let picks = probe(&mix, count: RadioProbe.length)
        let first = try #require(picks.first)
        mix.note(.finished, of: first.songIdentity)
        for pick in picks.dropFirst() { mix.note(.skipped, of: pick.songIdentity) }
        let drawnNext = mix.next()
        let next = try #require(drawnNext)
        #expect(!mix.isProbing)
        #expect(mix.reason(for: next.songIdentity) != .probing)
        #expect(mix.steering == .settledOn(try #require(family(first))))
    }

    @Test("a probe that's all skips tries directions it hasn't yet, until there are none", arguments: 1...30 as ClosedRange<UInt64>)
    func allSkipsExtend(seed: UInt64) {
        var mix = radio(seed: seed)
        var picks = probe(&mix, count: 1)
        // Each song skipped as the next starts, as the player tells it, until every family
        // worth trying has been.
        let directions = Self.families.count - 1
        while picks.count < directions, let next = mix.next() {
            if let last = picks.last { mix.note(.skipped, of: last.songIdentity) }
            picks.append(next)
        }
        #expect(mix.isProbing)
        #expect(mix.steering == .tryingSomethingElse)
        #expect(Set(picks.compactMap(family)).count == directions, "Every try is a direction not tried yet")

        mix.note(.skipped, of: picks[picks.count - 1].songIdentity)
        let drawnAfter = mix.next()
        #expect(drawnAfter != nil)
        #expect(!mix.isProbing)
    }

    @Test("loving a song ends the probe at once and follows it")
    func loveEndsProbe() throws {
        var mix = radio(seed: 4)
        let picks = probe(&mix, count: 2)
        let loved = try #require(picks.first)
        mix.noteLoved(loved.songIdentity)
        #expect(!mix.isProbing)
        #expect(mix.steering == .towardArtist(loved.artistName))
        let drawnNext = mix.next()
        let next = try #require(drawnNext)
        #expect(mix.reason(for: next.songIdentity) != .probing)
    }

    // MARK: - Across listens

    @Test("what lands is kept by the moment, counts double in the probe, and fades with time")
    func habitsUpdateAndFade() throws {
        var mix = radio(seed: 2)
        let picks = probe(&mix, count: RadioProbe.length)
        let first = try #require(picks.first)
        let key = try #require(candidate(first)?.genreKey)
        mix.note(.finished, of: first.songIdentity)
        let drawnLater = mix.next()
        let later = try #require(drawnLater)
        let laterKey = try #require(candidate(later)?.genreKey)
        mix.note(.finished, of: later.songIdentity)

        let habits = try #require(mix.habits(at: Self.now))
        let probed = habits.tally(genre: key, in: .evening)
        #expect(probed.landed >= 2)
        if laterKey != key {
            #expect(habits.tally(genre: laterKey, in: .evening).landed == 1)
        }
        #expect(habits.tally(genre: key, in: .morning).landed == probed.landed * RadioHabits.elsewhere)

        let faded = habits.decayed(to: Self.now.addingTimeInterval(RadioHabits.halfLife))
        #expect(abs(faded.tally(genre: key, in: .evening).landed - probed.landed / 2) < 0.001)
        #expect(RadioHabits(stored: habits.stored) == habits)
    }

    @Test("a mix that isn't Tracks Radio keeps no habits")
    func noHabitsWithoutBegin() {
        let mix = LiveMix(candidates: yours, seed: 1)
        #expect(mix.habits(at: Self.now) == nil)
        #expect(!mix.isProbing)
    }

    @Test("habits from earlier listens lead the probe toward what landed and away from what didn't")
    func habitsSteerTheProbe() {
        var habits = RadioHabits()
        for _ in 0..<8 {
            habits.record(landed: 1, missed: 0, genre: "jazz", decade: nil, isNew: false, in: .evening)
            habits.record(landed: 0, missed: 1, genre: "alternative", decade: nil, isNew: false, in: .evening)
        }
        var jazzFirst = 0
        var jazzFirstUnknown = 0
        var alternative = 0
        for seed in 1...100 as ClosedRange<UInt64> {
            var unknown = radio(seed: seed)
            if probe(&unknown, count: 1).first.flatMap(family) == "Jazz" { jazzFirstUnknown += 1 }
            var mix = radio(seed: seed, habits: habits)
            let picks = probe(&mix, count: RadioProbe.length)
            if picks.first.flatMap(family) == "Jazz" { jazzFirst += 1 }
            // Knowing this hour a little, the probe is shorter: only its own picks count.
            if picks.contains(where: { family($0) == "Alternative" && mix.reason(for: $0.songIdentity) == .probing }) { alternative += 1 }
        }
        #expect(jazzFirst > jazzFirstUnknown * 3)
        #expect(alternative == 0)
    }

    @Test("a moment it knows well gets a shorter probe")
    func shorterWhenKnown() {
        var habits = RadioHabits()
        for genre in ["alternative", "jazz", "pop", "country"] {
            habits.record(landed: 10, missed: 5, genre: genre, decade: nil, isNew: false, in: .evening)
        }
        var mix = radio(seed: 1, habits: habits)
        var picks = probe(&mix, count: 1)
        while mix.isProbing, let next = mix.next() {
            picks.append(next)
            mix.note(.finished, of: picks[picks.count - 2].songIdentity)
        }
        #expect(picks.count < RadioProbe.length)
    }

    // MARK: - Where it doesn't probe

    @Test("a listen started from a song, a mood or Autoplay never probes")
    func onlyFreshRadioProbes() throws {
        var started = radio(seed: 3, probing: false)
        #expect(!started.isProbing)
        let drawnNext = started.next()
        let next = try #require(drawnNext)
        #expect(started.reason(for: next.songIdentity) != .probing)

        var mood = LiveMix.mood(.chill, from: ListeningHistory([]), newFinds: yours.map(\.song), seed: 3)
        let picks = (0..<10).compactMap { _ in mood.next() }
        #expect(!mood.isProbing)
        #expect(!picks.contains { mood.reason(for: $0.songIdentity) == .probing })
    }

    @Test("the same seed, habits and listening make the same radio")
    func deterministic() {
        func run() -> [String] {
            var mix = radio(seed: 77, newShare: 0.25)
            var picks = probe(&mix, count: 1)
            for index in 0..<20 {
                guard let next = mix.next() else { break }
                mix.note(index % 3 == 0 ? .finished : .skipped, of: picks[picks.count - 1].songIdentity)
                picks.append(next)
            }
            return picks.map(\.songIdentity)
        }
        #expect(run() == run())
    }

    @Test("retuning carries the probe and what it has learned")
    func retuneKeepsProbe() throws {
        var mix = radio(seed: 6)
        let picks = probe(&mix, count: 3)
        mix.note(.finished, of: picks[0].songIdentity)
        var retuned = LiveMix(candidates: yours + new, moment: RadioMoment(hour: 23), seed: 6)
        retuned.continueListen(from: mix)
        #expect(retuned.isProbing)
        let drawnNext = retuned.next()
        let next = try #require(drawnNext)
        #expect(!Set(picks.compactMap(family)).contains(try #require(family(next))))
        let habits = try #require(retuned.habits(at: Self.now))
        #expect(habits.tally(genre: try #require(candidate(picks[0])?.genreKey), in: .evening).landed >= 2)
    }
}
