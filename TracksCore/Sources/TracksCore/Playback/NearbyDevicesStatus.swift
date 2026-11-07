import Foundation

/// How your devices stand, for Settings and the list's foot.
public enum NearbyDevicesStatus: Sendable, Equatable {
    case off
    case needsLocalNetwork
    /// On, with none of your devices connected.
    case looking
    case nearby(Int)
    case playing(on: String, nearby: Int)

    /// The one that matters most: off, then a reason it can't work, then what's playing.
    public init(isOn: Bool, needsLocalNetwork: Bool, connected: Int, playingOn: String?) {
        if !isOn {
            self = .off
        } else if needsLocalNetwork {
            self = .needsLocalNetwork
        } else if connected == 0 {
            self = .looking
        } else if let playingOn {
            self = .playing(on: playingOn, nearby: connected)
        } else {
            self = .nearby(connected)
        }
    }

    /// The line under the page's name.
    public var line: String {
        switch self {
        case .off: String(localized: "Off")
        case .needsLocalNetwork: String(localized: "Local Network is off for Tracks")
        case .looking: String(localized: "Looking for your devices nearby")
        case .nearby(let count): String(AttributedString(localized: "^[\(count) device](inflect: true) nearby").characters)
        case .playing(let name, _): String(localized: "Playing on \(name)")
        }
    }

    /// The value on its row in Settings.
    public var short: String {
        switch self {
        case .off: String(localized: "Off")
        case .needsLocalNetwork: String(localized: "Needs Local Network")
        case .looking: String(localized: "On")
        case .nearby(let count), .playing(_, let count): String(localized: "\(count) Nearby")
        }
    }

    /// Something someone should fix.
    public var needsAttention: Bool { self == .needsLocalNetwork }
}
