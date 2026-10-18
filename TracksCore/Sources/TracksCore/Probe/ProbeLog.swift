import Foundation
import Observation

/// A timestamped diagnostic entry from the phase 0 probe.
public struct ProbeEntry: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let timestamp: Date
    public let category: ProbeCategory
    public let headline: String
    /// Ordered so exported logs can be diffed between runs.
    public let fields: [(key: String, value: String)]

    public init(
        timestamp: Date = .now,
        category: ProbeCategory,
        headline: String,
        fields: [(key: String, value: String)] = []
    ) {
        self.timestamp = timestamp
        self.category = category
        self.headline = headline
        self.fields = fields
    }

    public static func == (lhs: ProbeEntry, rhs: ProbeEntry) -> Bool { lhs.id == rhs.id }

    public var plainText: String {
        let stamp = ProbeEntry.formatter.string(from: timestamp)
        var lines = ["[\(stamp)] \(category.rawValue): \(headline)"]
        let width = fields.map(\.key.count).max() ?? 0
        for field in fields {
            let padded = field.key.padding(toLength: max(width, field.key.count), withPad: " ", startingAt: 0)
            lines.append("    \(padded)  =  \(field.value)")
        }
        return lines.joined(separator: "\n")
    }

    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

public enum ProbeCategory: String, Sendable, CaseIterable {
    case systemPlayer = "SystemMusicPlayer"
    case mediaPlayer = "MPMusicPlayerController"
    case playerInfo = "Music playerInfo"
    case scripting = "Music AppleScript"
    case playlistWrite = "Playlist write"
    case environment = "Environment"
    case error = "Error"
}

/// Collects probe output for display and export.
///
/// Keeps the most recent ``maximumEntries`` so a long-running probe can't eat memory.
@MainActor
@Observable
public final class ProbeLog {
    public private(set) var entries: [ProbeEntry] = []
    public var maximumEntries: Int

    public init(maximumEntries: Int = 2_000) {
        self.maximumEntries = maximumEntries
    }

    public func append(_ entry: ProbeEntry) {
        entries.append(entry)
        if entries.count > maximumEntries {
            entries.removeFirst(entries.count - maximumEntries)
        }
    }

    public func append(
        _ category: ProbeCategory,
        _ headline: String,
        fields: [(key: String, value: String)] = []
    ) {
        append(ProbeEntry(category: category, headline: headline, fields: fields))
    }

    public func clear() { entries.removeAll() }

    /// The whole session as text, for the copy button and `ShareLink`.
    public var exportText: String {
        let header = """
        Tracks phase 0 probe
        Exported: \(Date.now.formatted(.iso8601))
        Platform: \(CapturePlatform.current.rawValue)
        Entries: \(entries.count)
        ────────────────────────────────────────────────────────
        """
        return ([header] + entries.map(\.plainText)).joined(separator: "\n")
    }
}
