import Foundation

/// Rough listening time per capture.
///
/// We only know when a song was captured, not how long it played (radio on the Mac reports
/// no duration at all), so this uses the gap to the next capture. Anything we can't measure
/// gets a typical song length, and the UI says "about".
public enum ListeningEstimate {
    public static let typicalSongSeconds: TimeInterval = 210

    /// A longer gap than this means playback stopped somewhere in between.
    public static let longestPlausibleGap: TimeInterval = 600

    /// One value per capture. `ordered` must be oldest first and should be the whole history,
    /// since the song after the end of a range is what measures the last one in it.
    public static func seconds(for ordered: [CaptureStat]) -> [TimeInterval] {
        var result = [TimeInterval](repeating: typicalSongSeconds, count: ordered.count)
        var nextWitnessed: Date?
        for index in ordered.indices.reversed() {
            let capture = ordered[index]
            // Imports are timestamped when we found them, often dozens at once, so their
            // gaps mean nothing. They keep the typical length.
            guard capture.kind.timeIsKnown else { continue }
            if let next = nextWitnessed {
                let gap = next.timeIntervalSince(capture.capturedAt)
                if gap > 0, gap <= longestPlausibleGap { result[index] = gap }
            }
            nextWitnessed = capture.capturedAt
        }
        return result
    }
}
