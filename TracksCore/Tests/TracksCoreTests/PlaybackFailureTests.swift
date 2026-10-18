import Testing
import Foundation
@testable import TracksCore

@Suite("Why Apple Music didn't play")
struct PlaybackFailureTests {
    @Test("the player's queue cut short is an interruption, worth one more try")
    func interrupted() {
        let failure = PlaybackFailure(NSError(domain: "MPMusicPlayerControllerErrorDomain", code: 2))
        #expect(failure == .interrupted)
        #expect(failure.isWorthRetrying)
    }

    @Test("MediaPlayer's own errors read as what they mean", arguments: [
        (1, PlaybackFailure.accessDenied),
        (2, .noSubscription),
        (3, .offline),
        (4, .unavailable),
        (6, .superseded),
        (7, .timedOut),
        (0, .other),
    ])
    func mediaPlayer(code: Int, expected: PlaybackFailure) {
        #expect(PlaybackFailure(NSError(domain: "MPErrorDomain", code: code)) == expected)
    }

    @Test("no connection is being offline, which trying again won't fix", arguments: [
        URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
    ])
    func offline(code: URLError.Code) {
        let failure = PlaybackFailure(URLError(code))
        #expect(failure == .offline)
        #expect(failure.isWorthRetrying == false)
    }

    @Test("a request cancelled was replaced by a newer one")
    func cancelled() {
        #expect(PlaybackFailure(CancellationError()) == .superseded)
        #expect(PlaybackFailure(URLError(.cancelled)) == .superseded)
    }

    @Test("an error that wraps a plainer one is read by the one it wraps")
    func wrapped() {
        let inner = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let outer = NSError(domain: "MusicKit.MusicDataRequest.Error", code: 1, userInfo: [NSUnderlyingErrorKey: inner])
        #expect(PlaybackFailure(outer) == .timedOut)
    }

    @Test("anything unknown is other, and worth one more try")
    func unknown() {
        let failure = PlaybackFailure(NSError(domain: "SomeDomain", code: 42))
        #expect(failure == .other)
        #expect(failure.isWorthRetrying)
    }
}
