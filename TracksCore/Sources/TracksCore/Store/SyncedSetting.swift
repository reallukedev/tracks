import Foundation

/// One preference mirrored between the user's devices.
///
/// Settings live in the App Group's `UserDefaults` rather than the model container, because
/// widgets, intents and the menu bar read them without opening the store (see
/// ``CaptureSettings``). ``SettingsSync`` keeps those copies the same across devices through
/// iCloud's key-value store; this type says which keys take part and how two copies of one
/// are reconciled.
public struct SyncedSetting: Sendable, Hashable {

    /// How to settle a key that both devices have written.
    public enum Merge: Sendable, Hashable {
        /// The most recent write wins. Right for a value the user sets outright, where a
        /// later change is meant to replace the earlier one.
        case newestWins

        /// Both devices' entries are kept. Right for a list that only ever grows, where
        /// newest-wins would silently drop whatever the other device added. The result
        /// doesn't depend on which device merges first, so every device lands on the same
        /// set without having to agree on an order.
        case union
    }

    /// What ``SettingsSync`` should do with one key, having compared the two copies.
    public enum Decision: Sendable, Hashable {
        case keepLocal
        case takeRemote
        case unionBoth
    }

    public let key: String
    public let merge: Merge

    public init(key: String, merge: Merge = .newestWins) {
        self.key = key
        self.merge = merge
    }

    /// Which copy of this setting to keep.
    ///
    /// The timestamps are when each side last changed the value, not when it was synced, so
    /// a device that changed a setting offline still wins over one that only read it.
    /// A missing timestamp means that side has never written the key.
    public func decide(localModifiedAt: Date?, remoteModifiedAt: Date?) -> Decision {
        switch merge {
        case .union:
            return .unionBoth
        case .newestWins:
            guard let remoteModifiedAt else { return .keepLocal }
            guard let localModifiedAt else { return .takeRemote }
            // Ties keep the local copy: the values are then almost always equal anyway, and
            // this stops two devices handing one change back and forth.
            return remoteModifiedAt > localModifiedAt ? .takeRemote : .keepLocal
        }
    }
}

extension SyncedSetting {
    /// Every setting that mirrors, and how.
    ///
    /// Deliberately left out, because they mean something different on each device:
    ///
    /// - ``CaptureSettings/recentlyPlayedAnchor``: Apple's recently-played list as *this*
    ///   device last saw it. The Mac and the iPhone see different lists, so sharing it would
    ///   make one device skip real plays and the other import old ones again.
    /// - ``CaptureSettings/forceCapture``: a diagnostic override, meant for the machine
    ///   it's switched on.
    /// - ``CloudSync/isEnabled`` and ``DeviceIdentity``: per device by definition. Syncing
    ///   the first would mean turning sync off on one device turned it off everywhere.
    public static let all: [SyncedSetting] = [
        // Playlist
        SyncedSetting(key: CaptureSettings.playlistNameKey),
        // Shared so a second device adds to the playlist the first one made, instead of
        // creating another with the same name.
        SyncedSetting(key: CaptureSettings.playlistIDKey),
        SyncedSetting(key: CaptureSettings.autoAddKey),

        // Capture
        SyncedSetting(key: CaptureSettings.dedupeWindowKey),
        SyncedSetting(key: CaptureSettings.minimumListenShareKey),
        SyncedSetting(key: CaptureSettings.capturesOnDemandKey),
        SyncedSetting(key: CaptureSettings.importsRecentlyPlayedKey),
        SyncedSetting(key: CaptureSettings.autoPlayBackKey),
        // The user curates this list and can take a station back out, so a removal has to
        // travel as well as an addition.
        SyncedSetting(key: CaptureSettings.excludedStationsKey),

        // Play. Blocked on the Mac is blocked on the iPhone; and unblocking is as much a
        // change as blocking, so the newest list wins rather than the two joining.
        SyncedSetting(key: CaptureSettings.blockedArtistsKey),

        // Song statuses. Nothing ever un-forgets a song, so the sets only grow and a union
        // is both safe and order-independent. Newest-wins would undo a removal made on the
        // other device the next time this one forgot anything.
        SyncedSetting(key: CaptureSettings.forgottenSongsKey, merge: .union),
        SyncedSetting(key: CaptureSettings.forgottenSongDatesKey, merge: .union),
        // A skip on the Mac is in the iPhone's recently-played list too. Each device only
        // adds, and trims the old ones by their own dates, so a union settles the same way.
        SyncedSetting(key: CaptureSettings.passedOverSongsKey, merge: .union),

        // Last.fm
        SyncedSetting(key: CaptureSettings.scrobblesToLastFMKey),
        SyncedSetting(key: CaptureSettings.scrobblesImportedKey),

        // Presentation
        SyncedSetting(key: CaptureSettings.showsUpNextInWidgetKey),
        SyncedSetting(key: CaptureSettings.menuBarLabelStyleKey),
        SyncedSetting(key: CaptureSettings.menuBarLabelFormatKey),
        SyncedSetting(key: CaptureSettings.animatesMenuBarKey),
        SyncedSetting(key: CaptureSettings.showsMenuBarProgressKey),
    ]

    /// The mirrored settings by key, for looking one up when a change names it.
    public static let byKey: [String: SyncedSetting] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.key, $0) }
    )
}
