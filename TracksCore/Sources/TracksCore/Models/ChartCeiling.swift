import Foundation

/// The top of a chart's value axis, rounded up so it moves in steps rather than with every
/// new play.
///
/// Swift Charts makes its axis labels afresh whenever the scale's domain changes, and keeps
/// the old ones' view graphs (iOS 27). A running total's peak grows with every song, so
/// Summary on All Time kept six labels' graphs a song, over 100 KB each time, for as long as
/// it stayed open. Rounded to a tenth of its order of magnitude, the top changes once every
/// few hundred songs instead, and gains at most a tenth more headroom.
public enum ChartCeiling {
    public static func rounded(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return value }
        let grain = pow(10, (log10(value)).rounded(.down)) / 10
        // A hair under, so a value already on a step (as 1 500 in hundreds) stays on it.
        return (value / grain - 1e-9).rounded(.up) * grain
    }
}
