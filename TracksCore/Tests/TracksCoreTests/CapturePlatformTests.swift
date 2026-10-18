import Testing
import Foundation
@testable import TracksCore

/// Every capture records which platform saw it, for diagnosing gaps between iPhone and Mac.
@Suite("Capture platform")
struct CapturePlatformTests {

    @Test("the current platform is the one running the tests")
    func currentPlatform() {
        #if os(iOS)
        #expect(CapturePlatform.current == .iOS)
        #else
        #expect(CapturePlatform.current == .macOS)
        #endif
    }

    @Test("a new capture is stamped with the current platform")
    func newCapture() {
        let capture = Capture(songID: "1", title: "Lost Boys", artistName: "Phoebe Bridgers", deviceID: "test")
        #expect(capture.platform == .current)
    }

    /// A newer app version synced a platform this build doesn't know.
    @Test("an unknown stored platform reads as the current one")
    func unknownPlatform() {
        let capture = Capture(songID: "1", title: "Lost Boys", artistName: "Phoebe Bridgers", deviceID: "test")
        capture.platformRawValue = "visionOS"
        #expect(capture.platform == .current)
    }
}
