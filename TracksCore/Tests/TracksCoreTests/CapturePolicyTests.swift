import Testing
import Foundation
@testable import TracksCore

@Suite("Dedupe window")
struct DedupePolicyTests {
    let policy = DedupePolicy(window: 600)
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("a song never seen before is always captured")
    func firstSighting() {
        #expect(policy.shouldCapture(lastSeen: nil, now: now))
    }

    @Test("a repeat inside the window is the same play", arguments: [0.0, 1.0, 300.0, 599.0])
    func insideWindow(elapsed: TimeInterval) {
        #expect(!policy.shouldCapture(lastSeen: now.addingTimeInterval(-elapsed), now: now))
    }

    /// The boundary is inclusive: exactly one window later counts as a new play.
    @Test("a repeat at or after the window is a new play", arguments: [600.0, 601.0, 3_600.0])
    func outsideWindow(elapsed: TimeInterval) {
        #expect(policy.shouldCapture(lastSeen: now.addingTimeInterval(-elapsed), now: now))
    }
}

@Suite("Session segmentation")
struct SessionPolicyTests {
    let policy = SessionPolicy(silenceTimeout: 900)
    let now = Date(timeIntervalSince1970: 2_000_000)

    @Test("with no session open, anything starts a new one")
    func noOpenSession() {
        let decision = policy.decide(
            openSessionStation: "Apple Music 1",
            openSessionLastActivity: nil,
            observedStation: "Apple Music 1",
            now: now
        )
        #expect(decision == .startNew)
    }

    @Test("continuing on the same station stays in the session")
    func sameStation() {
        let decision = policy.decide(
            openSessionStation: "Apple Music 1",
            openSessionLastActivity: now.addingTimeInterval(-60),
            observedStation: "Apple Music 1",
            now: now
        )
        #expect(decision == .current)
    }

    /// A session is contiguous listening to *one* station, so a change ends it even with
    /// no gap at all.
    @Test("changing station starts a new session even with no silence")
    func stationChange() {
        let decision = policy.decide(
            openSessionStation: "Apple Music 1",
            openSessionLastActivity: now,
            observedStation: "Apple Música Uno",
            now: now
        )
        #expect(decision == .startNew)
    }

    @Test("silence past the timeout starts a new session")
    func silenceTimeout() {
        let decision = policy.decide(
            openSessionStation: "Apple Music 1",
            openSessionLastActivity: now.addingTimeInterval(-901),
            observedStation: "Apple Music 1",
            now: now
        )
        #expect(decision == .startNew)
    }

    /// macOS often cannot name the station. Fragmenting the session every time would be
    /// worse than assuming it has not changed.
    @Test("an unknown incoming station does not fragment the session")
    func unknownStation() {
        let decision = policy.decide(
            openSessionStation: "Apple Music 1",
            openSessionLastActivity: now.addingTimeInterval(-60),
            observedStation: nil,
            now: now
        )
        #expect(decision == .current)
    }
}

@Suite("Scrobble threshold")
struct ScrobblePolicyTests {
    let policy = ScrobblePolicy()

    /// Last.fm's floor. ListenBrainz has none, so the stricter rule satisfies both.
    @Test("tracks of 30 seconds or less never scrobble", arguments: [1.0, 29.0, 30.0])
    func tooShort(duration: TimeInterval) {
        #expect(!policy.shouldScrobble(duration: duration, playedFor: duration))
    }

    @Test("a short track scrobbles at half its length")
    func halfway() {
        #expect(policy.shouldScrobble(duration: 200, playedFor: 100))
        #expect(!policy.shouldScrobble(duration: 200, playedFor: 99))
    }

    /// For anything over eight minutes, four minutes is the earlier of the two thresholds.
    @Test("a long track scrobbles at four minutes, not at half")
    func fourMinuteCap() {
        #expect(policy.shouldScrobble(duration: 1_200, playedFor: 240))
        #expect(!policy.shouldScrobble(duration: 1_200, playedFor: 239))
    }
}

@Suite("Scrobble threshold: required playback")
struct ScrobbleRequiredPlaybackTests {
    let policy = ScrobblePolicy()

    @Test("an unknown length is taken as the assumed song length", arguments: [TimeInterval?.none, 0, -5, .nan])
    func unknownLength(duration: TimeInterval?) {
        #expect(CaptureSettings.assumedSongLength == 240)
        #expect(policy.requiredPlayback(forDuration: duration) == 120)
    }

