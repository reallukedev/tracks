#if os(macOS)
import Foundation
import AppKit
import TracksCore

/// Drives play/pause and skip on Music.
public enum MediaTransportControl {
    /// Sends one transport command and returns whether the event was delivered.
    ///
    /// Delivered isn't the same as done: Music accepts `next track` on a radio station with
    /// no error and does nothing (`docs/PlatformNotes.md`). To know
    /// it worked, compare `database ID of current track` before and after.
    @discardableResult
    public static func perform(
        _ command: TransportCommand,
        timeoutSeconds: Int = 2
    ) -> Bool {
        // Addressing a stopped app launches it, so don't send to Music if it isn't running.
        guard MusicScripting.isMusicRunning else { return false }

        let source = """
        with timeout of \(timeoutSeconds) seconds
            tell application id "com.apple.Music" to \(command.appleScriptCommand)
        end timeout
        """
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error == nil
    }

    /// Pauses Music if it's playing, and does nothing if it isn't. Unlike `playpause`, safe to
    /// send twice: Tracks sends it when its own player starts, and a start can be reported
    /// more than once.
    @discardableResult
    public static func pause(timeoutSeconds: Int = 2) -> Bool {
        guard MusicScripting.isMusicRunning else { return false }
        let source = """
        with timeout of \(timeoutSeconds) seconds
            tell application id "com.apple.Music" to pause
        end timeout
        """
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error == nil
    }
}

extension TransportCommand {
    /// As spelled in Music's scripting dictionary.
    var appleScriptCommand: String {
        switch self {
        case .previous: "previous track"
        case .playPause: "playpause"
        case .next: "next track"
        }
    }
}
#endif
