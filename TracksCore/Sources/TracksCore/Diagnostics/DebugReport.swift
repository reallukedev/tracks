import Foundation

/// What "Copy Debug Info" puts on the clipboard, ready to paste into a GitHub issue.
///
/// Facts about the app and the Mac, never about the listening: no song titles, no Last.fm
/// user name or keys, no iCloud account. People paste this into a public issue.
public struct DebugReport: Sendable, Equatable {
    public struct Section: Sendable, Equatable {
        public let title: String
        public let rows: [(key: String, value: String)]

        public init(_ title: String, _ rows: [(key: String, value: String)]) {
            self.title = title
            self.rows = rows
        }

        public static func == (lhs: Section, rhs: Section) -> Bool {
            lhs.title == rhs.title
                && lhs.rows.map(\.key) == rhs.rows.map(\.key)
                && lhs.rows.map(\.value) == rhs.rows.map(\.value)
        }
    }

    public let sections: [Section]
    public let generatedAt: Date

    public init(sections: [Section], generatedAt: Date = .now) {
        self.sections = sections
        self.generatedAt = generatedAt
    }

    /// Markdown, with the details in a code block so GitHub keeps the alignment.
    public func markdown(timeZone: TimeZone = .current) -> String {
        var lines = ["### Tracks debug info", "", "```"]
        let generated = "Generated"
        let width = ([generated] + sections.flatMap(\.rows).map(\.key)).map(\.count).max() ?? 0
        lines.append(generated.padding(toLength: width, withPad: " ", startingAt: 0) + "  "
            + Self.timestamp(generatedAt, timeZone: timeZone))
        for section in sections where !section.rows.isEmpty {
            lines.append("")
            lines.append("[\(section.title)]")
            for row in section.rows {
                let key = row.key.padding(toLength: width, withPad: " ", startingAt: 0)
                // One line per value, so a multi-line error can't break the layout.
                let value = row.value.replacingOccurrences(of: "\n", with: " ")
                lines.append("\(key)  \(value)")
            }
        }
        lines.append("```")
        return lines.joined(separator: "\n")
    }

    /// ISO 8601 with the offset, so a time means the same thing to whoever reads the issue.
    public static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: timeZone))
            + " (\(timeZone.identifier))"
    }

    /// The rows describing an unexpected quit.
    public static func section(for quit: UnexpectedQuit, timeZone: TimeZone = .current) -> Section {
        Section("Unexpected quit", [
            ("Run started", timestamp(quit.launchedAt, timeZone: timeZone)),
            ("Stopped", timestamp(quit.stoppedAt, timeZone: timeZone)
                + (quit.stopTimeIsExact ? "" : " (last seen running; may be up to a minute early)")),
            ("Reopened", timestamp(quit.reopenedAt, timeZone: timeZone)
                + (quit.reopenedAutomatically ? " (automatically)" : "")),
            ("Not recording for", Duration.seconds(Int(quit.gap.rounded()))
                .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))),
            ("Version at the time", "\(quit.version) (\(quit.build))"),
        ])
    }

    /// Free space on the volume holding `url`, as "14.2 GB free of 460 GB (97% full)".
    ///
    /// Uses the space available for important use, which counts what the system can purge,
    /// the same figure Finder shows. Nil if the volume can't be read.
    public static func diskSpace(at url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey,
        ]),
            let available = values.volumeAvailableCapacityForImportantUsage,
            let total = values.volumeTotalCapacity, total > 0
        else { return nil }
        return describe(available: available, total: Int64(total))
    }

    static func describe(available: Int64, total: Int64) -> String {
        let style = ByteCountFormatStyle(style: .file)
        let used = Double(total - available) / Double(total)
        return "\(available.formatted(style)) free of \(total.formatted(style)) "
            + "(\(used.formatted(.percent.precision(.fractionLength(0)))) full)"
    }
}
