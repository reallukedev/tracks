import Testing
import Foundation
import SwiftData
@testable import TracksCore

/// Reading what Last.fm did with each scrobble. It answers 200 even when it ignored some.
@Suite("Last.fm scrobble response")
struct ScrobbleResponseTests {

    /// A two-scrobble batch as Last.fm sends it: an array, codes as strings, the second
    /// ignored for being too old.
    static let batchWithOneIgnored = #"""
    {"scrobbles":{"scrobble":[{"artist":{"corrected":"0","#text":"BANKS"},"album":{"corrected":"0","#text":"Off With Her Head"},"track":{"corrected":"0","#text":"Love Is Unkind"},"ignoredMessage":{"code":"0","#text":""},"albumArtist":{"corrected":"0","#text":""},"timestamp":"1700000000"},{"artist":{"corrected":"0","#text":"Mk.gee"},"album":{"corrected":"0","#text":""},"track":{"corrected":"0","#text":"You"},"ignoredMessage":{"code":"3","#text":"Timestamp too old"},"albumArtist":{"corrected":"0","#text":""},"timestamp":"1700000060"}],"@attr":{"ignored":1,"accepted":1}}}
    """#

    /// One scrobble comes back as a lone object, not an array of one.
    static let single = #"""
    {"scrobbles":{"scrobble":{"artist":{"corrected":"0","#text":"BANKS"},"album":{"corrected":"0","#text":""},"track":{"corrected":"0","#text":"Love Is Unkind"},"ignoredMessage":{"code":"0","#text":""},"albumArtist":{"corrected":"0","#text":""},"timestamp":"1700000000"},"@attr":{"ignored":0,"accepted":1}}}
    """#

    private func client(answering body: String) -> LastFMClient {
        LastFMClient(apiKey: "KEY", secret: "SECRET") { request in
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    private let session = LastFMSession(username: "example", sessionKey: "sk")
    private let played = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("each entry in a batch gets its own outcome, in the order sent")
    func readsABatch() async throws {
        let outcomes = try await client(answering: Self.batchWithOneIgnored).submit(
            [
                Scrobble(artist: "BANKS", track: "Love Is Unkind", playedAt: played),
                Scrobble(artist: "Mk.gee", track: "You", playedAt: played.addingTimeInterval(60)),
            ],
            session: session
        )
        #expect(outcomes == [.accepted, .ignored(code: 3, message: "Timestamp too old")])
    }

    @Test("a single scrobble's object is read like a batch of one")
    func readsASingleObject() async throws {
        let outcomes = try await client(answering: Self.single).submit(
            [Scrobble(artist: "BANKS", track: "Love Is Unkind", playedAt: played)],
            session: session
        )
        #expect(outcomes == [.accepted])
    }

    /// `scrobble` used to report everything it sent as accepted.
    @Test("the count only includes what was accepted")
    func countsAccepted() async throws {
        let accepted = try await client(answering: Self.batchWithOneIgnored).scrobble(
            [
                Scrobble(artist: "BANKS", track: "Love Is Unkind", playedAt: played),
                Scrobble(artist: "Mk.gee", track: "You", playedAt: played.addingTimeInterval(60)),
            ],
            session: session
        )
        #expect(accepted == 1)
    }

    @Test("codes sent as numbers are read too")
    func numericCodes() throws {
        let json = try #require(try JSONSerialization.jsonObject(with: Data(#"""
        {"scrobbles":{"scrobble":[{"ignoredMessage":{"code":0,"#text":""}},{"ignoredMessage":{"code":1,"#text":"Artist name failed filter"}}],"@attr":{"ignored":1,"accepted":1}}}
        """#.utf8)) as? [String: Any])
        let outcomes = try LastFMClient.scrobbleOutcomes(from: json, sent: 2)
        #expect(outcomes == [.accepted, .ignored(code: 1, message: "Artist name failed filter")])
    }

    @Test("entries that can't be lined up are fine when none were ignored")
    func unalignedButNothingIgnored() throws {
        let json: [String: Any] = ["scrobbles": ["@attr": ["ignored": "0", "accepted": "2"]]]
        #expect(try LastFMClient.scrobbleOutcomes(from: json, sent: 2) == [.accepted, .accepted])
    }

    /// Last.fm took the batch. Treating it as unreadable sent it again, scrobbling every
    /// accepted entry twice.
    @Test("entries that can't be lined up, with some ignored, still count as taken")
    func unalignedWithIgnored() throws {
        let json: [String: Any] = ["scrobbles": ["scrobble": [String: Any](), "@attr": ["ignored": 1, "accepted": 1]]]
        #expect(try LastFMClient.scrobbleOutcomes(from: json, sent: 2) == [.accepted, .accepted])
    }

    /// A 200 that doesn't mention the scrobbles used to mark them all sent.
    @Test("a response without a scrobbles report is unreadable")
    func missingReport() {
        #expect(throws: LastFMError.malformedResponse) {
            try LastFMClient.scrobbleOutcomes(from: [:], sent: 2)
        }
    }

    @Test("a 200 that isn't JSON is unreadable, not a success")
    func htmlBody() async {
        await #expect(throws: LastFMError.malformedResponse) {
            try await client(answering: "<html><body>Sign in to Wi-Fi</body></html>").submit(
                [Scrobble(artist: "BANKS", track: "Love Is Unkind", playedAt: played)],
                session: session
            )
        }
    }

    @Test("only the daily limit and a future timestamp are worth sending again")
    func retryableOutcomes() {
        #expect(ScrobbleOutcome.ignored(code: 5, message: "").isRetryable)
        #expect(ScrobbleOutcome.ignored(code: 4, message: "").isRetryable)
        #expect(!ScrobbleOutcome.ignored(code: 3, message: "").isRetryable)
        #expect(!ScrobbleOutcome.ignored(code: 1, message: "").isRetryable)
        #expect(!ScrobbleOutcome.accepted.isRetryable)
    }
}

/// The scrobble queue against a fake Last.fm: what a failure costs the rows, and that drains
/// don't overlap.
@MainActor
@Suite("Scrobble drain", .timeLimit(.minutes(1)))
struct ScrobbleDrainTests {
    let store: TracksStore
    let lastFM = FakeLastFM()
    private let scratch = ScratchDefaults()
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))

    init() throws {
        store = try TracksStore(inMemory: true)
    }

    func service() -> ScrobbleService {
        let lastFM = lastFM
        let service = ScrobbleService(
            store: store,
            settings: scratch.settings,
            makeClient: { lastFM.client() },
            currentSession: { LastFMSession(username: "example", sessionKey: "sk") }
        )
        let clock = clock
        service.now = { clock.now }
        return service
    }

    @discardableResult
    func owed(_ titles: String...) throws -> [Capture] {
        let rows = titles.enumerated().map { index, title in
            Capture(
                songID: title,
                title: title,
                artistName: "An Artist",
                capturedAt: base.addingTimeInterval(Double(index) * 60),
                deviceID: DeviceIdentity.current
            )
        }
        for row in rows { store.context.insert(row) }
        try store.context.save()
        return rows
    }

    /// Every one of these used to cost each of fifty rows an attempt, and three of them lost
    /// the rows for good.
    @Test(
        "a failure that isn't the scrobbles' fault leaves them untouched",
        arguments: [
            FakeLastFM.Failure.status(503, body: "{}"),
            .status(429, body: "{}"),
            .status(200, body: #"{"error":11,"message":"Service Offline"}"#),
            .status(200, body: #"{"error":16,"message":"There was a temporary error processing your request."}"#),
            .status(200, body: #"{"error":29,"message":"Rate Limit Exceeded"}"#),
            .status(403, body: #"{"error":9,"message":"Invalid session key - Please re-authenticate"}"#),
            // A captive portal, a proxy or an edge error page, none of which are Last.fm.
            .status(200, body: "<html>Sign in to Wi-Fi</html>"),
            .status(200, body: "{}"),
            .status(403, body: "<html>Forbidden</html>"),
            .status(404, body: ""),
            .offline,
        ]
    )
    func transientFailuresCostNothing(failure: FakeLastFM.Failure) async throws {
        let rows = try owed("One", "Two")
        lastFM.fail(with: failure)
        let service = service()

        #expect(await service.drain() == 0)

        for row in rows {
            #expect(row.scrobbledAt == nil)
            #expect(row.scrobbleAttempts == 0)
            #expect(row.lastScrobbleError == nil)
        }
        #expect(service.lastError != nil)
        #expect(try store.context.fetch(TracksStore.pendingScrobbles(includingImported: true)).count == 2)
    }

    @Test("a request Last.fm rejects outright charges the rows an attempt")
    func permanentFailureCharges() async throws {
        let rows = try owed("One", "Two")
        lastFM.fail(with: .status(400, body: #"{"error":6,"message":"Invalid parameters"}"#))

        await service().drain()

        #expect(rows.map(\.scrobbleAttempts) == [1, 1])
        // In Tracks' words, without Last.fm's code and message.
        #expect(rows.allSatisfy { $0.lastScrobbleError == "Something went wrong with Last.fm. Try again." })
    }

    /// A server that's down shouldn't get a request from every ten-second poll.
    @Test("after a transient failure the queue waits before asking again")
    func backsOff() async throws {
        let rows = try owed("One")
        lastFM.fail(with: .status(503, body: "{}"))
        let service = service()

        await service.drain()
        await service.drain()
        #expect(lastFM.requests.count == 1)

        // Each failure in a row doubles the wait: 30, then 60, then 120 seconds.
        for (failure, wait) in [(2, 30.0), (3, 60.0)] {
            clock.advance(by: wait - 0.5)
            await service.drain()
            #expect(lastFM.requests.count == failure - 1)
            clock.advance(by: 0.5)
            await service.drain()
            #expect(lastFM.requests.count == failure)
        }
        clock.advance(by: 119.5)
        await service.drain()
        #expect(lastFM.requests.count == 3)

        lastFM.acceptEverything()
        clock.advance(by: 0.5)
        #expect(await service.drain() == 1)
        #expect(rows[0].scrobbledAt != nil)
        #expect(service.lastError == nil)

        // A success clears the wait, so the next failure waits 30 seconds again.
        try owed("Two")
        lastFM.fail(with: .status(503, body: "{}"))
        await service.drain()
        #expect(lastFM.requests.count == 5)
        clock.advance(by: 30)
        await service.drain()
        #expect(lastFM.requests.count == 6)
    }

    /// Too old (3) is about the scrobble and will never pass. It used to be marked scrobbled.
    @Test("an ignored scrobble is given up on with the reason, and the rest are marked sent")
    func ignoredEntries() async throws {
        let rows = try owed("One", "Two", "Three")
        lastFM.answer { count in FakeLastFM.outcomes([0, 3, 0].prefix(count).map { $0 }) }

        #expect(await service().drain() == 2)

        #expect(rows[0].scrobbledAt != nil)
        #expect(rows[2].scrobbledAt != nil)
        #expect(rows[1].scrobbledAt == nil)
        #expect(rows[1].scrobbleAttempts >= TracksStore.maxScrobbleAttempts)
        #expect(rows[1].lastScrobbleError?.contains("Too old") == true)
        #expect(try store.context.fetch(TracksStore.pendingScrobbles(includingImported: true)).isEmpty)
    }

    @Test("a scrobble held back by the daily limit stays owed without an attempt")
    func dailyLimit() async throws {
        let rows = try owed("One", "Two")
        lastFM.answer { _ in FakeLastFM.outcomes([0, 5]) }
        let service = service()

        await service.drain()

        #expect(rows[0].scrobbledAt != nil)
        #expect(rows[1].scrobbledAt == nil)
        #expect(rows[1].scrobbleAttempts == 0)
        #expect(service.lastError?.contains("daily") == true)
        // And it waits rather than asking again straight away.
        await service.drain()
        #expect(lastFM.requests.count == 1)
    }

    /// Launch, the capture pump and the housekeeping timer all drain, and used to overlap
    /// while the first was waiting on Last.fm, sending everything twice.
    @Test("overlapping drains send each scrobble once")
    func drainsDontOverlap() async throws {
        let rows = try owed("One", "Two")
        lastFM.acceptEverything()
        lastFM.delay = .milliseconds(50)
        let service = service()

        async let first = service.drain()
        async let second = service.drain()
        async let third = service.drain()
        _ = await (first, second, third)

        let sentTitles = lastFM.requests.flatMap { fields in
            fields.filter { $0.key.hasPrefix("track[") }.map(\.value)
        }
        #expect(sentTitles.sorted() == ["One", "Two"])
        #expect(rows.allSatisfy { $0.scrobbledAt != nil })
    }

    @Test("a row added while a drain is out is sent by the drain that was joined")
    func joinedDrainPicksUpNewRows() async throws {
        try owed("One")
        lastFM.acceptEverything()
        let gate = Gate()
        lastFM.gate = gate
        let service = service()

        let first = Task { await service.drain() }
        try await waitUntil { lastFM.requests.count == 1 }
        let late = Capture(
            songID: "Late", title: "Late", artistName: "An Artist",
            capturedAt: base.addingTimeInterval(600), deviceID: DeviceIdentity.current
        )
        store.context.insert(late)
        try store.context.save()

        async let joined = service.drain()
        gate.open()
        _ = await (first.value, joined)

        #expect(late.scrobbledAt != nil)
    }

    /// Apple's recently-played list covers the whole account, so the iPhone imported songs
    /// the Mac had already scrobbled and sent them again.
    @Test("an import Last.fm already has from another device is not sent again")
    func importAlreadyScrobbled() async throws {
        let found = base.addingTimeInterval(3 * 60 * 60)
        let imported = Capture(
            songID: "1", title: "Love Is Unkind", artistName: "BANKS",
            kind: .imported, capturedAt: found, deviceID: DeviceIdentity.current
        )
        let fresh = Capture(
            songID: "2", title: "You", artistName: "Mk.gee",
            kind: .imported, capturedAt: found, deviceID: DeviceIdentity.current
        )
        store.context.insert(imported)
        store.context.insert(fresh)
        try store.context.save()
        lastFM.history = [(title: "Love Is Unkind", artist: "BANKS", playedAt: base)]
        lastFM.acceptEverything()

        #expect(await service().drain() == 1)

        let sentTitles = lastFM.scrobbleRequests.flatMap { fields in
            fields.filter { $0.key.hasPrefix("track[") }.map(\.value)
        }
        #expect(sentTitles == ["You"])
        #expect(imported.scrobbledAt != nil)
        #expect(fresh.scrobbledAt != nil)
    }

    @Test("an import is held when Last.fm's history can't be read")
    func importWaitsForHistory() async throws {
        let imported = Capture(
            songID: "1", title: "Love Is Unkind", artistName: "BANKS",
            kind: .imported, capturedAt: base, deviceID: DeviceIdentity.current
        )
        store.context.insert(imported)
        try store.context.save()
        lastFM.fail(with: .offline)

        await service().drain()

        #expect(lastFM.scrobbleRequests.isEmpty)
        #expect(imported.scrobbledAt == nil)
        #expect(imported.scrobbleAttempts == 0)
    }

    @Test("a scrobble only accounts for one import of the same song")
    func oneScrobbleOneImport() throws {
        let store = try TracksStore(inMemory: true)
        let rows = (0..<2).map { _ in
            Capture(songID: "1", title: "You", artistName: "Mk.gee", kind: .imported, capturedAt: base)
        }
        for row in rows { store.context.insert(row) }
        try store.context.save()
        let plays = rows.map {
            ScrobbleService.ImportedPlay(
                id: $0.persistentModelID,
                key: HistoryImport.key(title: $0.title, artistName: $0.artistName),
                foundAt: base
            )
        }
        let history = [ScrobbledTrack(title: "you", artistName: "MK.GEE", playedAt: base.addingTimeInterval(-60))]

        let found = ScrobbleService.alreadyScrobbled(plays, history: history, window: 24 * 60 * 60)
        #expect(found.count == 1)
        // Outside the window, or after the import found it, is a different play.
        #expect(ScrobbleService.alreadyScrobbled(plays, history: history, window: 30).isEmpty)
        let later = [ScrobbledTrack(title: "You", artistName: "Mk.gee", playedAt: base.addingTimeInterval(60))]
        #expect(ScrobbleService.alreadyScrobbled(plays, history: later, window: 24 * 60 * 60).isEmpty)
    }

    /// Sync can merge a row away while its scrobble is out. Writing to the deleted row trapped.
    @Test("a row deleted while its scrobble is out is skipped")
    func deletedWhileOut() async throws {
        let rows = try owed("Kept", "Merged")
        lastFM.acceptEverything()
        let gate = Gate()
        lastFM.gate = gate
        let service = service()

        let drain = Task { await service.drain() }
        try await waitUntil { lastFM.requests.count == 1 }
        store.context.delete(rows[1])
        try store.context.save()
        gate.open()
        _ = await drain.value

        #expect(rows[0].scrobbledAt != nil)
        #expect(try store.context.fetch(FetchDescriptor<Capture>()).count == 1)
    }
}

// MARK: - Fakes

/// A scriptable Last.fm, answering from the form it was sent.
final class FakeLastFM: @unchecked Sendable {
    enum Failure: Sendable, CustomTestStringConvertible {
        case status(Int, body: String)
        case offline

        var testDescription: String {
            switch self {
            case .status(let status, let body): "HTTP \(status) \(body)"
            case .offline: "offline"
            }
        }
    }

    private let lock = NSLock()
    private var _requests: [[String: String]] = []
    private var respond: @Sendable (Int) throws -> (Int, String) = { _ in (200, "{}") }
    private var _gate: Gate?
    private var _delay: Duration?
    private var _history: [(title: String, artist: String, playedAt: Date)] = []

    /// What `user.getRecentTracks` lists, newest first.
    var history: [(title: String, artist: String, playedAt: Date)] {
        get { lock.withLock { _history } }
        set { lock.withLock { _history = newValue } }
    }

    /// The `track.scrobble` requests, leaving out history lookups.
    var scrobbleRequests: [[String: String]] {
        requests.filter { $0["method"] == "track.scrobble" }
    }

    /// The decoded form of every request, in order.
    var requests: [[String: String]] { lock.withLock { _requests } }
    /// Holds each request until opened.
    var gate: Gate? {
        get { lock.withLock { _gate } }
        set { lock.withLock { _gate = newValue } }
    }
    var delay: Duration? {
        get { lock.withLock { _delay } }
        set { lock.withLock { _delay = newValue } }
    }

    /// Answers with a body built from how many scrobbles were sent.
    func answer(_ body: @escaping @Sendable (Int) -> String) {
        lock.withLock { respond = { count in (200, body(count)) } }
    }

    func acceptEverything() {
        answer { count in Self.outcomes(Array(repeating: 0, count: count)) }
    }

    func fail(with failure: Failure) {
        lock.withLock {
            respond = { _ in
                switch failure {
                case .status(let status, let body): return (status, body)
                case .offline: throw URLError(.notConnectedToInternet)
                }
            }
        }
    }

    func client() -> LastFMClient {
        LastFMClient(apiKey: "KEY", secret: "SECRET") { [self] request in
            let fields = Self.decode(request.httpBody ?? Data())
            let (respond, gate, delay) = lock.withLock {
                _requests.append(fields)
                return (self.respond, _gate, _delay)
            }
            if let delay { try? await Task.sleep(for: delay) }
            await gate?.wait()
            if fields["method"] == "user.getRecentTracks" {
                // Fails the way a scrobble would, otherwise lists the history.
                let (status, body) = try respond(0)
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (Data((status == 200 ? Self.recentTracks(history) : body).utf8), response)
            }
            let count = fields.keys.filter { $0.hasPrefix("timestamp[") }.count
            let (status, body) = try respond(count)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    /// A `track.scrobble` response in Last.fm's shape, one entry per code (0 is accepted):
    /// an array for several, a lone object for one.
    static func outcomes(_ codes: [Int]) -> String {
        let entries = codes.map { code in
            ##"{"artist":{"corrected":"0","#text":"An Artist"},"album":{"corrected":"0","#text":""},"track":{"corrected":"0","#text":"T"},"ignoredMessage":{"code":"\##(code)","#text":""},"albumArtist":{"corrected":"0","#text":""},"timestamp":"1700000000"}"##
        }
        let scrobble = entries.count == 1 ? entries[0] : "[\(entries.joined(separator: ","))]"
        let ignored = codes.filter { $0 != 0 }.count
        return ##"{"scrobbles":{"scrobble":\##(scrobble),"@attr":{"ignored":\##(ignored),"accepted":\##(codes.count - ignored)}}}"##
    }

    static func recentTracks(_ tracks: [(title: String, artist: String, playedAt: Date)]) -> String {
        let entries = tracks.map { track in
            ##"{"name":"\##(track.title)","artist":{"#text":"\##(track.artist)"},"date":{"uts":"\##(Int(track.playedAt.timeIntervalSince1970))"}}"##
        }
        return ##"{"recenttracks":{"track":[\##(entries.joined(separator: ","))],"@attr":{"total":"\##(tracks.count)","totalPages":"1"}}}"##
    }

    private static func decode(_ body: Data) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let value = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? "") : ""
            fields[name] = value
        }
        return fields
    }
}

/// Holds whatever waits on it until opened, or until its task is cancelled, so a test that
/// times out or fails never leaves a request parked behind it.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false

    func open() { lock.withLock { isOpen = true } }

    func wait() async {
        while !Task.isCancelled, !lock.withLock({ isOpen }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// A clock a test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

/// Polls rather than sleeping a fixed time, which a slow Simulator outlasts. It has no
/// deadline of its own, since a wall clock runs out on a busy machine while the work is still
/// on its way; the calling suite's `.timeLimit` bounds it instead, and cancelling the test
/// ends the wait.
@MainActor
func waitUntil(_ condition: () -> Bool) async throws {
    while !condition() {
        try await Task.sleep(for: .milliseconds(5))
    }
}
