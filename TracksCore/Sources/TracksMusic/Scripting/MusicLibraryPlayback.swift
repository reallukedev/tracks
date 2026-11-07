#if os(macOS)
import Foundation
import AppKit

/// Tells Music.app to play a track from one of its playlists.
///
/// On macOS, `ApplicationMusicPlayer` (the only MusicKit player there) adds plays to the
/// listening history behind Recently Played and Replay, but never moves the play count shown
/// in Get Info. Music.app playing the same track moves it within seconds. Measured with both
/// the catalog song and the library copy; see `docs/PlatformNotes.md`.
public enum MusicLibraryPlayback {
    public struct Track: Sendable, Equatable {
        public let name: String
        public let artist: String
        /// A station track, which Music.app reports with no duration. Play-back uses this to
        /// tell "the user started a station" from "our song ended".
        public let isStream: Bool

        public init(name: String, artist: String, isStream: Bool = false) {
            self.name = name
            self.artist = artist
            self.isStream = isStream
        }
    }

    public enum Failure: Error, Sendable, Equatable {
        case musicNotRunning
        /// Not in the playlist *and* not in the library.
        case notInLibrary(String)
        case scriptFailed(String)
    }

    /// Starts playing `track`, looking in `playlist` first and then the whole library.
    ///
    /// The library is `library playlist 1 of source 1`. The shorter `library playlist 1`
    /// names the same playlist, but Music refuses it to a sandboxed app with -10004
    /// (privilege violation), so every song outside Tracks’ playlist failed to play.
    public static func play(
        _ track: Track,
        inPlaylist playlist: String,
        timeoutSeconds: Int = 5
    ) -> Result<Void, Failure> {
        // Unlike `MediaTransportControl`, this launches Music.app if it isn't running.
        // The library fallback covers a playlist that was renamed, deleted or not written
        // yet; the song still plays and counts without it.
        let source = """
        with timeout of \(timeoutSeconds) seconds
            tell application id "com.apple.Music"
                -- Stop a station first. A user reported Music answering -10004 (privilege
                -- violation) to a sandboxed play request while a stream was running. Not
                -- fully pinned down, but harmless: the play below replaces it anyway.
                try
                    if player state is playing and duration of current track is missing value then
                        pause
                    end if
                end try
                set matches to {}
                try
                    set matches to (every track of playlist "\(escape(playlist))" ¬
                        whose name is "\(escape(track.name))" and artist is "\(escape(track.artist))")
                end try
                if (count of matches) is 0 then
                    set matches to (every track of library playlist 1 of source 1 ¬
                        whose name is "\(escape(track.name))" and artist is "\(escape(track.artist))")
                end if
                if (count of matches) is 0 then
                    return "NOTFOUND"
                end if
                play (item 1 of matches)
                return "OK"
            end tell
        end timeout
        """

        guard let script = NSAppleScript(source: source) else {
            return .failure(.scriptFailed("Could not compile script"))
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int
            let message = error[NSAppleScript.errorMessage] as? String
            // -10004 is `errAEPrivilegeError`: the script reached for something outside the
            // access groups in Tracks’ scripting-targets entitlement. Automation being turned
            // off is a different error (-1743), so don't send people to that setting.
            if number == -10004 {
                return .failure(.scriptFailed("Music refused the request (-10004)."))
            }
            return .failure(.scriptFailed("\(message ?? "unknown") (\(number ?? 0))"))
        }
        return result.stringValue == "NOTFOUND"
            ? .failure(.notInLibrary(track.name))
            : .success(())
    }

    /// Where Music.app has a track: the playlist, the library, or neither.
    public enum Location: String, Sendable, Equatable {
        case playlist, library, missing
    }

