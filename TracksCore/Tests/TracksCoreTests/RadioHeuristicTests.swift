import Testing
import Foundation
@testable import TracksCore

/// The observed difference between a live station and an album on macOS. These fail if
/// Apple changes the payload.
@Suite("Radio detection")
struct RadioHeuristicTests {

    /// The captured radio case: no Total Time, no duration, no composer, position at zero.
    @Test("a track with no duration is radio")
    func noDurationIsRadio() {
        let verdict = RadioHeuristic.evaluate(
            .init(duration: nil, hasComposer: false, playerPosition: 0)
        )
        #expect(verdict == .radio(confidence: .corroborated))
        #expect(verdict.shouldCapture)
    }

    /// The captured on-demand case: Total Time 148734, duration 148.73.
    @Test("a track with a real duration is on demand")
    func durationIsOnDemand() {
        let verdict = RadioHeuristic.evaluate(.init(duration: 148.73, hasComposer: true))
        #expect(verdict == .onDemand)
        #expect(!verdict.shouldCapture)
    }

    /// Music omits zero-valued keys, so "no length" can arrive as missing or as zero.
    @Test("a zero or negative duration counts as no duration", arguments: [0.0, -1.0])
    func zeroDuration(duration: TimeInterval) {
        #expect(RadioHeuristic.evaluate(.init(duration: duration)).shouldCapture)
    }

    /// Plenty of real tracks have no composer.
    @Test("composer only affects confidence, never the verdict")
    func composerIsCorroboration() {
        let withComposer = RadioHeuristic.evaluate(
            .init(duration: nil, hasComposer: true, playerPosition: 0)
        )
        let without = RadioHeuristic.evaluate(
            .init(duration: nil, hasComposer: false, playerPosition: 0)
        )
        #expect(withComposer == .radio(confidence: .likely))
        #expect(without == .radio(confidence: .corroborated))
        #expect(withComposer.shouldCapture && without.shouldCapture)
    }

    @Test("the user's own switch overrides the inference")
    func userOverride() {
        let verdict = RadioHeuristic.evaluate(
            .init(duration: 200, hasComposer: true, userForcedCapture: true)
        )
        #expect(verdict == .radio(confidence: .asserted))
    }

    /// Tracks’ own player queued the music, so it says rather than guesses.
    @Test("a player that says what it's playing decides", arguments: [true, false])
    func statedStation(isStation: Bool) {
        // Evidence that points the other way each time, to show it's ignored.
        let verdict = RadioHeuristic.evaluate(.init(
            duration: isStation ? 200 : nil,
            entryIdentifier: QueueEntryIdentifier(isStation ? "q::abc" : "q::STREAM"),
            statedStation: isStation
        ))
        #expect(verdict == (isStation ? .radio(confidence: .stated) : .onDemand))
    }

    @Test("an observation carries its stated station through to the verdict")
    func observationStatesStation() {
        let observation = NowPlayingObservation(title: "Song", artistName: "Artist", duration: 180, isStation: true)
        #expect(observation.radioVerdict() == .radio(confidence: .stated))
        #expect(observation.radioVerdict(userForcedCapture: true) == .radio(confidence: .asserted))
    }

    @Test("asserted outranks corroborated outranks likely")
    func confidenceOrdering() {
        #expect(RadioHeuristic.Confidence.likely < .corroborated)
        #expect(RadioHeuristic.Confidence.corroborated < .asserted)
    }
}

/// Apple Music 1 exposed shapes the first two captures did not: a station announced as a
/// track, notifications carrying only a player state, and a ~16 second heartbeat repeating
/// the same track.
@Suite("Live broadcast edge cases")
struct LiveBroadcastTests {

    /// Observed at tune-in: Name "Apple Music 1", artist and album empty.
    @Test("a station announcement is never capturable")
    func stationAnnouncement() {
        let observation = NowPlayingObservation(title: "Apple Music 1", artistName: "")
        #expect(observation.isStationAnnouncement)
        #expect(!observation.isCapturable)
        #expect(observation.announcedStationName == "Apple Music 1")
    }

    /// Announcements are the only station name source on macOS (`current stream title` is
    /// always empty), so they mustn't catch real tracks.
    @Test("a real track is not mistaken for a station announcement")
    func realTrack() {
        let observation = NowPlayingObservation(title: "Lost Boys", artistName: "Phoebe Bridgers")
        #expect(!observation.isStationAnnouncement)
        #expect(observation.announcedStationName == nil)
        #expect(observation.isCapturable)
    }

    /// Two of these arrived back to back at 13:21:43, carrying a Player State and nothing else.
    @Test("a payload with no track is not capturable")
    func emptyPayload() {
        #expect(!NowPlayingObservation(title: "", artistName: "").isCapturable)
    }

    @Test("a paused track is not capturable even when fully identified")
    func pausedTrack() {
        let observation = NowPlayingObservation(
            title: "Lost Boys", artistName: "Phoebe Bridgers", playbackState: .paused
        )
        #expect(!observation.isCapturable)
    }

    /// Position stays at zero on a station, independently of the missing duration.
    @Test("position pinned at zero corroborates the duration signal")
    func positionCorroborates() {
        let verdict = RadioHeuristic.evaluate(
            .init(duration: nil, hasComposer: false, playerPosition: 0)
        )
        #expect(verdict == .radio(confidence: .corroborated))
    }

    @Test("an advancing position with a real duration is on demand")
    func advancingPosition() {
        let verdict = RadioHeuristic.evaluate(
            .init(duration: 148.73, hasComposer: true, playerPosition: 28.1)
        )
        #expect(verdict == .onDemand)
    }

    /// Missing a radio track is worse than a rare false capture.
    @Test("duration alone still captures when position is unknown")
    func durationAlone() {
        let verdict = RadioHeuristic.evaluate(.init(duration: nil, playerPosition: nil))
        #expect(verdict.shouldCapture)
        #expect(verdict == .radio(confidence: .likely))
    }
}
