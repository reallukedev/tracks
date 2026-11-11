#if os(macOS)
import Foundation
import TracksCore

/// Music's AirPlay devices: which speakers it plays to, and how loud each one is.
///
/// `AirPlay device` and `current AirPlay devices` sit in Music's `com.apple.Music.playback`
/// access group, which the scripting-targets entitlement already holds. Run every call on
/// ``ScriptingQueue``: each one blocks until Music answers.
public enum MusicAirPlay {
    public enum Reading: Sendable, Equatable {
        case speakers(MusicSpeakers)
        /// Music isn't open. Asking it anything would open it.
        case notRunning
        /// Automation for Music is off for Tracks (-1743).
        case notAllowed
        case failed
    }

    /// Every device and Music's player state, one Apple event per property rather than per
    /// device, so a house full of speakers is still a quick read.
    public static func read(timeoutSeconds: Int = 2) -> Reading {
        guard MusicScripting.isMusicRunning else { return .notRunning }
        let source = """
        with timeout of \(timeoutSeconds) seconds
            tell application id "com.apple.Music"
                set out to "state" & tab & (player state as text) & linefeed
                set {theNames, theKinds, theAvailable, theAudio, theSelected} to {name, kind, available, supports audio, selected} of every AirPlay device
                set theVolumes to {}
                try
                    set theVolumes to sound volume of every AirPlay device
                end try
                repeat with i from 1 to count of theNames
                    set v to ""
                    if (count of theVolumes) is (count of theNames) then set v to (item i of theVolumes) as text
                    set out to out & "device" & tab & ((item i of theKinds) as text) & tab & ((item i of theAvailable) as text) & tab & ((item i of theAudio) as text) & tab & ((item i of theSelected) as text) & tab & v & tab & (item i of theNames) & linefeed
                end repeat
                return out
            end tell
        end timeout
        """
        switch run(source) {
        case .success(let output): return .speakers(MusicSpeakers.parse(output))
        case .failure(let failure): return failure == .notAllowed ? .notAllowed : .failed
        }
    }

    /// Plays to this device alone.
    @discardableResult
    public static func choose(only name: String) -> Bool {
        tell("set current AirPlay devices to {AirPlay device \(quoted(name))}")
    }

    /// Adds the device to the rooms playing, or takes it out.
    @discardableResult
    public static func set(_ name: String, selected: Bool) -> Bool {
        tell("set selected of AirPlay device \(quoted(name)) to \(selected)")
    }

    @discardableResult
    public static func set(_ name: String, volume: Int) -> Bool {
        tell("set sound volume of AirPlay device \(quoted(name)) to \(min(100, max(0, volume)))")
    }

    // MARK: - Running scripts

    private enum Failure: Error { case notAllowed, failed }

    private static func tell(_ command: String, timeoutSeconds: Int = 3) -> Bool {
        guard MusicScripting.isMusicRunning else { return false }
        let source = """
        with timeout of \(timeoutSeconds) seconds
            tell application id "com.apple.Music" to \(command)
        end timeout
        """
        if case .success = run(source) { return true }
        return false
    }

    private static func run(_ source: String) -> Result<String, Failure> {
        guard let script = NSAppleScript(source: source) else { return .failure(.failed) }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            return .failure(error[NSAppleScript.errorNumber] as? Int == -1743 ? .notAllowed : .failed)
        }
        return .success(result.stringValue ?? "")
    }

    /// An AppleScript string literal: a device's name is whatever its owner typed.
    private static func quoted(_ text: String) -> String {
        "\"" + MusicLibraryPlayback.escape(text) + "\""
    }
}
#endif
