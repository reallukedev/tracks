import Foundation
import Testing
@testable import TracksCore

private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let day: TimeInterval = 86_400

private func identity(_ title: String, _ artist: String) -> String {
    HistoryImport.key(title: title, artistName: artist)
}

/// One sitting: the songs four minutes apart, starting `daysAgo` days before now.
private func sitting(_ songs: [(String, String)], daysAgo: Double, kind: CaptureKind = .onDemand) -> [CaptureStat] {
    songs.enumerated().map { offset, song in
        CaptureStat(
            songKey: song.0, songID: song.0, title: song.0, artistName: song.1,
            capturedAt: now.addingTimeInterval(-daysAgo * day + Double(offset) * 240), kind: kind
        )
    }
}

@Suite("Taste graph")
struct TasteGraphTests {
    @Test("songs heard in the same sittings are neighbors, and songs never heard together aren't")
    func sittings() {
        var plays: [CaptureStat] = []
        for daysAgo in 1...10 {
            plays += sitting([("A1", "A"), ("B1", "B"), ("A2", "A")], daysAgo: Double(daysAgo))
            // Hours later: another sitting.
            plays += sitting([("C1", "C"), ("D1", "D")], daysAgo: Double(daysAgo) - 0.4)
        }
        let graph = TasteGraph(history: ListeningHistory(plays), now: now)
        #expect(graph.closeness(identity("A1", "A"), identity("B1", "B")) > 0)
        #expect(graph.closeness(identity("C1", "C"), identity("D1", "D")) > 0)
        #expect(graph.closeness(identity("A1", "A"), identity("C1", "C")) == 0)
        #expect(graph.neighbors(of: identity("A1", "A")).map(\.identity).contains(identity("D1", "D")) == false)
    }

    @Test("a song played with everything isn't everyone's closest, even when it's played with them more")
    func hubs() throws {
        var plays: [CaptureStat] = []
        for daysAgo in 1...6 { plays += sitting([("A", "Ann"), ("Hub", "Hal")], daysAgo: Double(daysAgo)) }
        for daysAgo in 7...10 { plays += sitting([("A", "Ann"), ("B", "Bo")], daysAgo: Double(daysAgo)) }
        for partner in 0..<30 { plays += sitting([("Hub", "Hal"), ("X\(partner)", "Xi \(partner)")], daysAgo: 11 + Double(partner)) }
        let graph = TasteGraph(history: ListeningHistory(plays), now: now)
        let closest = try #require(graph.neighbors(of: identity("A", "Ann")).first)
        #expect(closest.identity == identity("B", "Bo"))
        #expect(closest.closeness == 1)
    }

    @Test("songs you played together count for more than ones a station put together, and recent ones for more than old ones")
    func whatCountsMore() {
        var plays: [CaptureStat] = []
        for daysAgo in 1...3 {
            plays += sitting([("A", "Ann"), ("Chosen", "Cy")], daysAgo: Double(daysAgo))
            plays += sitting([("A", "Ann"), ("Station", "Sal")], daysAgo: Double(daysAgo) + 0.3, kind: .radio)
            plays += sitting([("A", "Ann"), ("Old", "Ole")], daysAgo: Double(daysAgo) + 1_100)
        }
        let graph = TasteGraph(history: ListeningHistory(plays), now: now)
        let a = identity("A", "Ann")
        #expect(graph.closeness(a, identity("Chosen", "Cy")) > graph.closeness(a, identity("Station", "Sal")))
        #expect(graph.closeness(a, identity("Chosen", "Cy")) > graph.closeness(a, identity("Old", "Ole")))
    }

    @Test("what leads into what has a direction")
    func leads() {
        let plays = (1...5).flatMap { sitting([("Intro", "Band"), ("Single", "Band")], daysAgo: Double($0)) }
        let graph = TasteGraph(history: ListeningHistory(plays), now: now)
        #expect(graph.leads(from: identity("Intro", "Band"), into: identity("Single", "Band")) == 1)
        #expect(graph.leads(from: identity("Single", "Band"), into: identity("Intro", "Band")) == 0)
    }

