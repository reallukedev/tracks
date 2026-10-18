import CloudKit
import Foundation
import Testing
@testable import TracksCore

/// Failures are said in Tracks' own words: what happened and what to do. Codes, domains and
/// servers' own messages ("Last.fm error 6: Invalid parameters", "CKErrorDomain error 2")
/// mean nothing to the person reading and stay in the log.
@Suite("Failures in plain words")
struct ErrorWordsTests {

    // MARK: - Last.fm

    @Test("Last.fm's failures are said plainly", arguments: [
        (LastFMError.http(status: 400), "Something went wrong with Last.fm. Try again."),
        (.http(status: 503), "Last.fm isn’t responding. Try again later."),
        (.service(code: 6, message: "Invalid parameters"), "Something went wrong with Last.fm. Try again."),
        (.service(code: 29, message: "Rate Limit Exceeded"), "Last.fm isn’t responding. Try again later."),
        (.service(code: 9, message: "Invalid session key - Please re-authenticate"),
         "You’re signed out of Last.fm. Connect your account again."),
        (.notConnected, "You’re signed out of Last.fm. Connect your account again."),
        (.service(code: 14, message: "Unauthorized Token"), "Last.fm didn’t get your approval. Try connecting again."),
        (.notAuthorised, "Last.fm didn’t get your approval. Try connecting again."),
        (.notConfigured, "Last.fm isn’t set up in this build of Tracks."),
        (.malformedResponse, "Something went wrong with Last.fm. Try again."),
    ])
    func lastFM(error: LastFMError, words: String) {
        #expect(ScrobbleService.describe(error) == words)
    }

    @Test("a dropped connection to Last.fm is being offline")
    func lastFMOffline() {
        #expect(ScrobbleService.describe(URLError(.notConnectedToInternet))
            == "You’re offline. Connect to the internet and try again.")
        #expect(ScrobbleService.describe(URLError(.timedOut)) == "Last.fm isn’t responding. Try again later.")
        #expect(!ScrobbleService.describe(CocoaError(.fileReadCorruptFile)).contains("Cocoa"))
    }

    @Test("an ignored scrobble's reason leaves out Last.fm's own message", arguments: [
        (3, "Too old for Last.fm, which only takes scrobbles from the last two weeks."),
        (5, "Last.fm’s daily scrobble limit was reached."),
        (91, "Last.fm didn’t take this scrobble."),
    ])
    func ignored(code: Int, words: String) {
        #expect(ScrobbleService.describeIgnored(code: code, message: "Timestamp failed filter") == words)
    }

    // MARK: - Playback

    @Test("Apple Music's failures are said plainly", arguments: [
        (PlaybackFailure.offline, "You’re offline. Connect to the internet and try again."),
        (.timedOut, "Apple Music took too long to answer. Try again in a moment."),
        (.unavailable, "That song isn’t available in Apple Music here. Try another."),
        (.accessDenied, "Tracks isn’t allowed to use Apple Music. Turn on Media & Apple Music for Tracks in Settings."),
        (.noSubscription, "Playing songs needs an active Apple Music subscription."),
        (.interrupted, "Apple Music stopped before the song started. Try again."),
        (.superseded, "Something else started playing first. Try again."),
        (.other, "Apple Music couldn’t play that. Try again."),
    ])
    func playback(failure: PlaybackFailure, words: String) {
        #expect(failure.words == words)
    }

    @MainActor
    @Test("a play that fails says why without the error's domain and code")
    func controllerWords() async throws {
        let store = try TracksStore(inMemory: true)
        let service = FakePlaybackService()
        service.playResult = .failure(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        let controller = PlaybackController(store: store, service: service)

        await controller.play(PlaybackItem(songID: "1", title: "T", artistName: "A"))
        #expect(controller.lastError == "You’re offline. Connect to the internet and try again.")

        // A player that has already put it in words is passed on as it said it.
        service.playResult = .failure(PlaybackError.failed("Music isn’t open. Open Music and try again."))
        await controller.play(PlaybackItem(songID: "1", title: "T", artistName: "A"))
        #expect(controller.lastError == "Music isn’t open. Open Music and try again.")
    }

    // MARK: - iCloud

    @Test("iCloud's failures are said plainly", arguments: [
        (CKError.Code.notAuthenticated, "You’re signed out of iCloud. Sign in to iCloud in Settings to sync your history."),
        (.networkUnavailable, "You’re offline. Tracks will sync when you’re back online."),
        (.networkFailure, "You’re offline. Tracks will sync when you’re back online."),
        (.serviceUnavailable, "iCloud is busy. Tracks will try again shortly."),
        (.requestRateLimited, "iCloud is busy. Tracks will try again shortly."),
        (.quotaExceeded, "Your iCloud storage is full. Free up space in iCloud to keep syncing."),
        (.invalidArguments, "iCloud wouldn’t take this device’s history. Update Tracks on all your devices."),
        (.incompatibleVersion, "This version of Tracks can’t sync. Update Tracks on all your devices."),
        (.badContainer, "iCloud sync ran into a problem. Tracks will try again."),
    ])
    func iCloud(code: CKError.Code, words: String) {
        let error = CKError(code, userInfo: [NSLocalizedDescriptionKey: "CKErrorDomain error \(code.rawValue)"])
        #expect(CloudSyncMonitor.message(for: error) == words)
    }

    /// What the Mac actually got: one record's reason, buried among the rest of the batch.
    @Test("a partial failure is said by the record that caused it")
    func partialFailureUsesTheCause() {
        let cause = "Cannot create or modify field 'CD_scrobbledAt' in record 'CD_Capture' in production schema"
        let error = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [
                CKRecord.ID(recordName: "a"): CKError(.batchRequestFailed),
                CKRecord.ID(recordName: "b"): CKError(.invalidArguments, userInfo: [NSLocalizedDescriptionKey: cause]),
                CKRecord.ID(recordName: "c"): CKError(.batchRequestFailed),
            ] as [CKRecord.ID: any Error],
        ])

        #expect(CloudSyncMonitor.message(for: error)
            == "iCloud wouldn’t take this device’s history. Update Tracks on all your devices.")
    }

    @Test("a store that couldn't open with iCloud says what to do")
    func startFailure() {
        let words = CloudSyncMonitor.startFailure(for: NSError(domain: "SwiftData.SwiftDataError", code: 1))
        #expect(words == "Tracks couldn’t open your history with iCloud. Check you’re signed in to iCloud, then open Tracks again.")
        #expect(CloudSyncMonitor.startFailure(for: CKError(.notAuthenticated))
            == "You’re signed out of iCloud. Sign in to iCloud in Settings to sync your history.")
    }
}
