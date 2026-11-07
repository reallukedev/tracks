import Testing
import Foundation
import SwiftData
@testable import TracksCore

/// The request signature. Last.fm answers any mistake with "Invalid method signature
/// supplied" and doesn't say which part was wrong.
@Suite("Last.fm signature")
struct LastFMSignatureTests {

    /// Last.fm's documented example: name+value pairs sorted by name, secret appended, MD5.
    @Test("parameters are concatenated in name order with the secret appended")
    func signsInNameOrder() {
        let signature = LastFMSignature.sign(
            ["method": "auth.getSession", "api_key": "KEY", "token": "TOKEN"],
            secret: "SECRET"
        )
        let expected = LastFMSignature.md5(
            "api_keyKEYmethodauth.getSessiontokenTOKENSECRET"
        )
        #expect(signature == expected)
    }

    /// `format` is sent but never signed; signing it gets the request rejected.
    @Test("format and callback are excluded from the signature")
    func excludesUnsignedParameters() {
        let base = ["method": "track.scrobble", "api_key": "KEY"]
        let withFormat = base.merging(["format": "json", "callback": "cb"]) { a, _ in a }
        #expect(
            LastFMSignature.sign(base, secret: "S") == LastFMSignature.sign(withFormat, secret: "S")
        )
    }

    @Test("an existing signature is not signed into itself")
    func excludesTheSignature() {
        let base = ["method": "m", "api_key": "KEY"]
        let withSig = base.merging(["api_sig": "whatever"]) { a, _ in a }
        #expect(LastFMSignature.sign(base, secret: "S") == LastFMSignature.sign(withSig, secret: "S"))
    }

    @Test("the signature does not depend on dictionary ordering")
    func isStable() {
        let once = LastFMSignature.sign(["b": "2", "a": "1", "c": "3"], secret: "S")
        let again = LastFMSignature.sign(["c": "3", "a": "1", "b": "2"], secret: "S")
        #expect(once == again)
    }

    @Test("md5 is lowercase hex")
    func hashFormat() {
        #expect(LastFMSignature.md5("abc") == "900150983cd24fb0d6963f7d28e17f72")
    }
}

@Suite("Last.fm request encoding")
struct LastFMEncodingTests {

    /// `URLComponents` leaves `+` alone, and the server decodes it as a space.
    @Test("a plus in a track name survives encoding")
    func encodesPlus() {
        let body = String(decoding: LastFMClient.formBody(["artist": "C+C Music Factory"]), as: UTF8.self)
        #expect(body.contains("%2B"))
        #expect(!body.contains("C+C"))
    }

    @Test("spaces and ampersands are encoded")
    func encodesSpecials() {
        let body = String(decoding: LastFMClient.formBody(["track": "Me & You"]), as: UTF8.self)
        #expect(!body.contains(" "))
        #expect(body.contains("%26"))
    }
}

/// Which failures are worth retrying. Retrying a bad signature wastes every row's attempts;
/// giving up on a rate limit drops listening.
@Suite("Last.fm error handling")
struct LastFMErrorTests {

    @Test("rate limits and outages are retryable")
    func retryableFailures() {
        #expect(LastFMError.http(status: 429).isRetryable)
        #expect(LastFMError.http(status: 503).isRetryable)
        #expect(LastFMError.service(code: 29, message: "Rate limit exceeded").isRetryable)
        #expect(LastFMError.service(code: 11, message: "Service offline").isRetryable)
    }

    @Test("a rejected request is not retryable")
    func permanentFailures() {
        // 13 is "invalid method signature".
        #expect(!LastFMError.service(code: 13, message: "Invalid method signature").isRetryable)
        #expect(!LastFMError.http(status: 400).isRetryable)
        #expect(!LastFMError.notConfigured.isRetryable)
    }