    @Test("a history of one play, or none, has nothing to go on")
    func tooLittle() {
        #expect(TasteGraph(history: ListeningHistory([]), now: now).isEmpty)
        #expect(TasteGraph(history: ListeningHistory(sitting([("A", "Ann")], daysAgo: 1)), now: now).isEmpty)
    }
}

@Suite("Live mixes following what lands")
struct FollowingWhatLandsTests {
    /// Two crowds of artists, all Pop, all played as often: the X crowd always together, the
    /// Y crowd always together. Only the graph can tell them apart.
    let history: ListeningHistory = {
        var plays: [CaptureStat] = []
        var metadata: [String: SongMetadata] = [:]
        for daysAgo in 1...20 {
            for (crowd, offset) in [("X", 0.0), ("Y", 0.4)] {
                // Each day a different order, as real sittings go, so no one song always leads
                // into another.
                let songs = (0..<12).map { index in ("\(crowd)\(index % 4) \(index / 4)", "\(crowd) Artist \(index % 4)") }
                let stride = [1, 5, 7, 11][daysAgo % 4]
                let order = (0..<12).map { songs[($0 * stride + daysAgo) % 12] }
                plays += sitting(order, daysAgo: Double(daysAgo) + offset)
                for song in songs { metadata[identity(song.0, song.1)] = SongMetadata(genre: "Pop", releaseYear: 2020) }
            }
        }
        return ListeningHistory(plays).with(artistArtwork: [:], songMetadata: metadata)
    }()

    let x = identity("X0 0", "X Artist 0")
    let otherX = identity("X1 0", "X Artist 1")

    func isX(_ song: MixSong) -> Bool { song.artistName.hasPrefix("X") }

    enum Source: CaseIterable { case appleMusic, yourMusic }

    /// Every song in the history, as files of your own.
    var tracks: [LocalTrack] {
        var seen = Set<String>()
        return history.captures.compactMap { capture in
            guard seen.insert(capture.songIdentity).inserted else { return nil }
            return LocalTrack(origin: .file(path: "\(capture.artistName)/\(capture.title).flac"), title: capture.title, artist: capture.artistName, genre: "Pop")
        }
    }

    /// The share of the X crowd in picks `range`, over many listens, after `noting` each one.
    func shareOfX(in range: Range<Int>, from source: Source = .appleMusic, noting: (inout LiveMix) -> Void) -> Double {
        var crowd = 0
        var total = 0
        let tracks = source == .yourMusic ? tracks : []
        for seed in 1...60 as ClosedRange<UInt64> {
            var mix = switch source {
            case .appleMusic: LiveMix.tracksRadio(from: history, now: now, seed: seed)
            case .yourMusic: LiveMix.tracksRadio(from: tracks, history: history, now: now, seed: seed)
            }
            noting(&mix)
            let picks = (0..<range.upperBound).compactMap { _ in mix.next() }[range]
            crowd += picks.count(where: isX)
            total += picks.count
        }
        return Double(crowd) / Double(total)
    }

    @Test("with nothing heard yet, neither crowd is favored")
    func even() {
        let share = shareOfX(in: 0..<3) { _ in }
        #expect(abs(share - 0.5) < 0.12)
    }

    enum Landing: CaseIterable { case finished, loved, replayed }

    @Test("a song that lands brings its crowd from the very next pick, on Apple Music and your own music", arguments: Landing.allCases, Source.allCases)
    func lands(_ landing: Landing, from source: Source) {
        let share = shareOfX(in: 0..<3, from: source) { mix in
            switch landing {
            case .finished: mix.noteFinished(x)
            case .loved: mix.noteLoved(x)
            case .replayed: mix.noteReplayed(x)
            }
        }
        #expect(share > 0.68)
    }

    @Test("skips dim the crowd they came from")
    func skips() {
        let share = shareOfX(in: 0..<3) { mix in
            mix.noteSkipped(x)
            mix.noteSkipped(otherX)
        }
        #expect(share < 0.35)
    }

