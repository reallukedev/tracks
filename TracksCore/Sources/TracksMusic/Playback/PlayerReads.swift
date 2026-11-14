import Foundation

/// Runs reads of Apple's music players one at a time, off the main thread.
///
/// Some reads, such as the playback position, ask Apple's player service and wait for its
/// answer: tens of milliseconds as a song changes, seconds while the service restarts. A
/// `DispatchQueue` rather than the concurrent pool, so the wait doesn't tie up a cooperative
/// thread, and serial, so reads never overlap.
public enum PlayerReads {
    private static let queue = DispatchQueue(
        label: "com.luke.tracks.player-reads",
        qos: .userInitiated
    )

    public static func run<T: Sendable>(_ read: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: read()) }
        }
    }
}
