import Foundation

/// Something worth keeping between launches that can be worked out again: what a server said,
/// or what it picked for you. Kept in Caches, so the system can clear it when space is short,
/// and written a moment after the last change, off the main actor, so a burst of answers is
/// one write.
@MainActor
final class CacheFile<Value: Codable & Sendable> {
    private let url: URL
    private var pending: Task<Void, Never>?

    init(_ name: String) {
        url = URL.cachesDirectory.appending(path: "YourMusic", directoryHint: .isDirectory).appending(path: "\(name).json")
    }

    /// What was kept, or nil if there's nothing, or it can't be read.
    func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    func save(_ value: Value) {
        pending?.cancel()
        let url = url
        pending = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await Self.write(value, to: url)
        }
    }

    @concurrent
    private static func write(_ value: Value, to url: URL) async {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
