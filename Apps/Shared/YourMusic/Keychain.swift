import Foundation
import Security

/// Server passwords, kept in the Keychain on this device only, never in defaults or iCloud.
enum ServerKeychain {
    private static let service = "com.luke.tracks.music-server"

    /// The item every query names. On the Mac, the data protection keychain, which is the one
    /// that honours "this device only"; the older file keychain would ignore it.
    private static func item(for serverID: String) -> [CFString: Any] {
        var item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: serverID,
        ]
        #if os(macOS)
        item[kSecUseDataProtectionKeychain] = true
        #endif
        return item
    }

    static func password(for serverID: String) -> String? {
        var query = item(for: serverID)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func setPassword(_ password: String, for serverID: String) -> Bool {
        let match = item(for: serverID)
        let data = Data(password.utf8)
        let update: [CFString: Any] = [kSecValueData: data]
        if SecItemUpdate(match as CFDictionary, update as CFDictionary) == errSecSuccess { return true }
        var add = match
        add[kSecValueData] = data
        // Readable in the background once the phone has been unlocked, so downloads and
        // playback carry on with the screen locked; never synced to other devices.
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func removePassword(for serverID: String) {
        SecItemDelete(item(for: serverID) as CFDictionary)
    }
}