    /// It was built by interpolation and force-unwrapped, so a token URLs reject trapped.
    @Test("the approval link encodes the token")
    func authorisationURLEncodes() throws {
        let client = LastFMClient(apiKey: "KEY", secret: "SECRET")
        let url = client.authorisationURL(for: "a b&c=d")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(url.host() == "www.last.fm")
        #expect(items.first { $0.name == "token" }?.value == "a b&c=d")
        #expect(items.first { $0.name == "api_key" }?.value == "KEY")
    }
}

@MainActor
@Suite("Scrobble queue")
struct ScrobbleQueueTests {

    private func capture(
        _ title: String,
        kind: CaptureKind = .radio,
        device: String = "this-device",
        at when: Date = .now
    ) -> Capture {
        Capture(songID: title, title: title, artistName: "An Artist", kind: kind, capturedAt: when, deviceID: device)
    }

    /// The database syncs, so otherwise every device would scrobble every row.
    @Test("only rows this device recorded are owed a scrobble")
    func scopedToThisDevice() throws {
        let store = try TracksStore(inMemory: true)
        store.context.insert(capture("Mine"))
        store.context.insert(capture("Theirs", device: "other-device"))
        try store.context.save()

        let owed = try store.context.fetch(
            TracksStore.pendingScrobbles(deviceID: "this-device", includingImported: true)
        )
        #expect(owed.map(\.title) == ["Mine"])
    }

    /// A scrobble has a timestamp, and an imported row is dated when it was found.
    @Test("imported rows are excluded unless asked for")
    func importedRowsAreOptional() throws {
        let store = try TracksStore(inMemory: true)
        store.context.insert(capture("Witnessed"))
        store.context.insert(capture("Imported", kind: .imported))
        try store.context.save()

        let without = try store.context.fetch(
            TracksStore.pendingScrobbles(deviceID: "this-device", includingImported: false)
        )
        #expect(without.map(\.title) == ["Witnessed"])

        let with = try store.context.fetch(
            TracksStore.pendingScrobbles(deviceID: "this-device", includingImported: true)
        )
        #expect(with.count == 2)
    }

    @Test("a scrobbled row is not owed again")
    func skipsSentRows() throws {
        let store = try TracksStore(inMemory: true)
        let sent = capture("Sent")
        sent.scrobbledAt = .now
        store.context.insert(sent)
        store.context.insert(capture("Owed"))
        try store.context.save()

        let owed = try store.context.fetch(
            TracksStore.pendingScrobbles(deviceID: "this-device", includingImported: true)
        )
        #expect(owed.map(\.title) == ["Owed"])
    }

    /// A track Last.fm never accepts mustn't block the queue.
    @Test("a row that has failed too often is given up on")
    func givesUpEventually() throws {
        let store = try TracksStore(inMemory: true)
        let doomed = capture("Doomed")
        doomed.scrobbleAttempts = TracksStore.maxScrobbleAttempts
        store.context.insert(doomed)
        try store.context.save()

        #expect(try store.context.fetch(
            TracksStore.pendingScrobbles(deviceID: "this-device", includingImported: true)
        ).isEmpty)
    }

    @Test("the queue is in listening order")
    func oldestFirst() throws {
        let store = try TracksStore(inMemory: true)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        store.context.insert(capture("Later", at: base.addingTimeInterval(60)))
        store.context.insert(capture("Earlier", at: base))
        try store.context.save()

        let owed = try store.context.fetch(
            TracksStore.pendingScrobbles(deviceID: "this-device", includingImported: true)
        )
        #expect(owed.map(\.title) == ["Earlier", "Later"])
    }
}

/// The client against a fake transport.
@Suite("Last.fm client")
struct LastFMClientTests {