    @Test("the lift fades, so a listen follows where you are now")
    func fades() {
        let soon = shareOfX(in: 0..<3) { $0.noteFinished(x) }
        let later = shareOfX(in: 14..<20) { $0.noteFinished(x) }
        #expect(later < soon - 0.15)
    }

    @Test("a song lifted by one that landed says so, naming only that song")
    func saysWhy() {
        var reasons: [LiveMix.Reason] = []
        for seed in 1...20 as ClosedRange<UInt64> {
            var mix = LiveMix.tracksRadio(from: history, now: now, seed: seed)
            mix.noteFinished(x)
            reasons += (0..<3).compactMap { _ in mix.next() }.compactMap { mix.reason(for: $0.songIdentity) }
        }
        let goesWith = reasons.compactMap { reason -> String? in
            if case .goesWith(let title) = reason { title } else { nil }
        }
        #expect(goesWith.isEmpty == false)
        #expect(Set(goesWith) == ["X0 0"])
    }

    @Test("in a big library, a song played again still brings its small circle straight away")
    func bigLibrary() {
        var plays: [CaptureStat] = []
        let circle = (0..<8).map { ("Circle \($0)", "Circle Artist \($0)") }
        for daysAgo in 1...20 {
            let stride = [1, 3, 5, 7][daysAgo % 4]
            plays += sitting((0..<8).map { circle[($0 * stride + daysAgo) % 8] }, daysAgo: Double(daysAgo))
        }
        // 400 more songs, each played in sittings with others, never with the circle.
        for index in 0..<400 {
            let others = [index, (index * 7 + 1) % 400, (index * 13 + 5) % 400].map { ("Other \($0)", "Other Artist \($0 % 150)") }
            plays += sitting(others, daysAgo: 30 + Double(index) / 4)
        }
        let history = ListeningHistory(plays)
        let replayed = identity("Circle 0", "Circle Artist 0")
        var fromCircle = 0
        for seed in 1...60 as ClosedRange<UInt64> {
            var mix = LiveMix.tracksRadio(from: history, now: now, seed: seed)
            mix.noteReplayed(replayed)
            if mix.next()?.title.hasPrefix("Circle") == true { fromCircle += 1 }
        }
        // By chance, about one pick in fifty.
        #expect(fromCircle > 60 * 45 / 100)
    }

    @Test("a station started from a song leans toward its crowd")
    func startedFrom() {
        let share = shareOfX(in: 0..<3) { mix in
            mix.note(picked: x)
            mix.lean(toward: x)
        }
        #expect(share > 0.65)
    }
}

@Suite("Live mixes reading the listener")
struct ListenerCalibrationTests {
    /// 60 songs in three genres, as the steering tests have them.
    let candidates: [LiveMix.Candidate] = (0..<60).map { index in
        LiveMix.Candidate(
            song: RadioSteeringTests.song("S\(index)", artist: "Artist \(index % 20)"),
            weight: 1,
            genre: ["Hip-Hop/Rap", "Country", "Alternative"][index % 3],
            releaseYear: 2015
        )
    }

    func country(_ index: Int) -> String {
        candidates.filter { $0.genre == "Country" }[index].song.songIdentity
    }

    func habits(landing: Bool) -> RadioHabits {
        var habits = RadioHabits()
        for _ in 0..<20 { habits.recordListen(landed: landing) }
        return habits
    }

    @Test("two skips in a row turn the radio for someone who seldom skips, but not for someone who skips freely")
    func runs() {
        var seldom = LiveMix(candidates: candidates, seed: 1)
        seldom.begin(with: habits(landing: true), probing: false, now: now)
        var freely = LiveMix(candidates: candidates, seed: 1)
        freely.begin(with: habits(landing: false), probing: false, now: now)
        seldom.noteSkipped(country(0))
        seldom.noteSkipped(country(1))
        freely.noteSkipped(country(0))
        freely.noteSkipped(country(1))
        #expect(seldom.steering == .awayFromGenre("Country"))
        #expect(freely.steering == nil)
        freely.noteSkipped(country(2))
        #expect(freely.steering == .awayFromGenre("Country"))
    }

