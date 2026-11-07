import Foundation

public enum TransportCommand: String, Sendable, Equatable, CaseIterable {
    case previous
    case playPause
    case next
}

/// What Music is doing. `state` is nil when it isn't running.
public struct PlayerPresence: Sendable, Equatable {
    public let state: PlaybackState?
    /// Whether it's playing a station.
    public let isRadio: Bool
    /// Seconds into the song, when Music said.
    public let position: Double?
    /// The song's length, when Music said. Never for a station.
    public let duration: Double?

    public init(state: PlaybackState?, isRadio: Bool = false, position: Double? = nil, duration: Double? = nil) {
        self.state = state
        self.isRadio = isRadio
        self.position = position
        self.duration = duration
    }

    /// Seconds as Music writes them as text: "212.5", or "212,5" where a comma is the
    /// decimal mark. Nil for anything else, or a time that can't be one.
    public static func seconds(_ text: String?) -> Double? {
        guard let text, let value = Double(text.trimmingCharacters(in: .whitespaces).replacing(",", with: ".")),
              value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// Not running at all.
    public static let absent = PlayerPresence(state: nil)

    public var isRunning: Bool { state != nil }
    public var isPlaying: Bool { state == .playing }
}

/// What Music's transport controls can be asked to do.
///
/// Pure, so the rules can be tested without Music running.
public enum TransportRouting {
    /// Which controls work right now. Anything that can't work is disabled.
    public static func capabilities(presence: PlayerPresence) -> TransportCapabilities {
        guard presence.isRunning else { return .none }
        // On a live station, `next track`, `previous track` and `back track` do nothing
        // and return no error; only `playpause` works. See
        // docs/PlatformNotes.md. Only tested on a live
        // broadcast; an algorithmic station might accept `next track`.
        return TransportCapabilities(
            canPlayPause: true,
            canSkipBack: !presence.isRadio,
            canSkipForward: !presence.isRadio
        )
    }
}

/// Which transport controls are meaningful for what is playing.
public struct TransportCapabilities: Sendable, Equatable {
    public var canPlayPause: Bool
    public var canSkipBack: Bool
    public var canSkipForward: Bool

    public init(canPlayPause: Bool, canSkipBack: Bool, canSkipForward: Bool) {
        self.canPlayPause = canPlayPause
        self.canSkipBack = canSkipBack
        self.canSkipForward = canSkipForward
    }

    /// Nothing is running.
    public static let none = TransportCapabilities(
        canPlayPause: false,
        canSkipBack: false,
        canSkipForward: false
    )

    public func allows(_ command: TransportCommand) -> Bool {
        switch command {
        case .previous: canSkipBack
        case .playPause: canPlayPause
        case .next: canSkipForward
        }
    }
}
