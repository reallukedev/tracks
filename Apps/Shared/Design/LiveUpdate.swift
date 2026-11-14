import SwiftUI

/// How a screen changes when new listening arrives: numbers roll to their new value, bars
/// grow, and a new song slides into its place.
///
/// Only for live changes. A screen's first figures, and a switch to another range, appear at
/// once: animating a whole screen in is noise, not news.
enum LiveUpdate {
    /// How long a page that's already showing waits for a burst of revisions to settle
    /// before working its figures out again. A first load or a new selection doesn't wait.
    static let settle: Duration = .milliseconds(400)

    /// Nil with Reduce Motion, so the new figures simply appear.
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.5)
    }

    /// Runs `body`, animated when `isLive` says the change is new listening on the same
    /// screen rather than a first load or a different selection.
    ///
    /// Never animated on the Mac, where an animated change lays out the whole window on every
    /// frame it runs: the Summary dashboard spent about 200 ms laying out per song.
    static func apply(isLive: Bool, reduceMotion: Bool, _ body: () -> Void) {
        #if os(macOS)
        body()
        #else
        withAnimation(isLive ? animation(reduceMotion: reduceMotion) : nil, body)
        #endif
    }
}