    @Test("playing a song again ends the opening probe, as loving one does")
    func replayEndsProbe() throws {
        var mix = LiveMix(candidates: candidates, seed: 4)
        mix.begin(with: RadioHabits(), probing: true, now: now)
        let opener = try #require(mix.opener { _ in true })
        #expect(mix.isProbing)
        mix.noteReplayed(opener.songIdentity)
        #expect(mix.isProbing == false)
    }

    @Test("how readily someone skips is learned across listens, and this listen counts too")
    func skipRate() {
        var mix = LiveMix(candidates: candidates, seed: 1)
        #expect(abs(mix.expectedSkipRate() - LiveMix.usualSkipRate) < 0.001)
        mix.begin(with: habits(landing: false), probing: false, now: now)
        let skipper = mix.expectedSkipRate()
        #expect(skipper > 0.7)
        for index in 0..<10 { mix.noteFinished(candidates[index * 3].song.songIdentity) }
        #expect(mix.expectedSkipRate() < skipper)
        // What this listen taught is kept for the next.
        let kept = mix.habits(at: now)?.listening
        #expect((kept?.landed ?? 0) > 0)
    }
}

@Suite("Live mix inputs")
struct LiveMixInputTests {
    @Test(
        "a small history plays more new finds, so first listens don't go round the same few songs",
        arguments: [
            (5, 0.08, true, 0.5),
            (30, 0.25, true, 0.35),
            (30, 0.5, true, 0.5),
            (200, 0.25, true, 0.25),
            (5, 0.25, false, 0.25),
        ]
    )
    func firstListens(yourSongs: Int, tuned: Double, hasNewFinds: Bool, expected: Double) {
        #expect(LiveMix.firstListens(tuned, yourSongs: yourSongs, hasNewFinds: hasNewFinds) == expected)
    }

    @Test("a skip is weighed against the plays around it")
    func skipsAgainstPlays() {
        #expect(RadioMomentFit.skipFactor(skips: 0, plays: 0) == 1)
        #expect(RadioMomentFit.skipFactor(skips: 1, plays: 12) > 0.85)
        #expect(RadioMomentFit.skipFactor(skips: 1, plays: 0) < 0.45)
        #expect(RadioMomentFit.skipFactor(skips: 6, plays: 0) == 0.35)
    }

    @Test("habits kept before the listener was learned still load, and what's learned now keeps and fades")
    func habitsCarryOver() throws {
        let older = #"{"bands":{"morning":{"genres":{"rock":{"landed":3,"missed":1}},"decades":{},"newFinds":{"landed":0,"missed":0}}}}"#
        var habits = RadioHabits(stored: older)
        #expect(habits.tally(genre: "rock", in: .morning).landed == 3)
        #expect(habits.listening == nil)

        habits.recordListen(landed: true)
        habits.recordListen(landed: false)
        let dated = habits.decayed(to: now)
        let reread = RadioHabits(stored: dated.stored)
        #expect(reread.listening == RadioHabits.Tally(landed: 1, missed: 1))
        let faded = try #require(reread.decayed(to: now.addingTimeInterval(RadioHabits.halfLife)).listening)
        #expect(abs(faded.landed - 0.5) < 0.001)
    }

    @Test("Autoplay prefers the song you play with the one it follows over another by the same artist")
    func autoplayFollowsSittings() {
        var plays: [CaptureStat] = []
        for daysAgo in 1...12 {
            plays += sitting([("Seed", "Sia"), ("Partner", "Quinn")], daysAgo: Double(daysAgo))
            plays += sitting([("Stranger", "Quinn"), ("Other", "Ola")], daysAgo: Double(daysAgo) + 0.4)
        }
        let history = ListeningHistory(plays)
        var partner = 0
        var stranger = 0
        for seed in 1...40 as ClosedRange<UInt64> {
            var mix = LiveMix.autoplay(after: [AutoplaySeed(songIdentity: identity("Seed", "Sia"), artistName: "Sia")], from: history, now: now, seed: seed)
            let first = mix.next()
            if first?.title == "Partner" { partner += 1 }
            if first?.title == "Stranger" { stranger += 1 }
        }
        #expect(partner > stranger * 2)
    }
}
