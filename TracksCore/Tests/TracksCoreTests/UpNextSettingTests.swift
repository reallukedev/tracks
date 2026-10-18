import Testing
import Foundation
@testable import TracksCore

/// The switch in Settings that the widget extension reads.
@Suite("Up Next setting")
struct UpNextSettingTests {
    let suite = "com.luke.tracks.tests.\(UUID().uuidString)"

    @Test("Up Next is shown until someone turns it off")
    func onByDefault() {
        defer { ScratchDefaults.remove(suiteName: suite) }
        #expect(CaptureSettings(suiteName: suite).showsUpNextInWidget)
    }

    /// A second instance stands in for the widget, which reads from another process.
    @Test("turning it off is seen by another reader of the same defaults")
    func offPersistsAcrossReaders() {
        defer { ScratchDefaults.remove(suiteName: suite) }
        CaptureSettings(suiteName: suite).showsUpNextInWidget = false
        #expect(CaptureSettings(suiteName: suite).showsUpNextInWidget == false)
    }

    /// Settings binds with `@AppStorage` by key, so a mismatch writes where the widget never reads.
    @Test("the property and the key Settings binds to are the same value")
    func keyMatchesProperty() {
        defer { ScratchDefaults.remove(suiteName: suite) }
        UserDefaults(suiteName: suite)?.set(false, forKey: CaptureSettings.showsUpNextInWidgetKey)
        #expect(CaptureSettings(suiteName: suite).showsUpNextInWidget == false)
    }
}
