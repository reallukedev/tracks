import Testing
import Foundation
@testable import TracksCore

/// Which of Music's transport controls actually work.
@Suite("Transport routing")
struct TransportRoutingTests {

    @Test("nothing running means nothing to drive")
    func nothingRunning() {
        #expect(TransportRouting.capabilities(presence: .absent) == .none)
    }

    @Test("a paused or stopped Music can still be driven", arguments: [
        PlaybackState.paused, .stopped,
    ])
    func runningIsDrivable(state: PlaybackState) {
        let capabilities = TransportRouting.capabilities(presence: PlayerPresence(state: state))
        for command in TransportCommand.allCases {
            #expect(capabilities.allows(command), "\(command) should be available while \(state)")
        }
    }

    /// On a live broadcast on 2026-09-08, `next track`, `previous track` and `back track` all
    /// returned no error and changed nothing (`database ID` stayed 8579); `playpause` worked.
    /// See docs/ProbeResults/macos-transport-2026-09-08.md. Algorithmic stations weren't tested.
    @Test("a station can only be paused, not skipped")
    func radioCannotSkip() {
        let capabilities = TransportRouting.capabilities(
            presence: PlayerPresence(state: .playing, isRadio: true)
        )
        #expect(capabilities.canPlayPause)
        #expect(!capabilities.canSkipBack)
        #expect(!capabilities.canSkipForward)
        #expect(!capabilities.allows(.previous))
        #expect(!capabilities.allows(.next))
    }

    @Test("an on-demand track keeps every control")
    func onDemandIsUnrestricted() {
        let capabilities = TransportRouting.capabilities(
            presence: PlayerPresence(state: .playing, isRadio: false)
        )
        for command in TransportCommand.allCases {
            #expect(capabilities.allows(command), "\(command) should be available on demand")
        }
    }
}

@Suite("Music's position")
struct MusicPositionTests {
    @Test("Reads seconds with either decimal mark, and nothing that isn't a time")
    func seconds() {
        #expect(PlayerPresence.seconds("212.5") == 212.5)
        #expect(PlayerPresence.seconds("212,5") == 212.5)
        #expect(PlayerPresence.seconds(" 30 ") == 30)
        for bad in [nil, "", "missing value", "-3", "nan", "inf"] as [String?] {
            #expect(PlayerPresence.seconds(bad) == nil, "\(bad ?? "nil")")
        }
    }
}