    @Test("a track of 30 seconds can never qualify")
    func thirtySeconds() {
        #expect(policy.requiredPlayback(forDuration: 30) == nil)
    }

    @Test("half the length, capped at four minutes", arguments: [
        (30.5, 15.25), (31, 15.5), (200, 100), (480, 240), (481, 240), (1_200, 240), (36_000, 240), (.infinity, 240),
    ] as [(TimeInterval, TimeInterval)])
    func halfCapped(duration: TimeInterval, expected: TimeInterval) {
        #expect(policy.requiredPlayback(forDuration: duration) == expected)
    }

    @Test("the requirement is positive, at most the cap, and at most half the track")
    func invariant() throws {
        for duration in stride(from: 30.5, through: 2_000, by: 7.25) {
            let required = try #require(policy.requiredPlayback(forDuration: duration))
            #expect(required > 0)
            #expect(required <= ScrobblePolicy.maximumRequiredPlayback)
            #expect(required <= duration / 2)
        }
        #expect(ScrobblePolicy.minimumTrackDuration == 30)
        #expect(ScrobblePolicy.maximumRequiredPlayback == 240)
    }

    @Test("whether to scrobble agrees with the required playback, inclusively")
    func shouldScrobbleAgrees() {
        let durations: [TimeInterval] = [1, 29, 30, 30.5, 31, 59, 120, 200, 479, 480, 481, 1_200]
        let played: [TimeInterval] = [0, 10, 15.25, 15.5, 29.5, 50, 99.99, 100, 119, 120, 239, 240, 241, 600, 1_200]
        for duration in durations {
            let required = policy.requiredPlayback(forDuration: duration)
            for playedFor in played {
                let expected = required.map { playedFor >= $0 } ?? false
                #expect(
                    policy.shouldScrobble(duration: duration, playedFor: playedFor) == expected,
                    "duration \(duration), played \(playedFor)"
                )
            }
        }
    }
}

@MainActor
@Suite("Held from scrobbling")
struct HeldFromScrobblingTests {
    let store: TracksStore
    let device = "held-test-device"
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws {
        store = try TracksStore(inMemory: true)
    }

    func row(_ title: String = "Song") throws -> Capture {
        let capture = Capture(songID: title, title: title, artistName: "An Artist", capturedAt: start, deviceID: device)
        store.context.insert(capture)
        try store.context.save()
        return capture
    }

    func pendingIDs() throws -> [String] {
        try store.context.fetch(TracksStore.pendingScrobbles(deviceID: device, includingImported: true)).map(\.songID)
    }

    nonisolated static let reasons = [ScrobblePolicy.tooShortReason, ScrobblePolicy.notPlayedEnoughReason]

    @Test("a fresh capture is not held")
    func fresh() throws {
        #expect(try !row().isHeldFromScrobbling)
    }

    @Test("a play Last.fm refused is not held")
    func refused() throws {
        let capture = try row()
        capture.lastScrobbleError = "Too old"
        capture.scrobbleAttempts = TracksStore.maxScrobbleAttempts
        #expect(!capture.isHeldFromScrobbling)
    }

    @Test("a policy reason on a play already scrobbled is not held", arguments: reasons)
    func alreadyScrobbled(reason: String) throws {
        let capture = try row()
        capture.lastScrobbleError = reason
        capture.scrobbledAt = start
        #expect(!capture.isHeldFromScrobbling)
    }

    @Test("a policy reason on an unscrobbled play is held", arguments: reasons)
    func heldByReason(reason: String) throws {
        let capture = try row()
        capture.lastScrobbleError = reason
        #expect(capture.isHeldFromScrobbling)
    }

    @Test("holding a play takes it out of the queue", arguments: reasons)
    func hold(reason: String) throws {
        let capture = try row()
        #expect(try pendingIDs() == ["Song"])

        capture.holdFromScrobbling(reason: reason)
        try store.context.save()

        #expect(capture.scrobbleAttempts == TracksStore.maxScrobbleAttempts)
        #expect(capture.lastScrobbleError == reason)
        #expect(capture.isHeldFromScrobbling)
        #expect(try pendingIDs().isEmpty)
    }

