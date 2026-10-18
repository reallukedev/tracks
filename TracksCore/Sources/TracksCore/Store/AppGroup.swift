import Foundation

/// The App Group container shared by the app and its extensions on the same device.
/// Syncing between devices is ``CloudSync``.
///
/// iOS uses `group.<name>` and macOS needs `<TeamID>.group.<name>`, so the identifier comes
/// from Info.plist via an xcconfig.
public enum AppGroup {
    public static let infoPlistKey = "TracksAppGroupIdentifier"

    /// Nil without the key (unit tests, previews); callers then use an in-memory store.
    public static var identifier: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String,
              !value.isEmpty,
              // An unresolved xcconfig variable leaves `$(…)` behind. Treat it as unset so
              // setup fails instead of writing nowhere.
              !value.contains("$(")
        else { return nil }
        return value
    }

    public static var containerURL: URL? {
        guard let identifier else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Whether there's a container path to try. Not proof it works: on macOS an empty
    /// `DEVELOPMENT_TEAM` gives `.group.com.luke.tracks` and a path under
    /// `~/Library/Group Containers` that can't be written to. ``TracksStore`` finds out by
    /// opening the store.
    public static var hasCandidateContainer: Bool { containerURL != nil }
}
