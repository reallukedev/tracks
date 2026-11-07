#if os(macOS)
import Foundation
import AppKit
import TracksCore

/// Reads the Music.app properties the `playerInfo` notification doesn't carry, such as the
/// station name.
///
/// Expect any read to fail. Since macOS 26, `current track` returns error -1728 for
/// non-library, streamed and autoplayed tracks (FB19908171), which includes radio.
public enum MusicScripting {
    /// A single AppleScript property read, and whatever came back.
    public struct Reading: Sendable {
        public let property: String
        public let value: String?
        public let errorDescription: String?

        public var succeeded: Bool { errorDescription == nil }
    }

    /// Properties worth sampling. `current stream title` and `current stream URL` are the
    /// station signals; the `current track` reads are the ones expected to fail on radio.
    public static let probedProperties: [String] = [
        "player state",
        "player position",
        "current stream title",
        "current stream URL",
        "name of current playlist",
        "class of current playlist",
        "name of current track",
        "artist of current track",
        "album of current track",
        "duration of current track",
        "database ID of current track",
        "cloud status of current track",
        "media kind of current track",
    ]

    /// Reads every property in one Apple event, each in its own `try`.
    ///
    /// One event per property could block for the default 60 second Apple event timeout;
    /// a 45 second probe run once produced a single sample that way.
    public static func readAll(timeoutSeconds: Int = 2) -> [Reading] {
        let source = """
        with timeout of \(timeoutSeconds) seconds
            tell application id "com.apple.Music"
                set out to ""
                \(probedProperties.map { property in
                    """
                    try
                        set out to out & "\(property)\t" & (\(property) as text) & linefeed
                    on error errText
                        set out to out & "\(property)\t!!" & errText & linefeed
                    end try
                    """
                }.joined(separator: "\n            "))
                return out
            end tell
        end timeout
        """

        guard let script = NSAppleScript(source: source) else {
            return probedProperties.map {
                Reading(property: $0, value: nil, errorDescription: "Could not compile script")
            }
        }

        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            // The whole event failed, usually a timeout or denied Automation access.
            let code = error[NSAppleScript.errorNumber] as? Int
            let message = error[NSAppleScript.errorMessage] as? String ?? "unknown"
            let suffix = code.map { " (error \($0))" } ?? ""
            return probedProperties.map {
                Reading(property: $0, value: nil, errorDescription: message + suffix)
            }
        }

        return parse(result.stringValue ?? "")
    }

    static func parse(_ output: String) -> [Reading] {
        var byProperty: [String: Reading] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let property = String(parts[0])
            let raw = String(parts[1])
            if raw.hasPrefix("!!") {
                byProperty[property] = Reading(
                    property: property,
                    value: nil,
                    errorDescription: String(raw.dropFirst(2))
                )
            } else {
                byProperty[property] = Reading(property: property, value: raw, errorDescription: nil)
            }
        }
        // Keep the declared order and report anything Music left out.
        return probedProperties.map {
            byProperty[$0] ?? Reading(property: $0, value: nil, errorDescription: "no value returned")
        }
    }

    /// Reads a single property. The sampler uses ``readAll(timeoutSeconds:)`` instead.
    public static func read(_ property: String, timeoutSeconds: Int = 2) -> Reading {
        let source = """
        with timeout of \(timeoutSeconds) seconds
            tell application id "com.apple.Music"
                return \(property) as text
            end tell
        end timeout
        """
        guard let script = NSAppleScript(source: source) else {
            return Reading(property: property, value: nil, errorDescription: "Could not compile script")
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int
            let message = error[NSAppleScript.errorMessage] as? String ?? "unknown"
            let suffix = code.map { " (error \($0))" } ?? ""
            return Reading(property: property, value: nil, errorDescription: message + suffix)
        }
        return Reading(property: property, value: result.stringValue, errorDescription: nil)
    }

    /// Checked first so the probe doesn't launch Music.app by asking it something.
    public static var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    /// What Music is doing, for routing the menu bar's transport controls.
    ///
    /// No duration means a station, but a stopped Music has no duration either, so radio
    /// also requires a track name.
    public static func presence(timeoutSeconds: Int = 2) -> PlayerPresence {
        guard isMusicRunning else { return .absent }
        let readings = readAll(timeoutSeconds: timeoutSeconds)
        func value(_ property: String) -> String? {
            guard let reading = readings.first(where: { $0.property == property }),
                  let value = reading.value,
                  value != "missing value",
                  !value.isEmpty
            else { return nil }
            return value
        }

        let state: PlaybackState = switch value("player state")?.capitalized {
        case "Playing": .playing
        case "Paused": .paused
        default: .stopped
        }

        let hasTrack = value("name of current track") != nil
        let duration = PlayerPresence.seconds(value("duration of current track"))
        return PlayerPresence(
            state: state,
            isRadio: hasTrack && duration == nil,
            position: PlayerPresence.seconds(value("player position")),
            duration: duration.flatMap { $0 > 0 ? $0 : nil }
        )
    }

    /// Moves Music to `seconds` into the song. False if Music didn't take it.
    @discardableResult
    public static func seek(to seconds: Double, timeoutSeconds: Int = 2) -> Bool {
        guard isMusicRunning, seconds.isFinite, seconds >= 0 else { return false }
        // AppleScript reads a number with a point whatever the region's decimal mark.
        let source = """
        with timeout of \(timeoutSeconds) seconds
            tell application id "com.apple.Music" to set player position to \(String(format: "%.2f", seconds))
        end timeout
        """
        var error: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil
    }
}
#endif
