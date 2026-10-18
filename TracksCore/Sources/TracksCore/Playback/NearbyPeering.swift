import Foundation

/// Who connects to whom among your devices nearby, and which connection to keep.
///
/// Only one side of a pair opens the connection, the device whose id sorts first, so two
/// devices never connect to each other twice. That side has to keep trying: when the other
/// device's app is closed and opened again, or its network changes, nothing is found anew, and
/// a pair that waited for that would stay apart.
public enum NearbyPeering {
    /// Whether this device opens a connection to one it found: when its own id sorts first,
    /// and it has no connection to it already.
    public static func dials(_ peerID: String, from myID: String, linked: some Sequence<String>) -> Bool {
        myID < peerID && !linked.contains(peerID)
    }

    /// The connections to let go as a device introduces itself on a new one: any others to
    /// the same device. They're from before it went away, and can look alive for minutes after
    /// it has; the new one is the one that works.
    /// - Parameter links: every connection, with the device it's to once that's known.
    public static func replaced<Link: Hashable>(by newLink: Link, from peerID: String, links: [Link: String?]) -> [Link] {
        links.compactMap { link, peer in link != newLink && peer == peerID ? link : nil }
    }
}

/// Which player a Mac tells your other devices about. It has two: Music, and Tracks’ own.
public enum NearbyVoice {
    /// Tracks’ own player speaks for the Mac while it plays, and while it holds a song paused
    /// with Music playing nothing, so your other devices see one player rather than the two
    /// taking turns.
    public static func isTracks(hasSong: Bool, isPlaying: Bool, musicIsPlaying: Bool) -> Bool {
        hasSong && (isPlaying || !musicIsPlaying)
    }
}