    /// Looks `track` up the way ``play(_:inPlaylist:timeoutSeconds:)`` does, without playing
    /// it, so a caller can tell whether Music can play it at all.
    public static func locate(
        _ track: Track,
        inPlaylist playlist: String,
        timeoutSeconds: Int = 5
    ) -> Result<Location, Failure> {
        let source = """
        with timeout of \(timeoutSeconds) seconds
            tell application id "com.apple.Music"
                try
                    if (count of (every track of playlist "\(escape(playlist))" ¬
                        whose name is "\(escape(track.name))" and artist is "\(escape(track.artist))")) > 0 then
                        return "playlist"
                    end if
                end try
                if (count of (every track of library playlist 1 of source 1 ¬
                    whose name is "\(escape(track.name))" and artist is "\(escape(track.artist))")) > 0 then
                    return "library"
                end if
                return "missing"
            end tell
        end timeout
        """
        guard let script = NSAppleScript(source: source) else {
            return .failure(.scriptFailed("Could not compile script"))
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int
            let message = error[NSAppleScript.errorMessage] as? String
            return .failure(.scriptFailed("\(message ?? "unknown") (\(number ?? 0))"))
        }
        return result.stringValue.flatMap(Location.init(rawValue:)).map { .success($0) }
            ?? .failure(.scriptFailed("Unexpected answer: \(result.stringValue ?? "nothing")"))
    }

    /// Where Music has each of `tracks`, in one round of Apple events. Doesn't launch Music:
    /// when it isn't running this fails with `.musicNotRunning` and nothing is known.
    public static func locateAll(
        _ tracks: [Track],
        inPlaylist playlist: String,
        timeoutSeconds: Int = 5
    ) -> Result<[Location], Failure> {
        guard isMusicRunning else { return .failure(.musicNotRunning) }
        guard !tracks.isEmpty else { return .success([]) }
        let list = tracks
            .map { "{\"\(escape($0.name))\", \"\(escape($0.artist))\"}" }
            .joined(separator: ", ")
        let source = """
        with timeout of \(timeoutSeconds) seconds
            set answers to {}
            tell application id "com.apple.Music"
                repeat with pair in {\(list)}
                    set songName to item 1 of pair
                    set artistName to item 2 of pair
                    set found to "missing"
                    try
                        if (count of (every track of playlist "\(escape(playlist))" ¬
                            whose name is songName and artist is artistName)) > 0 then set found to "playlist"
                    end try
                    if found is "missing" then
                        if (count of (every track of library playlist 1 of source 1 ¬
                            whose name is songName and artist is artistName)) > 0 then set found to "library"
                    end if
                    set end of answers to found
                end repeat
            end tell
            set AppleScript's text item delimiters to ","
            return answers as text
        end timeout
        """
        guard let script = NSAppleScript(source: source) else {
            return .failure(.scriptFailed("Could not compile script"))
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int
            let message = error[NSAppleScript.errorMessage] as? String
            return .failure(.scriptFailed("\(message ?? "unknown") (\(number ?? 0))"))
        }
        let answers = (result.stringValue ?? "").split(separator: ",").compactMap { Location(rawValue: String($0)) }
        guard answers.count == tracks.count else {
            return .failure(.scriptFailed("Unexpected answer: \(result.stringValue ?? "nothing")"))
        }
        return .success(answers)
    }

    /// Shows a catalog song in Music, one click from playing. For a song that isn't in the
    /// library, which is all Music can be told to play.
    @discardableResult
    public static func openInMusic(songID: String) -> Bool {
        guard !songID.isEmpty, let url = URL(string: "music://music.apple.com/song/\(songID)") else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// What Music.app is playing, or nil when it isn't playing or `current track` errors
    /// (which it can on radio). A track with no duration is marked `isStream`.
    public static func currentTrack(timeoutSeconds: Int = 2) -> Track? {
        guard isMusicRunning else { return nil }
        let source = """
        with timeout of \(timeoutSeconds) seconds
            tell application id "com.apple.Music"
                if player state is not playing then return ""
                try
                    set dur to ""
                    try
                        set dur to (duration of current track) as text
                    end try
                    return (name of current track) & "\t" & (artist of current track) & "\t" & dur
                on error
                    return ""
                end try
            end tell
        end timeout
        """
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil, let value = result.stringValue else { return nil }
        let parts = value.components(separatedBy: "\t")
        guard parts.count >= 2, !parts[0].isEmpty else { return nil }
        let duration = parts.count > 2 ? Double(parts[2]) : nil
        return Track(name: parts[0], artist: parts[1], isStream: duration == nil)
    }

    static var isMusicRunning: Bool {
        !NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.Music")
            .isEmpty
    }

    /// AppleScript string literals only need backslash and double quote escaped. Song titles
    /// contain quotes often enough to matter.
    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
#endif
