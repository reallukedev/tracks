import Foundation

/// The CloudKit container that mirrors the store between the user's devices.
///
/// Like ``AppGroup``, the identifier comes from Info.plist. It's derived from the bundle ID
/// in the xcconfig, and an unresolved build setting reads as nil.
public enum CloudSync {
    public static let infoPlistKey = "TracksCloudContainerIdentifier"

    /// Nil in unit tests, previews and unsigned builds.
    public static var containerIdentifier: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String,
              !value.isEmpty,
              !value.contains("$(")
        else { return nil }
        return value
    }

    /// Whether this build can reach iCloud at all.
    ///
    /// False in unit tests, previews and unsigned builds, where the container identifier is
    /// missing and the entitlements have been stripped.
    public static var isConfigured: Bool { containerIdentifier != nil }

    /// The App Group's defaults, so the app and its extensions agree.
    static var defaults: UserDefaults {
        AppGroup.identifier.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    // Renaming them would turn sync back on for anyone who turned it off, and run the
    // legacy stamp again.
    private static let enabledKey = "TracksCloudSyncEnabled"
    private static let stampedKey = "TracksCloudSyncDidStampLegacyCaptures"

    /// Whether to mirror the store to iCloud. On by default.
    ///
    /// Read once when the store opens (SwiftData fixes the CloudKit configuration when the
    /// container is created), so a change takes effect on the next launch.
    public static var isEnabled: Bool {
        get { defaults.object(forKey: enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    /// Whether captures from before this device synced have its ID yet.
    /// See ``TracksStore/stampLegacyCaptures()``.
    static var hasStampedLegacyCaptures: Bool {
        get { defaults.bool(forKey: stampedKey) }
        set { defaults.set(newValue, forKey: stampedKey) }
    }
}

/// A stable, random identifier for this device.
///
/// Each capture records the device that saw it, and only that device writes it to the
/// playlist. Otherwise the Mac and iPhone would both add the same synced row. A random UUID
/// is used instead of `identifierForVendor` or the hardware UUID so iCloud learns nothing
/// about the machine.
public enum DeviceIdentity {
    // Don't rename. A new key would mint a new identity and strand this device's pending
    // playlist writes and scrobbles.
    static let defaultsKey = "TracksDeviceIdentifier"

    public static var current: String {
        let defaults = CloudSync.defaults
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let identifier = UUID().uuidString
        defaults.set(identifier, forKey: defaultsKey)
        return identifier
    }
}
