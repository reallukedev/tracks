import Foundation
import CryptoKit

/// Answers from MusicBrainz and Last.fm, kept on disk so a song's info opens at once the next
/// time and the services aren't asked again. "Not known" is kept too, for less time, so a
/// song with no credits doesn't ask on every visit.
public actor SongInfoCache {
    public struct Lifetime: Sendable {
        let found: TimeInterval
        let missing: TimeInterval

        public init(found: TimeInterval, missing: TimeInterval) {
            self.found = found
            self.missing = missing
        }

        /// Credits and samples rarely change.
        public static let credits = Lifetime(found: 30 * 86_400, missing: 3 * 86_400)
        /// Counts move, the account's own most of all.
        public static let lastFM = Lifetime(found: 12 * 3_600, missing: 86_400)
    }

    private struct Entry<Value: Codable>: Codable {
        let savedAt: Date
        let value: Value?
    }

    public enum Lookup<Value: Sendable>: Sendable {
        case miss
        /// A saved answer; nil when the service didn't know the song.
        case hit(Value?)
    }

    private let directory: URL
    private let now: @Sendable () -> Date

    public init(directory: URL, now: @escaping @Sendable () -> Date = { .now }) {
        self.directory = directory
        self.now = now
    }

    /// In the app's Caches folder, which the system may empty when space runs low.
    public static let shared = SongInfoCache(
        directory: URL.cachesDirectory.appending(path: "SongInfo", directoryHint: .isDirectory)
    )

    public func value<Value: Codable & Sendable>(_ type: Value.Type, for key: String, lifetime: Lifetime) -> Lookup<Value> {
        guard let data = try? Data(contentsOf: file(for: key)),
              let entry = try? JSONDecoder().decode(Entry<Value>.self, from: data)
        else { return .miss }
        let age = now().timeIntervalSince(entry.savedAt)
        guard age >= 0, age < (entry.value == nil ? lifetime.missing : lifetime.found) else { return .miss }
        return .hit(entry.value)
    }

    public func store<Value: Codable & Sendable>(_ value: Value?, for key: String) {
        guard let data = try? JSONEncoder().encode(Entry(savedAt: now(), value: value)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(for: key), options: .atomic)
    }

    /// Hashed, so any title makes a safe file name.
    private func file(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(digest).json")
    }
}
