import Foundation

/// Which of your devices has the music, for the checkmark in Your Devices, as AirPlay marks
/// the speaker playing.
public enum MusicLocation: Sendable, Equatable {
    case here
    case device(String)
    case nowhere

    /// One of your other devices, as far as this needs to know.
    public struct Peer: Sendable {
        public let id: String
        public let hasSong: Bool
        public let isPlaying: Bool

        public init(id: String, hasSong: Bool, isPlaying: Bool) {
            self.id = id
            self.hasSong = hasSong
            self.isPlaying = isPlaying
        }
    }

    /// The device being controlled from here leads, then music playing (here before
    /// elsewhere), then a song held paused (here before elsewhere).
    public init(controlled: String?, isPlayingHere: Bool, hasSongHere: Bool, peers: [Peer]) {
        if let controlled, peers.contains(where: { $0.id == controlled && $0.hasSong }) {
            self = .device(controlled)
        } else if isPlayingHere {
            self = .here
        } else if let playing = peers.first(where: { $0.hasSong && $0.isPlaying }) {
            self = .device(playing.id)
        } else if hasSongHere {
            self = .here
        } else if let paused = peers.first(where: \.hasSong) {
            self = .device(paused.id)
        } else {
            self = .nowhere
        }
    }
}
