import Foundation
import Security

/// The user's Last.fm session key.
///
/// It never expires and is enough to scrobble as the user, so it's kept in the Keychain,
/// not in the App Group defaults every extension can read. Only the username goes there.
public struct LastFMSession: Sendable, Equatable {
    public let username: String
    public let sessionKey: String

    public init(username: String, sessionKey: String) {
        self.username = username
        self.sessionKey = sessionKey
    }
}

public enum LastFMSessionStore {
    // Renaming either signs every existing user out of Last.fm.
    static let service = "com.luke.tracks.lastfm"
    static let usernameKey = "TracksLastFMUsername"

    /// Where the username lives, so settings can show who's connected without the Keychain.
    static var defaults: UserDefaults {
        AppGroup.identifier.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    public static var current: LastFMSession? {
        guard let username = defaults.string(forKey: usernameKey),
              let key = readKey(for: username)
        else { return nil }
        return LastFMSession(username: username, sessionKey: key)
    }

    /// Saves the key, and the username only once the key is in the Keychain, so a failed
    /// save can't leave a username with no key behind it.
    ///
    /// - Returns: whether it was saved.
    @discardableResult
    public static func save(_ session: LastFMSession) -> Bool {
        deleteKey(for: session.username)
        var item = baseQuery(for: session.username)
        item[kSecValueData as String] = Data(session.sessionKey.utf8)
        // The app can launch at login before the first unlock.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        var status = SecItemAdd(item as CFDictionary, nil)
        #if os(macOS)
        if status == errSecMissingEntitlement {
            // A build without a keychain access group can only use the file-based keychain.
            item.removeValue(forKey: kSecUseDataProtectionKeychain as String)
            status = SecItemAdd(item as CFDictionary, nil)
        }
        #endif
        guard status == errSecSuccess else {
            Log.lastFM.error("Couldn't save the Last.fm session: \(status, privacy: .public)")
            return false
        }
        defaults.set(session.username, forKey: usernameKey)
        return true
    }

    public static func clear() {
        if let username = defaults.string(forKey: usernameKey) {
            deleteKey(for: username)
        }
        defaults.removeObject(forKey: usernameKey)
    }

    /// The data protection keychain, which on the Mac isn't tied to the code signature the
    /// way the file-based one is. iOS only has this one.
    static func baseQuery(for username: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: username,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    #if os(macOS)
    /// Where earlier Mac builds kept the key.
    static func legacyQuery(for username: String) -> [String: Any] {
        var query = baseQuery(for: username)
        query.removeValue(forKey: kSecUseDataProtectionKeychain as String)
        return query
    }
    #endif

    static func deleteKey(for username: String) {
        SecItemDelete(baseQuery(for: username) as CFDictionary)
        #if os(macOS)
        SecItemDelete(legacyQuery(for: username) as CFDictionary)
        #endif
    }

    static func readKey(for username: String) -> String? {
        if let key = readKey(matching: baseQuery(for: username)) { return key }
        #if os(macOS)
        // Moved across the first time it's read, so a Mac that connected before this keeps
        // its account. The old copy stays until the move has worked.
        guard let key = readKey(matching: legacyQuery(for: username)) else { return nil }
        var item = baseQuery(for: username)
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(item as CFDictionary, nil) == errSecSuccess {
            SecItemDelete(legacyQuery(for: username) as CFDictionary)
        }
        return key
        #else
        return nil
        #endif
    }

    private static func readKey(matching base: [String: Any]) -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }
}
