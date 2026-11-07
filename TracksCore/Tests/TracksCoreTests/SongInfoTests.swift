import Testing
import Foundation
@testable import TracksCore

/// A recording as MusicBrainz returns it with relationships, trimmed from a real response.
private let recordingJSON = #"""
{"id":"rec-1","title":"Gold Digger","first-release-date":"2005-08-26",
 "genres":[{"name":"pop rap","count":1},{"name":"hip hop","count":4},{"name":"soul","count":1}],"relations":[
 {"type":"engineer","direction":"backward","target-type":"artist","attributes":["assistant"],"artist":{"name":"Nate Connelly"}},
 {"type":"instrument","direction":"backward","target-type":"artist","attributes":["turntable"],"artist":{"name":"A-Trak"}},
 {"type":"mix","direction":"backward","target-type":"artist","attributes":[],"artist":{"name":"Mike Dean"}},
 {"type":"performer","direction":"backward","target-type":"artist","attributes":["guest"],"artist":{"name":"Jamie Foxx"}},
 {"type":"producer","direction":"backward","target-type":"artist","attributes":[],"artist":{"name":"Jon Brion"}},
 {"type":"producer","direction":"backward","target-type":"artist","attributes":[],"artist":{"name":"Ye"}},
 {"type":"recording","direction":"backward","target-type":"artist","attributes":[],"artist":{"name":"Mike Dean"}},
 {"type":"remix","direction":"backward","target-type":"recording","attributes":[],"recording":{"id":"rec-remix","title":"Gold Digger (remix)","artist-credit":[{"name":"Kraddy","joinphrase":""}]}},
 {"type":"mashes up","direction":"backward","target-type":"recording","attributes":[],"recording":{"id":"rec-mash","title":"Dafter Stronger Gold Digger","artist-credit":[{"name":"Ye","joinphrase":""}]}},
 {"type":"samples material","direction":"backward","target-type":"recording","attributes":[],"recording":{"id":"rec-casanova","title":"Casanova","artist-credit":[{"name":"Flamingosis","joinphrase":""}]}},
 {"type":"samples material","direction":"forward","target-type":"recording","attributes":[],"recording":{"id":"rec-woman","title":"I’ve Got a Woman","first-release-date":"1954-12-01","artist-credit":[{"name":"Ray Charles","joinphrase":" & "},{"name":"His Orchestra","joinphrase":""}]}},
 {"type":"performance","direction":"forward","target-type":"work","attributes":[],"work":{"id":"work-1","title":"Gold Digger","relations":[
   {"type":"writer","direction":"backward","target-type":"artist","artist":{"name":"Ray Charles"}},
   {"type":"writer","direction":"backward","target-type":"artist","artist":{"name":"Ye"}},
   {"type":"medley","direction":"backward","target-type":"work","work":{"title":"Polkarama!"}}
 ]}}
]}
"""#

private func json(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
}

/// Answers each request by its path, recording every one it was asked.
private final class FakeMusicBrainz: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: [(Int, String)]]
    private(set) var paths: [String] = []

    init(_ answers: [String: [(Int, String)]]) {
        self.answers = answers
    }

    var client: MusicBrainzClient {
        MusicBrainzClient(userAgent: "TracksTests/1.0", gate: MusicBrainzGate(spacing: .zero), retryDelay: .zero) { request in
            try self.answer(request)
        }
    }

    private func answer(_ request: URLRequest) throws -> (Data, URLResponse) {
        lock.lock()
        defer { lock.unlock() }
        let path = request.url!.path()
        paths.append(path)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "TracksTests/1.0")
        let key = answers.keys.first { path.hasSuffix($0) } ?? ""
        let (status, body) = answers[key]?.isEmpty == false ? answers[key]!.removeFirst() : (404, "{}")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

@Suite("MusicBrainz credits")
struct MusicBrainzCreditsTests {
    @Test("people are grouped as Apple Music groups credits, each once with all their roles")
    func groupsCredits() throws {
        let credits = try #require(MusicBrainzClient.credits(from: json(recordingJSON)))

        #expect(credits.sections.map(\.kind) == [.performers, .composition, .production])
        let performers = credits.sections[0].credits
        #expect(performers.map(\.name) == ["A-Trak", "Jamie Foxx"])
        #expect(performers[0].roles == [CreditRole(.instrument, detail: "turntable")])
        #expect(performers[1].roles == [CreditRole(.featured)])

        // Writers come from the work the recording performs, not the recording itself.
        #expect(credits.sections[1].credits.map(\.name) == ["Ray Charles", "Ye"])

        let production = credits.sections[2].credits
        #expect(production.map(\.name) == ["Nate Connelly", "Mike Dean", "Jon Brion", "Ye"])
        #expect(production[1].roles == [CreditRole(.mixing), CreditRole(.recording)])
        #expect(production[0].roles == [CreditRole(.engineer, detail: "assistant")])

        // What a radio song may come without: most agreed genre first, the year, the work.
        #expect(credits.genres == ["hip hop", "pop rap", "soul"])
        #expect(credits.firstReleaseYear == 2005)
        #expect(credits.workIDs == ["work-1"])
    }

    /// MusicBrainz's "samples material" points from the song that samples to the one sampled.
    @Test("samples and sampled-by follow the relationship's direction; mashups and remixes are kept apart")
    func samplesByDirection() throws {
        let credits = try #require(MusicBrainzClient.credits(from: json(recordingJSON)))

        #expect(credits.samples == [RecordingLink(title: "I’ve Got a Woman", artistName: "Ray Charles & His Orchestra", year: 1954, recordingID: "rec-woman")])
        #expect(credits.sampledBy.map(\.title) == ["Casanova"])
        #expect(credits.sampledBy.first?.year == nil)
        #expect(credits.mashups.map(\.recordingID) == ["rec-mash"])
        #expect(credits.remixes.map(\.artistName) == ["Kraddy"])
    }

    @Test("a recording with no relationships has nothing to show")
    func emptyRecording() throws {
        let credits = try #require(MusicBrainzClient.credits(from: json(#"{"id":"rec-2","title":"Quiet"}"#)))
        #expect(credits.isEmpty)
    }

    /// MusicBrainz often has one ISRC on a bare duplicate first and the credited recording later.
    @Test("an ISRC's recordings are read together, up to a few, so credits on any of them count")
    func looksUpByISRC() async throws {
        let fake = FakeMusicBrainz([
            "isrc/USUM70502983": [(200, #"{"recordings":[{"id":"rec-0"},{"id":"rec-1"},{"id":"rec-2"},{"id":"rec-3"}]}"#)],
            "recording/rec-0": [(200, #"{"id":"rec-0","title":"Gold Digger","first-release-date":"2005-08-30"}"#)],
            "recording/rec-1": [(200, recordingJSON)],
            "recording/rec-2": [(404, "{}")],
        ])
        let credits = try await fake.client.credits(isrc: "usum70502983", title: "Gold Digger", artistName: "Kanye West", duration: 208)

        #expect(credits?.recordingID == "rec-0")
        #expect(credits?.samples.count == 1)
        #expect(credits?.sections.count == 3)
        #expect(credits?.firstReleaseYear == 2005)
        #expect(fake.paths.map { $0.components(separatedBy: "/ws/2/").last ?? "" } == [
            "isrc/USUM70502983", "recording/rec-0", "recording/rec-1", "recording/rec-2",
        ])
    }

    @Test("an ISRC MusicBrainz doesn't know is no credits, not an error")
    func unknownISRC() async throws {
        let fake = FakeMusicBrainz([:])
        let credits = try await fake.client.credits(isrc: "XX0000000000", title: "Song", artistName: "Artist", duration: nil)
        #expect(credits == nil)
        #expect(fake.paths.count == 1)
    }

    @Test("a busy answer is tried once more, then given up on")
    func retriesBusyOnce() async throws {
        let recovers = FakeMusicBrainz([
            "isrc/AA1": [(503, "{}"), (200, #"{"recordings":[{"id":"rec-1"}]}"#)],
            "recording/rec-1": [(200, recordingJSON)],
        ])
        #expect(try await recovers.client.credits(isrc: "AA1", title: "", artistName: "", duration: nil) != nil)

        let stays = FakeMusicBrainz(["isrc/AA1": [(503, "{}"), (503, "{}"), (200, "{}")]])
        await #expect(throws: MusicBrainzError.busy) {
            try await stays.client.credits(isrc: "AA1", title: "", artistName: "", duration: nil)
        }
        #expect(stays.paths.count == 2)
    }

    @Test(
        "without an ISRC, only an exact title, artist and length match counts",
        arguments: [
            ("Gold Digger", "Kanye West", 208.0, "rec-match"),
            ("gold digger", "KANYE WEST", nil, "rec-match"),
            ("Gold Digger", "Kanye West", 150.0, nil),
            ("Gold Digger (Live)", "Kanye West", 208.0, nil),
            ("Gold Digger", "Kanye", 208.0, nil),
        ] as [(String, String, Double?, String?)]
    )
    func exactMatchOnly(title: String, artist: String, duration: Double?, expected: String?) {
        let results = [
            json(#"{"id":"rec-live","title":"Gold Digger (live)","length":250000,"artist-credit":[{"name":"Kanye West","joinphrase":""}]}"#),
            json(#"{"id":"rec-match","title":"Gold Digger","length":208000,"artist-credit":[{"name":"Kanye West","joinphrase":""}]}"#),
        ]
        #expect(MusicBrainzClient.exactMatch(in: results, title: title, artistName: artist, duration: duration) == expected)
    }

    @Test("requests through one gate are spaced, however many arrive together")
    func gateSpacesRequests() async throws {
        let gate = MusicBrainzGate(spacing: .milliseconds(80))
        let start = ContinuousClock.now
        try await withThrowingTaskGroup { group in
            for _ in 0..<3 { group.addTask { try await gate.turn() } }
            try await group.waitForAll()
        }
        #expect(ContinuousClock.now - start >= .milliseconds(155))
    }
}

@Suite("MusicBrainz versions and covers")
struct MusicBrainzVersionsTests {
    /// A work's performances, trimmed from a real response, with the edits and DJ mixes that
    /// are the same take sold another way.
    private let work = json(#"""
    {"id":"work-1","attributes":[{"type":"Key","value":"E♭ minor"},{"type":"SUISA ID","value":"003604"}],"relations":[
     {"type":"performance","target-type":"recording","attributes":[],"recording":{"id":"rec-1","title":"Gold Digger","disambiguation":"","artist-credit":[{"name":"Kanye West","joinphrase":" feat. "},{"name":"Jamie Foxx","joinphrase":""}]}},
     {"type":"performance","target-type":"recording","attributes":[],"recording":{"id":"rec-dup","title":"Gold Digger","disambiguation":"","artist-credit":[{"name":"Kanye West","joinphrase":""}]}},
     {"type":"performance","target-type":"recording","attributes":[],"recording":{"id":"rec-clean","title":"Gold Digger","disambiguation":"clean","artist-credit":[{"name":"Kanye West","joinphrase":""}]}},
     {"type":"performance","target-type":"recording","attributes":[],"recording":{"id":"rec-mix","title":"Gold Digger","disambiguation":"part of “Westwood Volume X” DJ‐mix","artist-credit":[{"name":"Kanye West","joinphrase":""}]}},
     {"type":"performance","target-type":"recording","attributes":["live"],"recording":{"id":"rec-live","title":"Gold Digger (AOL Sessions)","disambiguation":"live, 2005-09-21: Abbey Road Studios","artist-credit":[{"name":"Kanye West","joinphrase":""}]}},
     {"type":"performance","target-type":"recording","attributes":["instrumental"],"recording":{"id":"rec-inst","title":"Gold Digger (instrumental)","artist-credit":[{"name":"Kanye West","joinphrase":""}]}},
     {"type":"performance","target-type":"recording","attributes":["cover","live"],"recording":{"id":"cov-live","title":"Gold Digger","disambiguation":"live, Radio 1’s Live Lounge","artist-credit":[{"name":"The Automatic","joinphrase":""}]}},
     {"type":"performance","target-type":"recording","attributes":["cover"],"recording":{"id":"cov-studio","title":"Gold Digger","artist-credit":[{"name":"The Automatic","joinphrase":""}]}},
     {"type":"performance","target-type":"recording","attributes":["cover","instrumental"],"recording":{"id":"cov-vsq","title":"Gold Digger","artist-credit":[{"name":"Vitamin String Quartet","joinphrase":""}]}},
     {"type":"performance","target-type":"recording","attributes":["cover"],"recording":{"id":"cov-karaoke","title":"Gold Digger (karaoke version)","artist-credit":[{"name":"Glee Cast","joinphrase":""}]}},
     {"type":"medley","target-type":"work","work":{"title":"Polkarama!"}}
    ]}
    """#)

    @Test("the artist's own takes are versions, other artists' are covers, and the same take sold again is neither")
    func sortsVersionsAndCovers() {
        let found = MusicBrainzClient.versions(from: work, title: "Gold Digger", artistName: "Kanye West", excluding: ["rec-1"])

        #expect(found.versions.map(\.recordingID) == ["rec-live", "rec-inst"])
        #expect(found.versions.map(\.detail) == ["Live, 2005-09-21: Abbey Road Studios", "Instrumental"])
        // One row per covering artist, the studio take over the live one.
        #expect(found.covers.map(\.recordingID) == ["cov-studio", "cov-vsq"])
        #expect(found.key == "E♭ minor")
    }

    @Test(
        "words match whole, so a song's own name isn't mistaken for an edit or another artist",
        arguments: [
            ("Meditation (live)", "edit", false),
            ("radio edit", "edit", true),
            ("part of “Westwood” DJ‐mix", "dj mix", true),
            ("Kanye West feat. Jamie Foxx", "Kanye West", true),
            ("Kanye West", "Ye", false),
            ("AC/DC", "ac dc", true),
        ]
    )
    func wholeWords(text: String, phrase: String, matches: Bool) {
        #expect(MusicBrainzClient.mentions(text, [phrase]) == matches)
    }

    @Test("a work with nothing but the song itself has nothing to show")
    func nothingElse() {
        let lone = json(#"{"id":"work-2","relations":[{"type":"performance","target-type":"recording","attributes":[],"recording":{"id":"rec-1","title":"Quiet","artist-credit":[{"name":"Someone","joinphrase":""}]}}]}"#)
        #expect(MusicBrainzClient.versions(from: lone, title: "Quiet", artistName: "Someone", excluding: ["rec-1"]).isEmpty)
    }
}

@Suite("Last.fm track info")
struct LastFMTrackInfoTests {
    private func client(answering body: String) -> LastFMClient {
        LastFMClient(apiKey: "KEY", secret: "SECRET") { request in
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test("counts arrive as strings, the summary loses its link, and the tags lose the noise")
    func readsTrackInfo() async throws {
        let body = #"""
        {"track":{"name":"Gold Digger","url":"https://www.last.fm/music/Kanye+West/_/Gold+Digger","listeners":"1963166","playcount":"17988257","userplaycount":"42",
         "toptags":{"tag":[{"name":"Hip-Hop"},{"name":"rap"},{"name":"Kanye West"},{"name":"hip hop"},{"name":"pop"},{"name":"2005"},{"name":"party"},{"name":"soul"}]},
         "wiki":{"summary":"\"Gold Digger\" is a song by Kanye West &amp; Jamie Foxx. <a href=\"http://www.last.fm/music/Kanye+West/_/Gold+Digger\">Read more on Last.fm</a>."}}}
        """#
        let info = try #require(try await client(answering: body).trackInfo(title: "Gold Digger", artistName: "Kanye West", username: "example"))

        #expect(info.listeners == 1_963_166)
        #expect(info.scrobbles == 17_988_257)
        #expect(info.yourScrobbles == 42)
        #expect(info.tags == ["Hip-Hop", "Rap", "Pop", "2005", "Party"])
        #expect(info.summary == "\"Gold Digger\" is a song by Kanye West & Jamie Foxx.")
        #expect(info.url?.host() == "www.last.fm")
    }

    @Test("a song Last.fm doesn't know is nil, not an error")
    func unknownTrack() async throws {
        let client = client(answering: #"{"error":6,"message":"Track not found"}"#)
        #expect(try await client.trackInfo(title: "Nothing", artistName: "Nobody", username: nil) == nil)
        #expect(try await client.similarTracks(title: "Nothing", artistName: "Nobody").isEmpty)
    }

    @Test("a summary that's only the link is no summary")
    func emptySummary() {
        #expect(LastFMClient.plainSummary(#" <a href="https://www.last.fm/x">Read more on Last.fm</a>"#) == nil)
    }

    @Test("similar songs read a lone entry as well as a list, each once")
    func readsSimilar() {
        let one = json(#"{"similartracks":{"track":{"name":"Touch the Sky","artist":{"name":"Kanye West"}}}}"#)
        #expect(LastFMClient.similarTracks(from: one) == [.init(title: "Touch the Sky", artistName: "Kanye West")])

        let many = json(#"{"similartracks":{"track":[{"name":"Touch the Sky","artist":{"name":"Kanye West"}},{"name":"touch the sky","artist":{"name":"kanye west"}},{"name":"","artist":{"name":"X"}}]}}"#)
        #expect(LastFMClient.similarTracks(from: many).count == 1)
    }
}

@Suite("Song info cache")
struct SongInfoCacheTests {
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    @Test("an answer is kept for its lifetime, and not knowing for the shorter one")
    func keepsForLifetime() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SongInfoCache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let cache = SongInfoCache(directory: directory) { clock.now }
        let lifetime = SongInfoCache.Lifetime(found: 100, missing: 10)

        await cache.store(LastFMTrackInfo(listeners: 5), for: "found")
        await cache.store(LastFMTrackInfo?.none, for: "missing")
        guard case .miss = await cache.value(LastFMTrackInfo.self, for: "never", lifetime: lifetime) else {
            Issue.record("A key never stored should miss")
            return
        }

        clock.now += 50
        guard case .hit(let found) = await cache.value(LastFMTrackInfo.self, for: "found", lifetime: lifetime),
              case .miss = await cache.value(LastFMTrackInfo.self, for: "missing", lifetime: lifetime)
        else {
            Issue.record("Halfway through, the answer should be kept and not knowing forgotten")
            return
        }
        #expect(found?.listeners == 5)

        clock.now += 60
        guard case .miss = await cache.value(LastFMTrackInfo.self, for: "found", lifetime: lifetime) else {
            Issue.record("Past its lifetime, the answer should be asked for again")
            return
        }
    }
}

@Suite("Song day parts")
struct SongDayPartsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func at(hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: hour))!
    }

    @Test("too few plays make no pattern")
    func needsEnoughPlays() {
        #expect(SongDayParts.split([5, 6, 7].map(at(hour:)), calendar: calendar) == nil)
    }

    @Test("plays fall into their part of the day, night wrapping past midnight")
    func splitsAtBoundaries() throws {
        let plays = [4, 5, 11, 12, 21, 22, 23, 0].map(at(hour:))
        let split = try #require(SongDayParts.split(plays, calendar: calendar))
        #expect(split == [
            DayPartPlays(part: .morning, plays: 2),
            DayPartPlays(part: .afternoon, plays: 1),
            DayPartPlays(part: .evening, plays: 1),
            DayPartPlays(part: .night, plays: 4),
        ])
    }
}
