import Testing
import TracksCore
@testable import TracksMusic

/// Play Back on iOS goes through this service.
@Suite("MusicKit playback")
struct MusicKitPlaybackServiceTests {

    /// Checked before MusicKit is touched, so an empty Play Back never asks about the
    /// subscription or queries the catalog.
    @Test("an empty queue fails before reaching MusicKit")
    func emptyQueue() async {
        await #expect(throws: PlaybackError.nothingToPlay) {
            try await MusicKitPlaybackService().play(songIDs: [])
        }
    }
}
