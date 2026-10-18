import Foundation
import TracksCore

enum DemoMode {
    /// `-TracksDemoData YES` on the command line (or in the scheme's arguments), in a Debug
    /// build. A shipping build always opens the real store.
    static var isRequestedAtLaunch: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "TracksDemoData")
        #else
        false
        #endif
    }

    /// A fresh in-memory store filled with `DemoLibrary` plays ending now.
    @MainActor
    static func makeStore() throws -> TracksStore {
        let store = try TracksStore(inMemory: true, sync: false)
        if !isEmptyRequested {
            try store.seedDemoData(DemoLibrary.plays(endingAt: .now, days: days))
        }
        return store
    }

    /// `-TracksDemoEmpty YES` alongside `-TracksDemoData YES`, in a Debug build: nothing played
    /// yet, to see the screens as someone opening Tracks for the first time does.
    private static var isEmptyRequested: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "TracksDemoEmpty")
        #else
        false
        #endif
    }

    /// `-TracksDemoDays 1800` alongside `-TracksDemoData YES`, in a Debug build: years of sample
    /// listening instead of ten months, to see how the screens hold up in a long history.
    private static var days: Int {
        #if DEBUG
        let requested = UserDefaults.standard.integer(forKey: "TracksDemoDays")
        if requested > 0 { return requested }
        #endif
        return 300
    }

    /// `-TracksDemoLive YES` alongside `-TracksDemoData YES`, in a Debug build: a sample song
    /// finishes every few seconds, to watch the screens change as listening arrives.
    static var isLiveRequested: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "TracksDemoLive")
        #else
        false
        #endif
    }

    /// Adds a sample song to the demo store every `interval` until cancelled.
    @MainActor
    static func runLiveFeed(into store: TracksStore, every interval: Duration = .seconds(5)) async {
        var number = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            number += 1
            try? store.seedDemoData([DemoLibrary.livePlay(at: .now, number: number)])
        }
    }
}
