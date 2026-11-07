import Testing
import Foundation
@testable import TracksCore

/// Which observations become captures. Every case here comes from the phase 0 logs.
@Suite("Capture decisions")
struct CaptureDecisionTests {
    let policy = CapturePolicy()
    let now = Date(timeIntervalSince1970: 3_000_000)

    /// iOS: a station entry, id ending in STREAM.
    func radioObservation(
        title: String = "Dai Dai",
        artist: String = "Shakira & Burna Boy",
        entryID: String = "PxDIf4ejk::STREAM",
        station: String? = nil
    ) -> NowPlayingObservation {
        NowPlayingObservation(
            title: title,
            artistName: artist,
            catalogSongID: "6768469976",
            duration: 223,
            stationName: station,
            rawFields: ["entry.id": entryID]
        )
    }

    @Test("a playing radio track is captured")
    func capturesRadio() {
        let decision = policy.decide(radioObservation(), lastSeen: nil, now: now)
        #expect(decision.isCapture)
    }

    /// An album entry has an opaque item id instead of STREAM. It's kept for scrobbling, but
    /// only radio goes to the playlist and play-back.
    @Test("an on-demand track is captured, as on demand")
    func capturesOnDemandSeparately() {
        let observation = radioObservation(entryID: "PRhKeIIy0::6ostOUDHU")
        let decision = policy.decide(observation, lastSeen: nil, now: now)
        guard case .capture(let capturable) = decision else {
            Issue.record("Expected a capture, got \(decision)")
            return
        }
        #expect(capturable.kind == .onDemand)
    }

    @Test("with on-demand capture off, an on-demand track is ignored")
    func honoursTheOnDemandSwitch() {
        let stationsOnly = CapturePolicy(capturesOnDemand: false)
        let observation = radioObservation(entryID: "PRhKeIIy0::6ostOUDHU")
        #expect(stationsOnly.decide(observation, lastSeen: nil, now: now) == .ignore(.onDemand))
    }

    @Test("an excluded station does not suppress on-demand plays")
    func exclusionOnlyAppliesToRadio() {
        let excluding = CapturePolicy(excludedStations: ["Apple Music Chill"])
        let onDemand = radioObservation(entryID: "PRhKeIIy0::6ostOUDHU", station: "Apple Music Chill")
        #expect(excluding.decide(onDemand, lastSeen: nil, now: now).isCapture)

        let radio = radioObservation(station: "Apple Music Chill")
        #expect(
            excluding.decide(radio, lastSeen: nil, now: now)
                == .ignore(.excludedStation(name: "Apple Music Chill"))
        )
    }

    /// Observed at tune-in on both platforms: the station arrives as a track with no artist.
    @Test("a station announcement is rejected, and names the station")
    func rejectsStationAnnouncement() {
        let observation = NowPlayingObservation(title: "Apple Music 1", artistName: "")
        #expect(
            policy.decide(observation, lastSeen: nil, now: now)
                == .ignore(.stationAnnouncement(name: "Apple Music 1"))
        )
    }

    /// Two of these arrived back to back at a state transition, carrying nothing but a state.
    @Test("a paused or empty observation is rejected")
    func rejectsNotPlaying() {
        let paused = NowPlayingObservation(
            title: "Dai Dai", artistName: "Shakira", playbackState: .paused
        )
        #expect(policy.decide(paused, lastSeen: nil, now: now) == .ignore(.notPlaying))
    }

    /// playerInfo repeats on a ~16 second heartbeat, so this is the common case.
    @Test("a repeat inside the dedupe window is rejected as a duplicate")
    func rejectsDuplicate() {
        let decision = policy.decide(
            radioObservation(),
            lastSeen: now.addingTimeInterval(-16),
            now: now
        )
        #expect(decision == .ignore(.duplicate(secondsSinceLast: 16)))
    }

    @Test("the same song after the window is a new play")
    func capturesAfterWindow() {
        let decision = policy.decide(
            radioObservation(),
            lastSeen: now.addingTimeInterval(-601),
            now: now
        )
        #expect(decision.isCapture)
    }

    @Test("an excluded station is skipped")
    func excludedStation() {
        var observation = radioObservation()
        observation.stationName = "Apple Music 1"
        let policy = CapturePolicy(excludedStations: ["Apple Music 1"])
        #expect(
            policy.decide(observation, lastSeen: nil, now: now)
                == .ignore(.excludedStation(name: "Apple Music 1"))
        )
    }

    @Test("forcing capture overrides an on-demand verdict")
    func forceCapture() {
        let observation = radioObservation(entryID: "PRhKeIIy0::6ostOUDHU")
        let policy = CapturePolicy(forceCapture: true)
        #expect(policy.decide(observation, lastSeen: nil, now: now).isCapture)
    }

    /// macOS before the catalog search: no id yet, but title and artist are enough.
    @Test("a macOS observation with no catalog id is still capturable")
    func macOSObservation() {
        let observation = NowPlayingObservation(
            title: "Nostalgia",
            artistName: "Lossapardo",
            albumTitle: "Nostalgia - Single",
            catalogSongID: nil,
            duration: nil,
            playerPosition: 0
        )
        let decision = policy.decide(observation, lastSeen: nil, now: now)
        #expect(decision.isCapture)
        if case .capture(let capturable) = decision {
            #expect(capturable.catalogSongID == nil)
        }
    }

    @Test("an observation with neither id nor metadata is rejected")
    func unidentifiable() {
        let observation = NowPlayingObservation(title: "", artistName: "")
        #expect(policy.decide(observation, lastSeen: nil, now: now) == .ignore(.unidentifiable))
    }
}
