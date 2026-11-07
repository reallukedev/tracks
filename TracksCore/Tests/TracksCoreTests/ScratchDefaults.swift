import Foundation
@testable import TracksCore

/// A `UserDefaults` suite of its own, so tests that write settings can run in parallel
/// without seeing each other's values or the developer's real ones.
///
/// A class rather than a struct so a test suite, which is a struct and can't have a
/// `deinit`, still gets the suite cleared when the test finishes with it. Hold one as a
/// stored property: Swift Testing makes a fresh suite instance for every test and releases
/// it afterwards. A test that only needs a suite name for a moment can instead call
/// ``remove(suiteName:)`` from a `defer`.
final class ScratchDefaults {
    let suiteName = "com.luke.tracks.tests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        // Force-unwrapped deliberately: `UserDefaults(suiteName:)` only returns nil for the
        // reserved names, and a fresh UUID is never one. A nil here is a bug in the test.
        defaults = UserDefaults(suiteName: suiteName)!
    }

    /// Settings backed by this suite. `CaptureSettings` resolves the suite by name on every
    /// read, so any number of these see the same values.
    var settings: CaptureSettings { CaptureSettings(suiteName: suiteName) }

    deinit {
        Self.remove(suiteName: suiteName)
    }

    /// Empties a suite a test wrote to, as far as `UserDefaults` allows.
    ///
    /// Isolation doesn't depend on this: every suite has a fresh UUID name, so no test can see
    /// another's values. This is about not piling state up in `~/Library/Preferences`.
    ///
    /// `removePersistentDomain(forName:)` alone often leaves the values a test just wrote in
    /// the plist, because writes reach the preferences daemon asynchronously and can land
    /// after the removal. Removing each key through the suite and synchronizing first catches
    /// most of them. Not all: under a full parallel `swift test` some plists still keep their
    /// last values (`CaptureSettings` opens a new `UserDefaults` for every read and write, and
    /// their pending writes aren't ordered against these). Only an in-memory settings store
    /// would avoid the files entirely. `dictionaryRepresentation()` also lists the global
    /// domain's keys, but `removeObject(forKey:)` on a suite only touches the suite.
    static func remove(suiteName: String) {
        if let defaults = UserDefaults(suiteName: suiteName) {
            for key in defaults.dictionaryRepresentation().keys {
                defaults.removeObject(forKey: key)
            }
            defaults.synchronize()
        }
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}
