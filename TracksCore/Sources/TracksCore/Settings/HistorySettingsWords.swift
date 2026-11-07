import Foundation

/// The words for Settings ▸ History: what Tracks keeps, and when a play counts.
///
/// Pure, so tests pin every sentence and the root row, the page's status line and the Mac
/// pane can never disagree.
public enum HistorySettingsWords {
    /// The root row's value: "All Music" or "Radio Only".
    public static func short(keepsOnDemand: Bool) -> String {
        keepsOnDemand ? String(localized: "All Music") : String(localized: "Radio Only")
    }

    /// The status line: what's kept, then when a play counts.
    public static func status(keepsOnDemand: Bool, minimumListenShare: Double) -> String {
        let counting = minimumListenShare <= 0
            ? String(localized: "counts as soon as a song starts")
            : String(localized: "counts after \(percent(minimumListenShare)) of a song")
        return keepsOnDemand
            ? String(localized: "Keeping everything you play · \(counting)")
            : String(localized: "Keeping radio only · \(counting)")
    }

    /// "30 seconds", "1 minute", "1 minute, 30 seconds".
    public static func listenLength(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded())
            .formatted(.units(allowed: [.minutes, .seconds], width: .wide))
    }

    /// "50%". Whole percents, since the slider moves in fives.
    public static func percent(_ share: Double) -> String {
        share.formatted(.percent.precision(.fractionLength(0)))
    }

    /// The Counts After row's value: "Straight Away" or "50%".
    public static func countsAfterValue(_ share: Double) -> String {
        guard share > 0 else { return String(localized: "Straight Away") }
        return percent(share)
    }

    /// What the Counts After position means, read back as time for a typical song.
    public static func countsAfterFooter(_ share: Double) -> String {
        guard share > 0 else {
            return String(localized: "Every song is kept as soon as it starts, even one you skip straight away.")
        }
        let example = CaptureSettings.assumedSongLength
        let needs = CaptureSettings.minimumListen(share: share, duration: example)
        return String(localized: "A song is kept once \(percent(share)) of it has played, so skipping through doesn’t fill your history. For a song \(listenLength(example)) long, that’s \(listenLength(needs)).")
    }

    /// "10 min", for the Same Song Again row.
    public static func windowValue(minutes: Double) -> String {
        Duration.seconds((minutes * 60).rounded())
            .formatted(.units(allowed: [.minutes], width: .abbreviated))
    }

    /// What the Same Song Again position means.
    public static func windowFooter(minutes: Double) -> String {
        let length = Duration.seconds((minutes * 60).rounded())
            .formatted(.units(allowed: [.minutes], width: .wide))
        return String(localized: "Hearing the same song again within \(length) counts once.")
    }
}
