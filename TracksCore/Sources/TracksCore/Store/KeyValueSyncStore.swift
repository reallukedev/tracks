import Foundation

/// The part of `NSUbiquitousKeyValueStore` that ``SettingsSync`` uses.
///
/// Declared as a protocol so the merge can be tested without an iCloud account: the tests
/// hand ``SettingsSync`` a dictionary-backed stand-in.
public protocol KeyValueSyncStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: KeyValueSyncStore {}

/// A ``KeyValueSyncStore`` held in memory, standing in for iCloud in tests and previews.
public final class InMemoryKeyValueStore: KeyValueSyncStore {
    private var storage: [String: Any] = [:]

    public init(storage: [String: Any] = [:]) {
        self.storage = storage
    }

    public func object(forKey key: String) -> Any? { storage[key] }

    public func set(_ value: Any?, forKey key: String) {
        if let value {
            storage[key] = value
        } else {
            storage.removeValue(forKey: key)
        }
    }

    @discardableResult
    public func synchronize() -> Bool { true }

    /// Every key written so far, for a test to assert on what was pushed.
    public var keys: [String] { Array(storage.keys) }
}
