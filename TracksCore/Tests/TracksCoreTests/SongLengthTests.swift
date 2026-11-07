import Foundation
import Testing
@testable import TracksCore

@Suite("A song's length in the player")
struct SongLengthTests {
    @Test("a song off a station of on-demand songs keeps its length, to scrub")
    func onDemandStation() {
        #expect(SongLength.shown(214, isLiveBroadcast: false) == 214)
    }

    @Test("a live broadcast has none, even when the song playing reports one")
    func liveBroadcast() {
        #expect(SongLength.shown(214, isLiveBroadcast: true) == nil)
        #expect(SongLength.shown(nil, isLiveBroadcast: true) == nil)
    }

    @Test("a length that can't be scrubbed is none", arguments: [nil, 0, -3, .infinity, .nan] as [TimeInterval?])
    func unusable(duration: TimeInterval?) {
        #expect(SongLength.shown(duration, isLiveBroadcast: false) == nil)
    }
}
