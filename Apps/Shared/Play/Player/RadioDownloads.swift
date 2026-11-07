import Foundation

/// What Tracks Radio needs from your own music to start with songs already on this iPhone and
/// get its new finds ready in the background: which songs play at once, and getting the rest.
/// Your Music is it.
@MainActor
protocol RadioDownloads: AnyObject {
    /// Whether Tracks Radio should start with songs ready to play and get its new finds ready
    /// behind them. Its setting, on by default.
    var downloadsFirst: Bool { get }
    /// Whether a song plays at once, with nothing to wait for: a file, or one downloaded.
    func isReady(_ song: HistorySong) -> Bool
    /// Starts getting a song ready: downloading it, or asking its server to keep it first.
    func prepare(_ song: HistorySong)
    /// A song taken out of Up Next before it played: stops getting it ready.
    func decline(_ song: HistorySong)
    /// A song Tracks Radio played has given way. One downloaded only to play on the radio has its
    /// download removed, with Delete After Playing on. Returns whether it was.
    func finishedPlaying(_ song: HistorySong) -> Bool
    /// Keeps a song Tracks Radio downloaded to play: downloaded again if it's been removed, and
    /// not removed after it plays.
    func keep(_ song: HistorySong)
    /// Called with a song's identity once it's ready to play at once. Set by the player.
    var onReady: ((String) -> Void)? { get set }
}
