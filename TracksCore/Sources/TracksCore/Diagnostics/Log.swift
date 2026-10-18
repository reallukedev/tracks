import Foundation
import OSLog

/// Where the raw detail behind a failure goes: the error's domain and code, a server's own
/// message, a script's output. People are told what happened in Tracks' own words, and this
/// keeps the rest for Console and a sysdiagnose.
package enum Log {
    package static let playback = Logger(subsystem: subsystem, category: "Playback")
    package static let lastFM = Logger(subsystem: subsystem, category: "Last.fm")
    package static let iCloud = Logger(subsystem: subsystem, category: "iCloud")

    private static let subsystem = Bundle.main.bundleIdentifier ?? "Tracks"
}
