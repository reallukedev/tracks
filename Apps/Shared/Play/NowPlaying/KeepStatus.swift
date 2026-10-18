import Foundation
import TracksCore

/// How close the song on is to being kept in your history: the ring beside its play count on
/// the phone, and the same ring in the car.
enum KeepStatus: Equatable {
    /// Filling: how far through the share of the song that must play, 0 to 1.
    case counting(Double)
    case kept

    /// Where the song on stands, or nil when this playing won't be kept at all: capture is
    /// off for it, or Tracks has already passed it over as a repeat of a play it just heard.
    @MainActor
    static func of(_ track: PlayerTrack, player: PlayerModel, capture: CaptureService, at date: Date = .now) -> KeepStatus? {
        guard willBeKept(player: player, capture: capture) else { return nil }
        if isKept(track, player: player, capture: capture) { return .kept }
        if isPassedOver(track, player: player, capture: capture) { return nil }
        let fill = progress(player: player, at: date)
        // With sample data nothing is really kept, so a full ring stands in for it.
        return player.isDemo && fill >= 1 ? .kept : .counting(fill)
    }

    /// Whether Tracks will keep this song at all: on-demand plays can be switched off in
    /// Settings, which leaves stations only.
    @MainActor
    static func willBeKept(player: PlayerModel, capture: CaptureService) -> Bool {
        !capture.isPaused && (player.context?.isStation == true || CaptureSettings().capturesOnDemand)
    }

    /// Whether Tracks has kept this playing of it: the last capture is this song, made since it
    /// started.
    @MainActor
    static func isKept(_ track: PlayerTrack, player: PlayerModel, capture: CaptureService) -> Bool {
        guard let last = capture.lastCapture,
              HistoryImport.key(title: last.title, artistName: last.artistName) == track.songIdentity,
              let started = player.trackStartedAt
        else { return false }
        // With no minimum, the capture can land a moment before the player reports the song.
        let slack: TimeInterval = CaptureSettings().minimumListenShare > 0 ? 0 : 5
        return last.capturedAt >= started.addingTimeInterval(-slack)
    }

    /// Whether Tracks has already decided not to keep this playing: it heard the song moments
    /// ago, so this counts as the same play, or its station is excluded. The ring would fill
    /// and never turn into a check, so it isn't shown.
    @MainActor
    static func isPassedOver(_ track: PlayerTrack, player: PlayerModel, capture: CaptureService) -> Bool {
        guard !isKept(track, player: player, capture: capture),
              let heard = capture.nowPlaying,
              HistoryImport.key(title: heard.title, artistName: heard.artistName) == track.songIdentity,
              case .ignore(let reason) = capture.lastDecision
        else { return false }
        switch reason {
        case .duplicate, .excludedStation, .onDemand: return true
        default: return false
        }
    }

    /// How far through the share of it that must play the song is. Counted as the capture
    /// counts it, from when the song first played, so neither loading nor scrubbing fills the
    /// ring ahead of the check.
    @MainActor
    static func progress(player: PlayerModel, at date: Date) -> Double {
        let minimum = CaptureSettings().minimumListen(forDuration: player.current?.duration)
        guard minimum > 0 else { return 1 }
        let elapsed = player.trackStartedAt.map { date.timeIntervalSince($0) } ?? 0
        return min(1, max(0, elapsed / minimum))
    }

}
