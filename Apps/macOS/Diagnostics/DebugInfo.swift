import AppKit
import SwiftData
import MusicKit
import TracksCore

/// Gathers what "Copy Debug Info" reports. See ``DebugReport`` for what it leaves out.
@MainActor
enum DebugInfo {
    static func report(model: AppModel, quitMonitor: UnexpectedQuitMonitor) -> DebugReport {
        var sections = [app, system]
        if let notice = quitMonitor.notice {
            var quit = DebugReport.section(for: notice)
            quit = DebugReport.Section(quit.title, quit.rows + [
                ("Reopen automatically", quitMonitor.reopensAutomatically ? "On" : "Off"),
                ("Automatic reopens (10 min)", String(quitMonitor.recentAutomaticReopens)),
            ])
            sections.append(quit)
        }
        sections.append(tracks(model: model))
        return DebugReport(sections: sections)
    }

    /// Copies the report as Markdown, ready for a GitHub issue.
    static func copy(model: AppModel, quitMonitor: UnexpectedQuitMonitor) {
        let text = redactingHome(in: report(model: model, quitMonitor: quitMonitor).markdown())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The report goes into public issues, and errors from the store name its path, which
    /// starts with the home folder and so the person's account name. Each home becomes "~".
    static func redactingHome(in text: String) -> String {
        var homes = [NSHomeDirectory()]
        // In the sandbox NSHomeDirectory() is the app's container; this is the real one.
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            homes.append(String(cString: directory))
        }
        // Longest first, so the container isn't left half replaced.
        return homes
            .filter { $0.count > 1 }
            .sorted { $0.count > $1.count }
            .reduce(text) { $0.replacing($1, with: "~") }
    }

    private static var app: DebugReport.Section {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        return DebugReport.Section("App", [
            ("Version", "\(version) (\(build))"),
            ("Configuration", configuration),
            ("Bundle ID", Bundle.main.bundleIdentifier ?? "?"),
        ])
    }

    private static var system: DebugReport.Section {
        let process = ProcessInfo.processInfo
        var rows: [(key: String, value: String)] = [
            ("macOS", process.operatingSystemVersionString),
            ("Mac", hardwareModel ?? "?"),
            ("Memory", Int64(process.physicalMemory).formatted(.byteCount(style: .memory))),
            ("Low Power Mode", process.isLowPowerModeEnabled ? "On" : "Off"),
        ]
        // The home directory is the app's container, on the same volume as the store.
        if let disk = DebugReport.diskSpace(at: URL(filePath: NSHomeDirectory())) {
            rows.append(("Disk", disk))
        }
        return DebugReport.Section("System", rows)
    }

    private static func tracks(model: AppModel) -> DebugReport.Section {
        let settings = CaptureSettings()
        var rows: [(key: String, value: String)] = [
            ("Demo data", model.isDemoLaunch ? "Yes" : "No"),
            ("Store", model.store?.backing.description ?? "Not opened: \(model.startupError ?? "unknown")"),
        ]
        if let reason = model.store?.syncFailureReason {
            rows.append(("iCloud sync didn't start", reason))
        }
        if let failure = model.syncMonitor?.failure {
            rows.append(("iCloud \(failure.activity.rawValue) failed", failure.message))
        }
        rows += [
            ("Recording", model.capture?.isRunning == true ? "On" : "Paused"),
            ("Apple Music access", String(describing: model.musicAuthorization)),
            ("Add to playlist", settings.autoAddToPlaylist ? "On" : "Off"),
            ("Last.fm", LastFMSessionStore.current == nil ? "Not connected" : "Connected"),
            ("Scrobbling", settings.scrobblesToLastFM ? "On" : "Off"),
        ]
        if let context = model.store?.context {
            var scrobbles = TracksStore.pendingScrobbles(includingImported: settings.scrobblesImported)
            scrobbles.fetchLimit = nil
            rows += [
                ("Plays", count(FetchDescriptor<Capture>(), in: context)),
                ("Waiting for the playlist", count(TracksStore.pendingPlaylistWrites(), in: context)),
                ("Waiting for Last.fm", count(scrobbles, in: context)),
            ]
        }
        return DebugReport.Section("Tracks", rows)
    }

    private static func count(_ descriptor: FetchDescriptor<Capture>, in context: ModelContext) -> String {
        (try? context.fetchCount(descriptor)).map(String.init) ?? "?"
    }

    /// The model identifier, such as "Mac16,1", which says more than a marketing name.
    private static var hardwareModel: String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
