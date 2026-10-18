import Foundation

/// Keeps the user's settings the same on every device they use Tracks on.
///
/// The listening history syncs as SwiftData over CloudKit (see ``CloudSync``). Settings can't
/// ride along: widgets, App Intents and the Mac menu bar read them out of the App Group's
/// defaults without opening the model container, which is why ``CaptureSettings`` lives in
/// `UserDefaults`. This mirrors those defaults through iCloud's key-value store instead, so
/// every device keeps reading them the same cheap way and still sees the same values.
///
/// The key-value store is sized for exactly this: a kilobyte per key, a megabyte overall,
/// against the couple of dozen small values in ``SyncedSetting/all``.
///
/// Both directions are idempotent: a pull writes the local copy only when it differs, and a
/// push compares against what it last saw, so the two devices settle instead of handing one
/// change back and forth.
@MainActor
public final class SettingsSync {

    /// Posted after settings arrive from another device, with the changed keys in
    /// `userInfo[changedKeysKey]`.
    ///
    /// `@AppStorage` redraws on its own, since this writes through `UserDefaults`. This is
    /// for the views that copy a setting into `@State` and would otherwise keep showing the
    /// old value.
    public static let didChangeNotification = Notification.Name("TracksSettingsDidChangeRemotely")
    public static let changedKeysKey = "keys"

    /// Where each key was last changed, as `[key: timeIntervalSince1970]`.
    ///
    /// Kept next to the values so a device that changed a setting offline still wins when it
    /// reconnects, rather than being overwritten by a device that only ever read it.
    static let modifiedAtKey = "TracksSettingModifiedAt"

    /// The fields of the envelope each value travels in.
    static let valueField = "value"
    static let modifiedAtField = "modifiedAt"

    private let defaults: UserDefaults
    private let cloud: KeyValueSyncStore
    private let settings: [SyncedSetting]

    /// The mirrored values as this last saw them, so a local write can be spotted without
    /// `UserDefaults` saying which key moved.
    private var snapshot: [String: Any] = [:]
    private var observers: [NSObjectProtocol] = []
    /// Set while ``pull(keys:)`` writes iCloud's values into the defaults.
    private var isPulling = false

    /// The mirror for this process, or nil when there is nothing to mirror to.
    ///
    /// Answers to the same switch as the store: turning "Sync with iCloud" off has to stop
    /// the settings travelling as well as the history, or the toggle would only be half
    /// true. Like the store, the switch is read once here, so a change takes effect on the
    /// next launch.
    public static func forCurrentBuild() -> SettingsSync? {
        guard shouldMirror(enabled: CloudSync.isEnabled, configured: CloudSync.isConfigured)
        else { return nil }
        return SettingsSync()
    }

    /// Whether to mirror settings at all, given the user's switch and whether this build can
    /// reach iCloud. Split out from ``forCurrentBuild()`` so it can be tested: under
    /// `swift test` neither condition holds, so the factory alone can't tell them apart.
    static func shouldMirror(enabled: Bool, configured: Bool) -> Bool {
        enabled && configured
    }

