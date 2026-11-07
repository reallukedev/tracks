import Foundation
import TracksCore
import TracksMusic

/// The player each platform uses.
///
/// iOS uses `SystemMusicPlayer`, which reaches both listening history and the play count.
/// macOS has no `SystemMusicPlayer`, and `ApplicationMusicPlayer` never moves the play count,
/// so the Mac hands playback to Music.app. See "What Apple counts as a play" in
/// `docs/PlatformNotes.md`.
enum PlatformPlaybackService {
    static func make() -> any PlaybackService {
        #if os(macOS)
        // Read at play time, since the playlist can be renamed in Settings.
        MusicAppPlaybackService(playlistName: { CaptureSettings().playlistName })
        #else
        MusicKitPlaybackService()
        #endif
    }
}
