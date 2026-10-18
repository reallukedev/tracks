import Testing
import Foundation
@testable import TracksCore

/// How the share of a song that must play becomes a time, and how the old setting, a time of
/// its own, carries over.
@Suite("Minimum listen share")
struct MinimumListenShareTests {
    /// A fresh, empty suite per test, removed when the test finishes.
    private let scratch = ScratchDefaults()
    private var settings: CaptureSettings { scratch.settings }

    @Test("the share is held between none and nine tenths", arguments: [(-0.2, 0.0), (0.4, 0.4), (1.0, 0.9)])
    func shareIsClamped(stored: Double, read: Double) {
        settings.minimumListenShare = stored
        #expect(settings.minimumListenShare == read)
    }

    @Test("a share stored out of range by another device is still read in range")
    func storedShareIsClamped() {
        scratch.defaults.set(5.0, forKey: CaptureSettings.minimumListenShareKey)
        #expect(settings.minimumListenShare == CaptureSettings.maximumListenShare)
    }

    @Test("the time owed is the share of the song's length")
    func timeFollowsLength() {
        settings.minimumListenShare = 0.5
        #expect(settings.minimumListen(forDuration: 180) == 90)
        #expect(settings.minimumListen(forDuration: nil) == 120)
    }

    // MARK: - Carrying over the old setting

    @Test("Straight Away carries over from the old time")
    func straightAwayCarriesOver() {
        scratch.defaults.set(0.0, forKey: CaptureSettings.legacyMinimumListenKey)
        settings.migrateMinimumListen()
        #expect(settings.minimumListenShare == 0)
    }

    /// No share matches a time on every song, so the time gives way to the default.
    @Test("any other old time gives way to the default", arguments: [30.0, 90.0])
    func otherTimesTakeTheDefault(seconds: TimeInterval) {
        scratch.defaults.set(seconds, forKey: CaptureSettings.legacyMinimumListenKey)
        settings.migrateMinimumListen()
        #expect(scratch.defaults.object(forKey: CaptureSettings.minimumListenShareKey) == nil)
        #expect(settings.minimumListenShare == CaptureSettings.defaultMinimumListenShare)
    }

    /// The old time can still be lying around after a share has been chosen, here or synced
    /// down from another device. The share is the newer choice.
    @Test("a share already chosen is left alone")
    func chosenShareWins() {
        settings.minimumListenShare = 0.25
        scratch.defaults.set(0.0, forKey: CaptureSettings.legacyMinimumListenKey)
        settings.migrateMinimumListen()
        #expect(settings.minimumListenShare == 0.25)
    }
}