    @Test("releasing a held play puts it back in the queue, and twice is the same as once")
    func release() throws {
        let capture = try row()
        capture.holdFromScrobbling(reason: ScrobblePolicy.notPlayedEnoughReason)
        try store.context.save()

        capture.releaseForScrobbling()
        try store.context.save()
        #expect(capture.scrobbleAttempts == 0)
        #expect(capture.lastScrobbleError == nil)
        #expect(!capture.isHeldFromScrobbling)
        #expect(try pendingIDs() == ["Song"])

        capture.releaseForScrobbling()
        try store.context.save()
        #expect(capture.scrobbleAttempts == 0)
        #expect(capture.lastScrobbleError == nil)
        #expect(try pendingIDs() == ["Song"])
    }

    @Test("releasing never revives a play Last.fm refused")
    func releaseKeepsRefusal() throws {
        let capture = try row()
        capture.lastScrobbleError = "Too old"
        capture.scrobbleAttempts = TracksStore.maxScrobbleAttempts
        try store.context.save()

        capture.releaseForScrobbling()
        try store.context.save()

        #expect(capture.lastScrobbleError == "Too old")
        #expect(capture.scrobbleAttempts == TracksStore.maxScrobbleAttempts)
        #expect(try pendingIDs().isEmpty)
    }

    @Test("releasing a play already scrobbled changes nothing")
    func releaseScrobbled() throws {
        let capture = try row()
        capture.scrobbledAt = start
        capture.scrobbleAttempts = 1
        try store.context.save()

        capture.releaseForScrobbling()

        #expect(capture.scrobbledAt == start)
        #expect(capture.scrobbleAttempts == 1)
        #expect(try pendingIDs().isEmpty)
    }
}

@Suite("Session segmentation boundaries")
struct SessionPolicyBoundaryTests {
    let policy = SessionPolicy(silenceTimeout: 900)
    let now = Date(timeIntervalSince1970: 2_000_000)
    let station = "Apple Music 1"

    func decide(
        _ policy: SessionPolicy? = nil,
        open: String?,
        lastActivity: TimeInterval?,
        observed: String?
    ) -> SessionPolicy.Decision {
        (policy ?? self.policy).decide(
            openSessionStation: open,
            openSessionLastActivity: lastActivity.map { now.addingTimeInterval($0) },
            observedStation: observed,
            now: now
        )
    }

    @Test("quiet just under the timeout stays in the session")
    func justUnder() {
        #expect(decide(open: station, lastActivity: -899.999, observed: station) == .current)
    }

    @Test("quiet at or past the timeout starts a new session", arguments: [-900.0, -901.0])
    func atOrPast(offset: TimeInterval) {
        #expect(decide(open: station, lastActivity: offset, observed: station) == .startNew)
    }

    @Test("last activity in the future stays in the session")
    func clockWentBackwards() {
        #expect(decide(open: station, lastActivity: 5, observed: station) == .current)
    }

    @Test("an unnamed or unknown station never splits the session", arguments: [
        (String?.none, String?("Apple Music 1")),
        ("Apple Music 1", nil),
        (nil, nil),
    ])
    func unknownStations(open: String?, observed: String?) {
        #expect(decide(open: open, lastActivity: -60, observed: observed) == .current)
    }

    @Test("a different station starts a new session")
    func differentStation() {
        #expect(decide(open: "Apple Music 1", lastActivity: -60, observed: "Apple Music 2") == .startNew)
    }

    @Test(
        "the same station spelled with different case or a stray space stays in the session",
        arguments: [("Apple Music 1", "apple music 1"), ("Apple Music 1 ", "Apple Music 1")]
    )
    func foldedStation(open: String, observed: String) {
        #expect(decide(open: open, lastActivity: -60, observed: observed) == .current)
    }

    @Test("no open session starts a new one, even with no station names")
    func noOpenSession() {
        #expect(decide(open: nil, lastActivity: nil, observed: nil) == .startNew)
    }

    @Test("a zero timeout starts a new session on every observation")
    func zeroTimeout() {
        #expect(decide(SessionPolicy(silenceTimeout: 0), open: station, lastActivity: 0, observed: station) == .startNew)
    }

    @Test("silence, a station change, or both start a new session", arguments: [
        (-1_000.0, "Apple Music 1"),
        (-60.0, "Apple Music 2"),
        (-1_000.0, "Apple Music 2"),
    ])
    func precedence(offset: TimeInterval, observed: String) {
        #expect(decide(open: station, lastActivity: offset, observed: observed) == .startNew)
    }
}
