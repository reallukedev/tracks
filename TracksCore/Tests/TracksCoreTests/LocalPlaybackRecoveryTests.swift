import Testing
import Foundation
@testable import TracksCore

@Suite("Recovering your own music's playback")
struct LocalPlaybackRecoveryTests {
    static let lost = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
    static let timedOut = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
    /// AVFoundation's own error, with the connection's beneath it.
    static let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [NSUnderlyingErrorKey: lost])
    static let notFound = NSError(domain: "AVFoundationErrorDomain", code: -11829)

    @Test("a stream that dropped is tried again, a little later each time", arguments: [lost, timedOut, wrapped])
    func retriesDroppedStream(error: NSError) {
        #expect(StreamRetry.step(after: error, isStream: true, tried: 0) == .retry(after: .seconds(1)))
        #expect(StreamRetry.step(after: error, isStream: true, tried: 1) == .retry(after: .seconds(2)))
    }

    @Test("then given up on")
    func givesUpAfterTries() {
        #expect(StreamRetry.step(after: Self.lost, isStream: true, tried: StreamRetry.tries) == .giveUp)
    }

    @Test("a stream that stopped without saying why is tried again")
    func retriesSilentFailure() {
        #expect(StreamRetry.step(after: nil, isStream: true, tried: 0) == .retry(after: .seconds(1)))
    }

    @Test("a file, or a song that won't play however often it's tried, isn't")
    func noRetryForFilesOrBadSongs() {
        #expect(StreamRetry.step(after: Self.lost, isStream: false, tried: 0) == .giveUp)
        #expect(StreamRetry.step(after: Self.notFound, isStream: true, tried: 0) == .giveUp)
    }

    static func isPrivate(_ port: String) -> Bool { ["Headphones", "Bluetooth"].contains(port) }

    @Test("headphones out pauses, so it doesn't go on out loud")
    func headphonesOut() {
        #expect(RoutePause.shouldPause(previous: ["Headphones"], current: ["Speaker"], isPrivate: Self.isPrivate))
        #expect(RoutePause.shouldPause(previous: ["Bluetooth"], current: ["Speaker"], isPrivate: Self.isPrivate))
    }

    @Test("a car or AirPlay speaker dropping out, or one set of headphones for another, doesn't", arguments: [
        (["CarAudio"], ["Speaker"]),
        (["AirPlay"], ["Speaker"]),
        (["Bluetooth"], ["Headphones"]),
        (["Speaker"], ["Speaker"]),
    ])
    func otherChanges(previous: [String], current: [String]) {
        #expect(!RoutePause.shouldPause(previous: previous, current: current, isPrivate: Self.isPrivate))
    }
}