    public init(
        defaults: UserDefaults = CaptureSettings.sharedDefaults,
        cloud: KeyValueSyncStore = NSUbiquitousKeyValueStore.default,
        settings: [SyncedSetting] = SyncedSetting.all
    ) {
        self.defaults = defaults
        self.cloud = cloud
        self.settings = settings
        self.snapshot = Self.read(settings, from: defaults)
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Lifecycle

    /// Starts mirroring: reconciles once with whatever iCloud already has, then follows
    /// changes from either side.
    ///
    /// Safe to call more than once; later calls only reconcile.
    public func start() {
        if observers.isEmpty {
            observers.append(NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: cloud,
                queue: .main
            ) { [weak self] notification in
                // `Notification` isn't `Sendable`, so the two values that matter are read
                // out here rather than carried into the isolated call.
                let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
                let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
                MainActor.assumeIsolated { self?.cloudChanged(reason: reason, keys: keys) }
            })

            // `UserDefaults` doesn't say which key changed, so this diffs against `snapshot`.
            observers.append(NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: defaults,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.pushLocalChanges() }
            })
        }

        cloud.synchronize()
        reconcileAll()
    }

    /// Pulls every mirrored key, then pushes anything this device holds a newer copy of.
    ///
    /// The pull runs first so a fresh install takes iCloud's settings rather than pushing the
    /// defaults it started with.
    public func reconcileAll() {
        let changed = pull(keys: settings.map(\.key))
        seedSettingsNeverSynced()
        pushLocalChanges()
        announce(changed)
    }

    // MARK: - Pulling

    private func cloudChanged(reason: Int?, keys: [String]?) {
        switch reason {
        case NSUbiquitousKeyValueStoreQuotaViolationChange:
            // Nothing sensible to do: the values here are far inside the quota, so something
            // else filled it. Leave the local copies alone.
            return
        case NSUbiquitousKeyValueStoreAccountChange:
            // A different iCloud account, so the remote side is another person's settings or
            // nothing at all. Reconcile from scratch rather than trusting the changed list.
            reconcileAll()
            return
        default:
            break
        }

        announce(pull(keys: keys ?? settings.map(\.key)))
    }

    /// Brings the named keys down from iCloud where iCloud's copy should win.
    /// - Returns: the keys whose local value changed.
    @discardableResult
    func pull(keys: [String]) -> [String] {
        // Each write below fires the defaults' change observer before the snapshot and stamp
        // have caught up, and the push it runs would send the pulled value back up as a
        // change made here, now.
        isPulling = true
        defer { isPulling = false }
        var changed: [String] = []
        var stamps = localModifiedAt

        for key in keys {
            guard let setting = SyncedSetting.byKey[key],
                  settings.contains(setting),
                  let envelope = cloud.object(forKey: key) as? [String: Any]
            else { continue }

            let remoteValue = envelope[Self.valueField]
            let remoteModifiedAt = (envelope[Self.modifiedAtField] as? Double)
                .map(Date.init(timeIntervalSince1970:))
            let localValue = defaults.object(forKey: key)

            switch setting.decide(
                localModifiedAt: stamps[key].map(Date.init(timeIntervalSince1970:)),
                remoteModifiedAt: remoteModifiedAt
            ) {
            case .keepLocal:
                continue

            case .takeRemote:
                guard !Self.isEqual(localValue, remoteValue) else { continue }
                defaults.set(remoteValue, forKey: key)
                snapshot[key] = remoteValue
                // Stamped with iCloud's time, not now, so this doesn't then look like a
                // local change and get pushed straight back.
                stamps[key] = remoteModifiedAt?.timeIntervalSince1970
                changed.append(key)

            case .unionBoth:
                let merged = Self.union(localValue, remoteValue, forKey: key)
                let stamp = max(
                    stamps[key] ?? 0,
                    remoteModifiedAt?.timeIntervalSince1970 ?? 0
                )
                if !Self.isEqual(localValue, merged) {
                    defaults.set(merged, forKey: key)
                    snapshot[key] = merged
                    changed.append(key)
                }
                stamps[key] = stamp
                // This device knew entries iCloud didn't, so send the whole set back up.
                if !Self.isEqual(remoteValue, merged) {
                    write(merged, forKey: key, modifiedAt: stamp)
                }
            }
        }

        if !changed.isEmpty || stamps != localModifiedAt { localModifiedAt = stamps }
        return changed
    }

    // MARK: - Pushing

    /// Sends up every mirrored key whose local value has moved since this last looked.
    ///
    /// Driven by `UserDefaults.didChangeNotification`, which fires for any key in the suite
    /// and doesn't say which, so the work is the diff rather than the notification.
    func pushLocalChanges() {
        guard !isPulling else { return }
        let current = Self.read(settings, from: defaults)
        let moved = settings.filter { !Self.isEqual(current[$0.key], snapshot[$0.key]) }
        guard !moved.isEmpty else { return }

        var stamps = localModifiedAt
        let now = Date.now.timeIntervalSince1970

        for setting in moved {
            let key = setting.key
            let value: Any?
            switch setting.merge {
            case .newestWins:
                value = current[key]
            case .union:
                // A union key's local copy may be missing entries another device added and
                // this one hasn't pulled yet, so push the union rather than the local set.
                let remote = (cloud.object(forKey: key) as? [String: Any])?[Self.valueField]
                value = Self.union(current[key], remote, forKey: key)
            }
            stamps[key] = now
            write(value, forKey: key, modifiedAt: now)
        }

        snapshot = current
        localModifiedAt = stamps
        cloud.synchronize()
    }

    /// Sends up the settings this device already had, the first time it mirrors anything.
    ///
    /// Pushing is driven by local *changes*, and an install that predates mirroring has none
    /// to make: its settings were chosen long ago and have been sitting in `UserDefaults`
    /// ever since. Without this, an upgraded device puts nothing into iCloud until the user
    /// happens to change a setting, and a second device would find the store empty and keep
    /// its own defaults, which looks exactly like sync not working.
    ///
    /// Seeded values are dated 1970, so a real change made on any device at any time beats
    /// them. Where two devices both seed a key, the first to run the new build wins it; the
    /// next time the user sets it anywhere, that settles it for good.
    private func seedSettingsNeverSynced() {
        var stamps = localModifiedAt
        for setting in settings where stamps[setting.key] == nil {
            // Only keys iCloud has never heard of. A key already up there has an owner.
            guard cloud.object(forKey: setting.key) == nil,
                  let value = defaults.object(forKey: setting.key)
            else { continue }
            write(value, forKey: setting.key, modifiedAt: 0)
            stamps[setting.key] = 0
        }
        guard stamps != localModifiedAt else { return }
        localModifiedAt = stamps
        cloud.synchronize()
    }

    private func write(_ value: Any?, forKey key: String, modifiedAt: TimeInterval) {
        guard let value else {
            // A cleared setting is removed rather than sent as null, so a device that has
            // never seen the key doesn't treat "nothing" as a value worth taking.
            cloud.set(nil, forKey: key)
            return
        }
        cloud.set(
            [Self.valueField: value, Self.modifiedAtField: modifiedAt],
            forKey: key
        )
    }

    private func announce(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: [Self.changedKeysKey: keys]
        )
    }

    // MARK: - Stored timestamps

    private var localModifiedAt: [String: TimeInterval] {
        get { defaults.dictionary(forKey: Self.modifiedAtKey) as? [String: TimeInterval] ?? [:] }
        set { defaults.set(newValue, forKey: Self.modifiedAtKey) }
    }

    // MARK: - Values

    private static func read(
        _ settings: [SyncedSetting],
        from defaults: UserDefaults
    ) -> [String: Any] {
        var values: [String: Any] = [:]
        for setting in settings {
            if let value = defaults.object(forKey: setting.key) { values[setting.key] = value }
        }
        return values
    }

    /// Whether two property-list values are the same. `UserDefaults` hands back `Any`, so
    /// this goes through `NSObject`'s equality rather than `==`.
    static func isEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?): (lhs as AnyObject).isEqual(rhs)
        default: false
        }
    }

    /// Both sides of a ``SyncedSetting/Merge/union`` key, sorted so every device stores the
    /// same array and neither sees the other's copy as a change.
    ///
    /// A list that trims itself is trimmed again here. Each device only trims its own copy,
    /// and the union would otherwise put back everything the other device still had.
    static func union(_ lhs: Any?, _ rhs: Any?, forKey key: String, now: Date = .now) -> [String] {
        let left = lhs as? [String] ?? []
        let right = rhs as? [String] ?? []
        let joined = Set(left).union(right).sorted()
        guard key == CaptureSettings.passedOverSongsKey else { return joined }
        var passedOver = PassedOverSongs(joined)
        passedOver.trim(now: now)
        return passedOver.entries
    }
}
