import Testing
import Foundation
import MusicKit
import TracksCore
@testable import TracksMusic

/// Tracks’ own player states what it's playing, so its captures aren't guessed at.
@Suite("Tracks’ player capture")
@MainActor
struct ApplicationMusicPlayerSourceTests {
    @Test("a song from a station Tracks started is radio, with the station's name")
    func station() throws {
        let entry = MusicPlayer.Queue.Entry(try MusicPlayerReadingTests.song())
        let observation = try #require(ApplicationMusicPlayerSource.observation(
            from: entry, status: .playing, playbackTime: 0, isStation: true, stationName: "Apple Music 1"
        ))
        #expect(observation.isStation == true)
        #expect(observation.stationName == "Apple Music 1")
        #expect(observation.radioVerdict() == .radio(confidence: .stated))
        #expect(CapturePolicy().decide(observation, lastSeen: nil).isCapture)
    }

    @Test("a song Tracks played on demand is on demand, whatever its entry looks like")
    func onDemand() throws {
        let entry = MusicPlayer.Queue.Entry(try MusicPlayerReadingTests.song())
        let observation = try #require(ApplicationMusicPlayerSource.observation(
            from: entry, status: .playing, playbackTime: 12, isStation: false, stationName: "Ignored"
        ))
        #expect(observation.isStation == false)
        #expect(observation.stationName == nil)
        #expect(observation.radioVerdict() == .onDemand)
        guard case .capture(let capturable) = CapturePolicy().decide(observation, lastSeen: nil) else {
            Issue.record("expected a capture")
            return
        }
        #expect(capturable.kind == .onDemand)
    }

    @Test("an empty player has nothing to observe")
    func empty() {
        #expect(ApplicationMusicPlayerSource.observation(
            from: nil, status: .stopped, playbackTime: 0, isStation: false, stationName: nil
        ) == nil)
    }
}