    private func client(
        answering body: String,
        status: Int = 200,
        capturing recorder: (@Sendable (URLRequest) -> Void)? = nil
    ) -> LastFMClient {
        LastFMClient(apiKey: "KEY", secret: "SECRET") { request in
            recorder?(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (Data(body.utf8), response)
        }
    }

    @Test("a token is read from the response")
    func readsToken() async throws {
        let token = try await client(answering: #"{"token":"abc"}"#).requestToken()
        #expect(token == "abc")
    }

    @Test("a session carries the username and key")
    func readsSession() async throws {
        let json = #"{"session":{"name":"example","key":"sk-123","subscriber":0}}"#
        let session = try await client(answering: json).session(for: "abc")
        #expect(session == LastFMSession(username: "example", sessionKey: "sk-123"))
    }

    /// Before the user clicks Allow in the browser. The caller polls on this.
    @Test("an unapproved token reports notAuthorised rather than a service error")
    func mapsUnauthorisedToken() async {
        let json = #"{"error":14,"message":"This token has not been authorized"}"#
        await #expect(throws: LastFMError.notAuthorised) {
            try await client(answering: json).session(for: "abc")
        }
    }

    /// Last.fm often sends its errors with HTTP 400; the body says what actually went wrong.
    @Test("a service error in the body wins over the HTTP status")
    func prefersTheBodyError() async {
        let json = #"{"error":13,"message":"Invalid method signature supplied"}"#
        await #expect(throws: LastFMError.service(code: 13, message: "Invalid method signature supplied")) {
            try await client(answering: json, status: 400).requestToken()
        }
    }

    @Test("scrobbles are sent indexed, and the indices are signed")
    func sendsIndexedScrobbles() async throws {
        let body = LockedBox()
        let client = client(answering: FakeLastFM.outcomes([0, 0]), capturing: { request in
            body.set(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        })
        let played = Date(timeIntervalSince1970: 1_700_000_000)
        let sent = try await client.scrobble(
            [
                Scrobble(artist: "BANKS", track: "Love Is Unkind", album: "Off With Her Head", playedAt: played),
                Scrobble(artist: "Mk.gee", track: "You", playedAt: played.addingTimeInterval(60)),
            ],
            session: LastFMSession(username: "example", sessionKey: "sk")
        )

        #expect(sent == 2)
        let form = body.value ?? ""
        #expect(form.contains("artist%5B0%5D=BANKS"))
        #expect(form.contains("track%5B1%5D=You"))
        #expect(form.contains("timestamp%5B0%5D=1700000000"))
        // The album is optional and must be omitted rather than sent empty.
        #expect(!form.contains("album%5B1%5D"))

        // Every field that was sent, decoded, so the signature can be checked against exactly
        // what Last.fm will see.
        var fields = try Self.decodeForm(form)
        // Sent but never signed.
        let format = fields.removeValue(forKey: "format")
        #expect(format == "json")
        let sentSignature = fields.removeValue(forKey: "api_sig")
        let signature = try #require(sentSignature)
        #expect(Set(fields.keys) == [
            "method", "api_key", "sk",
            "artist[0]", "track[0]", "timestamp[0]", "album[0]",
            "artist[1]", "track[1]", "timestamp[1]",
        ])

        // Built by hand rather than through `LastFMSignature.sign`, so a signer that skipped
        // the indexed keys can't agree with itself. Everything sent except `format` and the
        // signature is signed: name and value, in name order, then the secret.
        let signable = fields.sorted { $0.key < $1.key }.map { $0.key + $0.value }.joined()
        #expect(signature == LastFMSignature.md5(signable + "SECRET"))
    }

    /// Splits a form body back into its fields. Keys are unique here, since the client builds
    /// the body from a dictionary.
    private static func decodeForm(_ form: String) throws -> [String: String] {
        var fields: [String: String] = [:]
        for pair in form.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = try #require(String(parts[0]).removingPercentEncoding)
            let value = try #require(String(parts.count > 1 ? parts[1] : "").removingPercentEncoding)
            fields[name] = value
        }
        return fields
    }

    @Test("an empty batch is not a request")
    func skipsEmptyBatches() async throws {
        let calls = LockedBox()
        let client = client(answering: "{}", capturing: { _ in calls.set("called") })
        let sent = try await client.scrobble([], session: LastFMSession(username: "l", sessionKey: "k"))
        #expect(sent == 0)
        #expect(calls.value == nil)
    }
}

/// A `Sendable` box, so the fake transport can report what it saw.
private final class LockedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    var value: String? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func set(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        stored = value
    }
}
