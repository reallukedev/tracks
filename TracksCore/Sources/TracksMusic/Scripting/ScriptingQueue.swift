#if os(macOS)
import Foundation

/// Runs Apple events one at a time, off the main thread.
///
/// `NSAppleScript` isn't safe to run concurrently, and an Apple event blocks its thread until
/// the other app answers or times out. A `DispatchQueue` rather than an actor, so the
/// blocking call doesn't tie up a cooperative pool thread.
public enum ScriptingQueue {
    private static let queue = DispatchQueue(
        label: "com.luke.tracks.scripting",
        qos: .userInitiated
    )

    public static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}
#endif
