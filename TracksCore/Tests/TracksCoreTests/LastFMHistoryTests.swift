import Testing
import Foundation
import SwiftData
@testable import TracksCore

private let start = Date(timeIntervalSince1970: 1_700_000_000)

/// A time `minutes` after ``start``.
private func at(_ minutes: Double) -> Date {
    start.addingTimeInterval(minutes * 60)
}

private func scrobble(_ title: String, _ minutes: Double, artist: String = "An Artist") -> ScrobbledTrack {
    ScrobbledTrack(title: title, artistName: artist, playedAt: at(minutes))
}

private func known(_ title: String, _ minutes: Double, _ kind: CaptureKind) -> LastFMHistory.KnownPlay {
    LastFMHistory.KnownPlay(
        key: HistoryImport.key(title: title, artistName: "An Artist"),
        playedAt: at(minutes),
        kind: kind
    )
}

/// The parameters of a form-encoded Last.fm request.
private func parameters(of request: URLRequest) -> [String: String] {
    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    var components = URLComponents()
    components.percentEncodedQuery = body
    return Dictionary(
        (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
        uniquingKeysWith: { _, last in last }
    )
}

private func client(answering body: String, capturing recorder: (@Sendable (URLRequest) -> Void)? = nil) -> LastFMClient {
    LastFMClient(apiKey: "KEY", secret: "SECRET") { request in
        recorder?(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

private let session = LastFMSession(username: "listener", sessionKey: "sk-1")

@Suite("Reading Last.fm history")
struct LastFMHistoryParsingTests {

    @Test("a page reads names, album, cover and time, and says how many there are")
    func readsAPage() throws {
        let json = try #require(try JSONSerialization.jsonObject(with: Data(#"""
        {"recenttracks": {
            "track": [
                {"artist": {"#text": "Sevens"}, "name": "Café", "album": {"#text": "Late"},
                 "image": [{"size": "small", "#text": "https://lastfm.example/34s/a.jpg"},
                           {"size": "extralarge", "#text": "https://lastfm.example/300x300/a.jpg"}],
                 "date": {"uts": "1700000600", "#text": "14 Nov 2023"}},
                {"artist": {"#text": "Sevens"}, "name": "Early", "album": {"#text": ""},
                 "date": {"uts": "1700000000"}}
            ],
            "@attr": {"user": "listener", "page": "1", "perPage": "200", "totalPages": "3", "total": "412"}
        }}
        """#.utf8)) as? [String: Any])

        let page = try LastFMClient.historyPage(from: json)

        #expect(page.total == 412)
        #expect(page.totalPages == 3)
        #expect(page.scrobbles == [
            ScrobbledTrack(
                title: "Café", artistName: "Sevens", albumTitle: "Late",
                artworkURL: "https://lastfm.example/300x300/a.jpg",
                playedAt: Date(timeIntervalSince1970: 1_700_000_600)
            ),
            ScrobbledTrack(title: "Early", artistName: "Sevens", playedAt: Date(timeIntervalSince1970: 1_700_000_000)),
        ])
    }

    /// The song playing now has no date and isn't a scrobble yet.
    @Test("the song playing now is left out")
    func skipsNowPlaying() throws {
        let json: [String: Any] = ["recenttracks": ["track": [
            ["artist": ["#text": "A"], "name": "Now", "@attr": ["nowplaying": "true"]],
            ["artist": ["#text": "A"], "name": "Then", "date": ["uts": "1700000000"]],
        ]]]
        #expect(try LastFMClient.historyPage(from: json).scrobbles.map(\.title) == ["Then"])
    }

    @Test("a single scrobble arrives as an object, not an array")
    func readsALoneTrack() throws {
        let json: [String: Any] = ["recenttracks": [
            "track": ["artist": ["#text": "A"], "name": "Only", "date": ["uts": 1_700_000_000]],
            "@attr": ["total": "1", "totalPages": "1"],
        ]]
        #expect(try LastFMClient.historyPage(from: json).scrobbles.map(\.title) == ["Only"])
    }

    @Test("an account with no scrobbles reads as an empty page")
    func readsNothing() throws {
        let json: [String: Any] = ["recenttracks": ["track": [Any](), "@attr": ["total": "0", "totalPages": "0"]]]
        let page = try LastFMClient.historyPage(from: json)
        #expect(page.scrobbles.isEmpty)
        #expect(page.totalPages == 0)
    }

    @Test("an answer without recent tracks is malformed")
    func rejectsTheWrongShape() {
        #expect(throws: LastFMError.malformedResponse) {
            try LastFMClient.historyPage(from: ["user": [String: Any]()])
        }
    }

    @Test("Last.fm's grey star is not a cover")
    func dropsThePlaceholder() {
        let star = "https://lastfm.freetls.fastly.net/i/u/300x300/\(LastFMClient.missingArtworkID).png"
        #expect(LastFMClient.artworkURL(from: [["#text": star]]) == nil)
        #expect(LastFMClient.artworkURL(from: [["#text": ""]]) == nil)
    }

    @Test("the request is signed, uses the session and asks for the range")
    func asksForTheRange() async throws {
        let captured = LockedBox<URLRequest?>(nil)
        let body = #"{"recenttracks": {"track": [], "@attr": {"total": "0", "totalPages": "0"}}}"#
        _ = try await client(answering: body) { captured.value = $0 }
            .recentTracks(session: session, after: at(0), before: at(60))

        let sent = parameters(of: try #require(captured.value))
        #expect(sent["method"] == "user.getRecentTracks")
        #expect(sent["user"] == "listener")
        #expect(sent["sk"] == "sk-1")
        #expect(sent["limit"] == "200")
        #expect(sent["from"] == "1700000000")
        #expect(sent["to"] == "1700003600")
        #expect(sent["api_sig"]?.isEmpty == false)
    }
}

@Suite("Last.fm history duplicates")
struct LastFMHistoryDuplicateTests {
    let policy = DedupePolicy(window: 10 * 60, importWindow: 24 * 60 * 60)

    private func newPlays(_ scrobbles: [ScrobbledTrack], known: [LastFMHistory.KnownPlay] = [], forgotten: Set<String> = []) -> [String] {
        LastFMHistory.newPlays(in: scrobbles, known: known, forgotten: forgotten, policy: policy)
            .map { "\($0.title)@\(Int($0.playedAt.timeIntervalSince(start) / 60))" }
    }

    @Test("new scrobbles come back oldest first")
    func oldestFirst() {
        #expect(newPlays([scrobble("B", 30), scrobble("A", 0)]) == ["A@0", "B@30"])
    }

    /// Tracks sends a row with its own time, so Last.fm has it to the second.
    @Test("a play Tracks scrobbled itself is skipped")
    func skipsTracksOwnScrobble() {
        #expect(newPlays([scrobble("A", 0)], known: [known("A", 0, .radio)]).isEmpty)
    }

    @Test(arguments: [
        (CaptureKind.onDemand, 4.0, true),    // another app's scrobble of a play Tracks kept
        (.onDemand, -4.0, true),              // the same, the other way round
        (.radio, 11.0, false),                // outside the window: a second play
        (.imported, 180.0, true),             // recovered from Recently Played three hours on
        (.imported, -30.0, false),            // an import found before this play can't be it
        (.lastFM, 5.0, true),                 // already imported
    ])
    func `a row of the same song counts by the merge windows`(kind: CaptureKind, minutesAfter: Double, isSkipped: Bool) {
        let result = newPlays([scrobble("A", 0)], known: [known("A", minutesAfter, kind)])
        #expect(result.isEmpty == isSkipped)
    }

    @Test("one song scrobbled twice inside the window is kept once")
    func collapsesRepeatsWithinThePage() {
        #expect(newPlays([scrobble("A", 0), scrobble("A", 3), scrobble("A", 30)]) == ["A@0", "A@30"])
    }

    @Test("another song at the same time is kept")
    func matchesOnSong() {
        #expect(newPlays([scrobble("B", 0)], known: [known("A", 0, .radio)]) == ["B@0"])
    }

    @Test("a song you removed stays out")
    func respectsForgottenSongs() {
        let forgotten: Set = [HistoryImport.key(title: "A", artistName: "An Artist")]
        #expect(newPlays([scrobble("A", 0), scrobble("B", 5)], forgotten: forgotten) == ["B@5"])
    }
}

@MainActor
@Suite("Importing Last.fm history into the store")
struct LastFMHistoryStoreTests {
    private let scratch = ScratchDefaults()
    var settings: CaptureSettings { scratch.settings }

    @Test("rows are dated when they played and never sent back to Last.fm")
    func writesLastFMRows() throws {
        let store = try TracksStore(inMemory: true)
        #expect(try store.importScrobbles([scrobble("A", 0), scrobble("B", 5)], settings: settings) == 2)

        let rows = try store.context.fetch(TracksStore.allCaptures())
        #expect(rows.map(\.capturedAt) == [at(5), at(0)])
        #expect(rows.allSatisfy { $0.kind == .lastFM && $0.scrobbledAt != nil && !$0.needsPlaylistWrite })
        #expect(try store.context.fetch(TracksStore.pendingScrobbles(includingImported: true)).isEmpty)
    }

    /// A long history would otherwise search the catalog once per play before any playlist
    /// write could go.
    @Test("rows are not searched for in the catalog")
    func skipsCatalogSearch() throws {
        let store = try TracksStore(inMemory: true)
        try store.importScrobbles([scrobble("A", 0)], settings: settings)
        #expect(try store.context.fetch(TracksStore.awaitingCatalogID()).isEmpty)
    }

    @Test("importing the same page twice adds nothing the second time")
    func isIdempotent() throws {
        let store = try TracksStore(inMemory: true)
        let page = [scrobble("A", 0), scrobble("B", 5)]
        #expect(try store.importScrobbles(page, settings: settings) == 2)
        #expect(try store.importScrobbles(page, settings: settings) == 0)
        #expect(try store.context.fetchCount(TracksStore.allCaptures()) == 2)
    }

    @Test("a play the store already has is left alone")
    func keepsTheWitnessedRow() throws {
        let store = try TracksStore(inMemory: true)
        store.context.insert(Capture(songID: "1", title: "A", artistName: "An Artist", kind: .radio, capturedAt: at(0)))
        try store.context.save()

        #expect(try store.importScrobbles([scrobble("A", 0)], settings: settings) == 0)
        let rows = try store.context.fetch(TracksStore.allCaptures())
        #expect(rows.map(\.kind) == [.radio])
    }

    /// The merge must agree with the import, or it would delete what the import wrote.
    @Test("the sync merge finds nothing to fold into an import")
    func agreesWithTheMerge() throws {
        let store = try TracksStore(inMemory: true)
        store.context.insert(Capture(songID: "1", title: "A", artistName: "An Artist", kind: .onDemand, capturedAt: at(0)))
        try store.context.save()
        try store.importScrobbles([scrobble("A", 2), scrobble("A", 20), scrobble("A", 25)], settings: settings)

        #expect(try store.mergeDuplicateCaptures(policy: settings.dedupePolicy) == 0)
        #expect(try store.context.fetchCount(TracksStore.allCaptures()) == 2)
    }
}

/// A Last.fm account serving `user.getRecentTracks` from a list, a few at a time.
private actor ScrobbleHistoryServer {
    var scrobbles: [ScrobbledTrack]
    let pageSize: Int
    /// Fails this many requests with Last.fm's "try again" before answering.
    var busyFor = 0
    /// Fails every request from this one on (counting from one), as a dropped connection
    /// would, retries included.
    var dropsRequest: Int?
    private(set) var requests: [[String: String]] = []

    init(_ scrobbles: [ScrobbledTrack], pageSize: Int = 2) {
        self.scrobbles = scrobbles
        self.pageSize = pageSize
    }

    func add(_ scrobble: ScrobbledTrack) { scrobbles.append(scrobble) }
    func setBusy(_ count: Int) { busyFor = count }
    func setDrops(_ request: Int?) { dropsRequest = request }

    func respond(to request: URLRequest) throws -> (Data, URLResponse) {
        let sent = parameters(of: request)
        requests.append(sent)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        if let dropsRequest, requests.count >= dropsRequest { throw URLError(.networkConnectionLost) }
        if busyFor > 0 {
            busyFor -= 1
            return (Data(#"{"error": 29, "message": "Rate limit exceeded"}"#.utf8), response)
        }

        let from = sent["from"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) ?? .distantPast
        let to = sent["to"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) ?? .distantFuture
        let range = scrobbles
            .filter { $0.playedAt >= from && $0.playedAt <= to }
            .sorted { $0.playedAt > $1.playedAt }
        let page = range.prefix(pageSize).map { track -> [String: Any] in
            ["artist": ["#text": track.artistName], "name": track.title,
             "date": ["uts": String(Int(track.playedAt.timeIntervalSince1970))]]
        }
        let pages = (range.count + pageSize - 1) / pageSize
        let json: [String: Any] = ["recenttracks": [
            "track": page,
            "@attr": ["total": String(range.count), "totalPages": String(pages)],
        ]]
        return (try JSONSerialization.data(withJSONObject: json), response)
    }
}

@MainActor
@Suite("Walking the Last.fm history")
struct LastFMHistoryImporterTests {
    private let scratch = ScratchDefaults()
    var settings: CaptureSettings { scratch.settings }

    private func importer(_ server: ScrobbleHistoryServer, store: TracksStore, now: Date = at(1_000)) -> LastFMHistoryImporter {
        let client = LastFMClient(apiKey: "KEY", secret: "SECRET") { try await server.respond(to: $0) }
        let importer = LastFMHistoryImporter(client: client, session: session, store: store, settings: settings)
        importer.pause = { _ in }
        importer.now = { now }
        return importer
    }

    private func titles(in store: TracksStore) throws -> [String] {
        try store.context.fetch(TracksStore.allCaptures()).map(\.title).sorted()
    }

    @Test("the whole history is read page by page")
    func readsEverything() async throws {
        let store = try TracksStore(inMemory: true)
        let server = ScrobbleHistoryServer((0..<5).map { scrobble("Song \($0)", Double($0) * 10) })

        let report = try await importer(server, store: store).run()

        #expect(report.imported == 5)
        #expect(report.total == 5)
        #expect(try titles(in: store) == (0..<5).map { "Song \($0)" })
        let progress = try #require(settings.lastFMHistoryProgress)
        #expect(progress.importedThrough == at(40))
        #expect(progress.imported == 5)
        #expect(!progress.isUnfinished)
        #expect(progress.lastFinished == at(1_000))
    }

    @Test("a later sync only asks for what's new")
    func syncsOnlyWhatsNew() async throws {
        let store = try TracksStore(inMemory: true)
        let server = ScrobbleHistoryServer([scrobble("Old", 0), scrobble("Older", -10)])
        try await importer(server, store: store).run()

        await server.add(scrobble("New", 60))
        let report = try await importer(server, store: store, now: at(2_000)).run()

        #expect(report.imported == 1)
        #expect(try titles(in: store) == ["New", "Old", "Older"])
        let requests = await server.requests
        let lastRequest = try #require(requests.last)
        #expect(lastRequest["from"] == String(Int(at(0).timeIntervalSince1970)))
    }

    @Test("a run that fails part way carries on from there next time")
    func resumesAfterAFailure() async throws {
        let store = try TracksStore(inMemory: true)
        let server = ScrobbleHistoryServer((0..<6).map { scrobble("Song \($0)", Double($0) * 10) })
        await server.setDrops(2)

        await #expect(throws: URLError.self) {
            try await importer(server, store: store).run()
        }
        let stopped = try #require(settings.lastFMHistoryProgress)
        #expect(stopped.isUnfinished)
        #expect(try store.context.fetchCount(TracksStore.allCaptures()) == 2)

        // Something new arrives while it's stopped: the resumed run picks it up too.
        await server.setDrops(nil)
        await server.add(scrobble("Newer", 100))
        try await importer(server, store: store).run()

        #expect(try titles(in: store) == ((0..<6).map { "Song \($0)" } + ["Newer"]).sorted())
        let finished = try #require(settings.lastFMHistoryProgress)
        #expect(!finished.isUnfinished)
        #expect(finished.importedThrough == at(100))
        #expect(finished.imported == 7)
    }

    @Test("Last.fm saying it's busy is waited out")
    func retriesWhenBusy() async throws {
        let store = try TracksStore(inMemory: true)
        let server = ScrobbleHistoryServer([scrobble("A", 0)])
        await server.setBusy(2)

        #expect(try await importer(server, store: store).run().imported == 1)
    }

    @Test("another account starts from nothing")
    func progressBelongsToTheAccount() {
        var other = LastFMHistory.Progress(username: "someone else")
        other.importedThrough = at(0)
        settings.lastFMHistoryProgress = other
        #expect(settings.lastFMHistory(for: "listener") == LastFMHistory.Progress(username: "listener"))
    }
}

@Suite("Last.fm history words")
struct LastFMHistoryWordsTests {
    typealias State = LastFMHistoryWords.State

    @Test("the state follows the run, then the stored progress")
    func resolvesState() {
        var progress = LastFMHistory.Progress(username: "listener")
        #expect(State(progress: nil, running: nil, failure: nil) == .notImported)
        #expect(State(progress: progress, running: nil, failure: nil) == .notImported)

        let report = LastFMHistoryImporter.Report(read: 400, imported: 120, total: 9_000)
        #expect(State(progress: progress, running: report, failure: nil) == .importing(read: 400, total: 9_000, added: 120))

        progress.runBefore = at(0)
        progress.imported = 120
        #expect(State(progress: progress, running: nil, failure: nil) == .stopped(added: 120))
        #expect(State(progress: progress, running: nil, failure: "Offline.") == .failed("Offline."))

        progress.runBefore = nil
        progress.lastFinished = at(10)
        #expect(State(progress: progress, running: nil, failure: nil) == .upToDate(lastSynced: at(10), added: 120))
    }

    @Test(arguments: [
        (State.notImported, "Import Your Scrobbles", "Import"),
        (.importing(read: 0, total: nil, added: 0), "Stop Importing", "Stop"),
        (.stopped(added: 3), "Continue Importing", "Continue"),
        (.upToDate(lastSynced: .now, added: 3), "Sync Now", "Sync Now"),
        (.failed("x"), "Try Again", "Try Again"),
    ])
    func `each state has its button`(state: State, action: String, button: String) {
        #expect(LastFMHistoryWords.action(state) == action)
        #expect(LastFMHistoryWords.button(state) == button)
    }

    @Test("progress is counted in scrobbles read and plays added")
    func countsProgress() {
        #expect(LastFMHistoryWords.detail(.importing(read: 0, total: 52_000, added: 0)) == "Importing… read 0 of 52,000 scrobbles · 0 new")
        #expect(LastFMHistoryWords.detail(.importing(read: 3_400, total: 52_000, added: 3_100)) == "Importing… read 3,400 of 52,000 scrobbles · 3,100 new")
        #expect(LastFMHistoryWords.detail(.importing(read: 0, total: nil, added: 0)) == "Importing…")
    }

    @Test("a stopped run says how much is in")
    func saysWhatsIn() {
        #expect(LastFMHistoryWords.detail(.stopped(added: 1)) == "Stopped part way · 1 play added so far. Continue picks up where it left off.")
        #expect(LastFMHistoryWords.detail(.stopped(added: 12_345)).hasPrefix("Stopped part way · 12,345 plays added so far."))
    }

    @Test("a failure says so, then why")
    func explainsFailure() {
        #expect(LastFMHistoryWords.detail(.failed("Last.fm returned HTTP 503.")) == "Couldn’t import. Last.fm returned HTTP 503.")
    }
}

/// A value a `@Sendable` closure can set.
private final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
