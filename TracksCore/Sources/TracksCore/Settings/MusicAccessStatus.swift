import Foundation

/// Whether Tracks may use Apple Music, and how Settings says it. The app maps MusicKit's
/// authorization onto this, so the words can be tested without MusicKit.
public enum MusicAccessStatus: Sendable, Equatable {
    case allowed
    case notAsked
    case denied
    case restricted

    /// The status line under the name.
    public var line: String {
        switch self {
        case .allowed:
            String(localized: "Allowed · Tracks fills in missed songs, artwork and your radio playlist.")
        case .notAsked:
            String(localized: "Allow access so Tracks can fill in songs you played while it was closed, find artwork and add radio songs to your playlist.")
        case .denied:
            String(localized: "Access is off, so Tracks can’t fill in missed songs, find artwork or add to your playlist.")
        case .restricted:
            String(localized: "Apple Music access is restricted on this device.")
        }
    }

    /// The root row's value.
    public var short: String {
        switch self {
        case .allowed: String(localized: "Allowed")
        case .notAsked: String(localized: "Not Set Up")
        case .denied: String(localized: "Off")
        case .restricted: String(localized: "Restricted")
        }
    }

    public var tone: SettingsTone {
        switch self {
        case .allowed, .notAsked: .plain
        case .denied, .restricted: .attention
        }
    }
}
