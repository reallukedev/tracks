import Foundation

/// One of your devices as last seen: kept on this device, so the list can show the ones that
/// are away, as Find My does, and say when each was last here.
public struct KnownNearbyDevice: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var platform: String
    public var kind: String?
    public var lastSeen: Date
    /// The last song it was playing, while it was here.
    public var song: String?
    public var artist: String?

    public init(id: String, name: String, platform: String, kind: String?, lastSeen: Date, song: String?, artist: String?) {
        self.id = id
        self.name = name
        self.platform = platform
        self.kind = kind
        self.lastSeen = lastSeen
        self.song = song
        self.artist = artist
    }

    public var deviceKind: NearbyDeviceKind { NearbyDeviceKind(platform: platform, kind: kind) }
}

/// The devices you've had nearby: which to keep, which are away, and how to say when.
public enum KnownNearbyDevices {
    /// More than anyone has, and few enough that the list stays short.
    public static let limit = 8
    /// A device not seen for this long has likely been sold or wiped, and drops out of view.
    public static let awayFor: TimeInterval = 30 * 86_400

    /// The list with a device seen just now: replacing what was known of it, newest first.
    public static func remembering(_ device: KnownNearbyDevice, in list: [KnownNearbyDevice]) -> [KnownNearbyDevice] {
        var device = device
        if let old = list.first(where: { $0.id == device.id }), device.song == nil {
            device.song = old.song
            device.artist = old.artist
        }
        let others = list.filter { $0.id != device.id }
        return Array(([device] + others).sorted { $0.lastSeen > $1.lastSeen }.prefix(limit))
    }

    /// The ones not connected now, seen lately, the latest first.
    public static func away(_ list: [KnownNearbyDevice], connected: Set<String>, now: Date) -> [KnownNearbyDevice] {
        list
            .filter { !connected.contains($0.id) && now.timeIntervalSince($0.lastSeen) < awayFor }
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    public static func encoded(_ list: [KnownNearbyDevice]) -> Data? {
        try? JSONEncoder().encode(list)
    }

    public static func decoded(_ data: Data?) -> [KnownNearbyDevice] {
        guard let data, let list = try? JSONDecoder().decode([KnownNearbyDevice].self, from: data) else { return [] }
        return list
    }

    /// "Seen just now", "Seen 2 hours ago", "Seen yesterday".
    public static func seen(_ date: Date, now: Date = .now, locale: Locale = .current) -> String {
        if now.timeIntervalSince(date) < 60 {
            return String(localized: "Seen just now", locale: locale)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        let when = formatter.localizedString(for: date, relativeTo: now)
        return String(localized: "Seen \(when)", locale: locale)
    }
}
